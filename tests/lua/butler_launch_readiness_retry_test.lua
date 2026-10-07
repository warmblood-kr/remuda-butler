-- A live candidate can paint its prompt after transient capture failures or
-- an initially blank ConPTY screen. Those frames are not evidence of exit.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 3')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

local function probe_until_ready(name, initial_capture)
  T.eval(string.format([[
    remuda._butler_agent_builders.retry_probe = function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_test_force_launch_probe = remuda._butler_test_force_launch_probe or {}
    remuda._butler_test_force_launch_probe[%q] = true
    remuda._probe_capture_count = 0
    remuda.capture = function(session)
      if session == %q then
        remuda._probe_capture_count = remuda._probe_capture_count + 1
        if remuda._probe_capture_count <= 2 then
          %s
        end
        return "\n❯"
      end
      return ""
    end
  ]], name, name, initial_capture))
  T.eval(string.format([[
    remuda._probe_results = remuda._probe_results or {}
    remuda._butler_choose_async({ "retry_probe" }, {
      name = %q, cwd = os.getenv("XDG_DATA_HOME"), timeout = 3,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, rows)
      remuda._probe_results[%q] = { session = session, agent = agent, attempts = rows }
    end)
  ]], name, name))
  T.wait_until(function()
    return T.eval(string.format("return tostring(remuda._probe_results[%q] ~= nil)", name)) == "true"
  end, 5, name .. " readiness")
  local result = T.eval(string.format([[
    local row = remuda._probe_results[%q]
    return table.concat({ tostring(row.session), tostring(row.agent),
      tostring(row.attempts[1].reason), tostring(remuda._probe_capture_count) }, "|")
  ]], name))
  T.eq(result, name .. "|retry_probe|ready|3", name .. " candidate should survive transient frames")
  T.eval(string.format("return remuda.close(%q)", name))
end

T.test("transient capture errors and blank frames keep a live candidate probing", function()
  probe_until_ready("probe-error-retry", 'error("transient capture error")')
  probe_until_ready("probe-empty-retry", 'return ""')
end)

local function probe_timeout(name, kind, argv, screen, timeout, expected_reason, expected_session)
  T.eval(string.format([[
    remuda._butler_agent_builders[%q] = function() return %s end
    remuda._butler_test_force_launch_probe = remuda._butler_test_force_launch_probe or {}
    remuda._butler_test_force_launch_probe[%q] = true
    remuda._probe_results = remuda._probe_results or {}
    remuda.capture = function(session) if session == %q then return %q end return "" end
  ]], kind, argv, name, name, screen))
  T.eval(string.format([[
    remuda._butler_choose_async({ %q }, {
      name = %q, cwd = os.getenv("XDG_DATA_HOME"), timeout = %d,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, rows)
      remuda._probe_results[%q] = { session = session, agent = agent, attempts = rows }
    end)
  ]], kind, name, timeout, name))
  T.wait_until(function()
    return T.eval(string.format("return tostring(remuda._probe_results[%q] ~= nil)", name)) == "true"
  end, timeout + 5, name .. " timeout decision")
  local result = T.eval(string.format([[
    local row, live = remuda._probe_results[%q], false
    for _, session in ipairs(remuda.ls()) do
      if session.name == %q and session.alive then live = true end
    end
    return table.concat({ tostring(row.session), tostring(row.attempts[1].reason),
      tostring(live), tostring(row.attempts[1].detail or ""),
      tostring(row.attempts[1].session) }, "|")
  ]], name, name))
  T.ok(result:match("^[^|]*|" .. expected_reason .. "|" .. expected_session .. "|") ~= nil,
    name .. " decision mismatch: " .. result)
  T.eq(result:match("|([^|]*)$"), expected_session == "true" and name or "nil",
    name .. " attempt session should distinguish success from failure")
  return result
end

