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
    local expected = { 2000, 4000, 8000, 16000, 32000, 60000, 60000 }
    for _, delay in ipairs(expected) do
      retry.note_failure()
      assert(retry.retry_at_ms == now + delay, "wrong retry deadline for " .. delay)
      now = retry.retry_at_ms - 1
      assert(remuda._butler_reconcile() == "retry deferred", "retry was not deferred before deadline")
      now = retry.retry_at_ms
      assert(remuda._butler_reconcile() ~= "retry deferred", "retry was not allowed at deadline")
    end
    retry.reset()
    assert(retry.delay_ms == 2000 and retry.retry_at_ms == 0, "success did not reset retry state")
    retry.note_failure()
    assert(retry.retry_at_ms == now + 2000, "post-success retry did not restart at 2 seconds")
    remuda._butler_launching = nil
    remuda.clock = real_clock
    return "backoff ok"
  ]=])
  T.eq(result, "backoff ok", "fake remuda.clock should drive reconcile backoff")
end)
