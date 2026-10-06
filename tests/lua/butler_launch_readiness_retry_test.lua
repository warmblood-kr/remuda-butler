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