T.test("only a live blank screen is kept unverified at readiness timeout", function()
  local blank = probe_timeout("probe-blank-unverified", "retry_probe",
    '{ "sh", "-c", "sleep 60" }', "", 1, "ready_unverified", "true")
  T.ok(blank:find("screen was blank", 1, true), "unverified attempt should explain the blank screen: " .. blank)
  probe_timeout("probe-screen-timeout", "retry_probe",
    '{ "sh", "-c", "sleep 60" }', "initializing agent", 1, "timeout", "false")
  local multiline = probe_timeout("probe-multiline-screen", "retry_probe",
    '{ "sh", "-c", "sleep 60" }', "first visible row\nsecond visible row\n" .. string.rep("later row content ", 20) .. "\nSECRET_SENTINEL_LATER_ROW", 1, "timeout", "false")
  T.ok(not multiline:find("second visible row", 1, true), "timeout detail must contain only the first visible row: " .. multiline)
  T.ok(multiline:find("first visible row", 1, true), "timeout detail should retain the first visible row: " .. multiline)
  T.ok(not multiline:find("SECRET_SENTINEL_LATER_ROW", 1, true), "timeout detail leaked later screen rows: " .. multiline)
  local early_secret = probe_timeout("probe-early-row-secret", "retry_probe",
    '{ "sh", "-c", "sleep 60" }', "first visible row\nSECRET_SENTINEL_LATER_ROW\nthird row", 1, "timeout", "false")
  T.ok(not early_secret:find("SECRET_SENTINEL_LATER_ROW", 1, true), "timeout detail leaked second-row secret: " .. early_secret)
  local early_outputs = T.eval(string.format([[
    local attempt=remuda._probe_results["probe-early-row-secret"].attempts[1]
    remuda._butler_attempts={attempt}
    local sessions=remuda._butler_sessions()
    local path=%q .. "/early-session-trace.log"
    remuda._butler_session_trace_path=path
    _butler_session_trace("launch_failed",attempt.detail)
    local file=assert(io.open(path,"r"));local trace=file:read("a");file:close()
    local render=table.concat(remuda.butler.launch_failure_lines({attempt}),"\\n")
    return tostring(attempt.detail:find("SECRET_SENTINEL_LATER_ROW",1,true)~=nil) .. "/"
      .. tostring(sessions:find("SECRET_SENTINEL_LATER_ROW",1,true)~=nil) .. "/"
      .. tostring(trace:find("SECRET_SENTINEL_LATER_ROW",1,true)~=nil) .. "/"
      .. tostring(render:find("SECRET_SENTINEL_LATER_ROW",1,true)~=nil)
  ]], os.getenv("XDG_DATA_HOME")))
  T.eq(early_outputs, "false/false/false/false", "early-row secret must not reach any diagnostic surface")
  local safe_outputs = T.eval(string.format([[
    local attempt = remuda._probe_results["probe-multiline-screen"].attempts[1]
    remuda._butler_attempts = { attempt }
    local sessions = remuda._butler_sessions()
    local path = %q .. "/session-trace.log"
    remuda._butler_session_trace_path = path
    _butler_session_trace("launch_failed", attempt.detail)
    local file = assert(io.open(path, "r"))
    local trace = file:read("a")
    file:close()
    return tostring(not sessions:find("SECRET_SENTINEL_LATER_ROW", 1, true)) .. "|"
      .. tostring(not trace:find("SECRET_SENTINEL_LATER_ROW", 1, true))
  ]], os.getenv("XDG_DATA_HOME")))
  T.eq(safe_outputs, "true|true", "sessions and session trace must not expose later rows")
  probe_timeout("probe-dead-child", "retry_probe",
    '{ "sh", "-c", "exit 0" }', "", 3, "exited", "false")
  probe_timeout("probe-login-screen", "claude",
    '{ "sh", "-c", "sleep 60" }', "Please log in", 3, "login", "false")
  T.eval([[remuda._butler_agent_startup.retry_probe = { modals = {{ match = "must choose", keys = {} }} }]])
  probe_timeout("probe-known-dialog", "retry_probe",
    '{ "sh", "-c", "sleep 60" }', "you must choose an option", 1, "dialog", "false")
  probe_timeout("probe-unknown-dialog", "retry_probe",
    '{ "sh", "-c", "sleep 60" }', "please confirm to continue", 5, "dialog", "false")
end)

T.test("root reconcile failures back off exponentially and reset on success", function()
  local result = T.eval([=[
    local real_clock, now = remuda.clock, 100000
    remuda.clock = function() return now end
    local retry = assert(remuda._butler_reconcile_retry, "reconcile backoff state is missing")
    retry.reset()
    remuda._butler_launching = true

    local tick_calls = 0
    local host = setmetatable({
      _butler_test_mode = "lifecycle",
      _butler_system = {},
      schedule = function() return 0 end,
      cancel = function() end,
      exec = function() end,
      emit = function() end,
    }, { __index = function(_, key)
      if key == "_butler_reconcile" then return function() tick_calls = tick_calls + 1 end end
      return remuda[key]
    end, __newindex = function(_, key, value) remuda[key] = value end })
    local fake_g = setmetatable({}, { __index = { remuda = host } })
    local env = setmetatable({ _G = fake_g, getmetatable = getmetatable }, { __index = _G })
    local file = assert(io.open(os.getenv("REMUDA_LUA_REPO") .. "/packages/butler/init.lua"))
    local source = file:read("a")
    file:close()
    local mod = assert(load(source, "@butler/init.lua", "t", env))()
    mod.start({})
    local tick
    for _, schedule in ipairs(mod.schedules) do
      if schedule.name == "butler-reconcile" then tick = schedule; break end
    end
    assert(tick, "reconcile tick was not registered")

    local expected = { 2000, 4000, 8000, 16000, 32000, 60000, 60000 }
    for index, delay in ipairs(expected) do
      retry.note_failure()
      assert(retry.retry_at_ms == now + delay, "wrong retry deadline for " .. delay)
      now = retry.retry_at_ms - 1
      tick.run()
      assert(tick_calls == index - 1, "periodic reconcile tick was not deferred before deadline")
      assert(remuda._butler_reconcile() ~= "retry deferred", "explicit reconcile call was deferred")
      now = retry.retry_at_ms
      tick.run()
      assert(tick_calls == index, "periodic reconcile tick was not allowed at deadline")
    end
    retry.reset()
    assert(retry.delay_ms == 2000 and retry.retry_at_ms == 0, "success did not reset retry state")
    retry.note_failure()
    assert(retry.retry_at_ms == now + 2000, "post-success retry did not restart at 2 seconds")
    remuda._butler_launching = nil
    remuda.clock = real_clock
    return "tick gating ok"
  ]=])
  T.eq(result, "tick gating ok", "fake remuda.clock should gate only periodic reconcile ticks")
end)
