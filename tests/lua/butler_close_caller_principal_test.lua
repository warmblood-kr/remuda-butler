T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_launch("codex", "alice")
  remuda._butler_launch("codex", "bob")
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

local function eval(code) return T.eval(code) end

T.test("close_uses_the_supplied_principal_and_refuses_unidentified_without_mutation", function()
  local result = eval([[
    local saved_caller, saved_close = remuda.caller, remuda.close
    local attempts = 0
    remuda.caller = function() return {kind = "outside"} end -- ambient authority must not replace the argument
    remuda.close = function() attempts = attempts + 1 end
    local cases = { {kind = "unknown"}, {}, {kind = "session", session = "unregistered"},
      {kind = "service", service = "timer"} }
    local failures = 0
    for _, c in ipairs(cases) do
      local ok, out = pcall(remuda._butler_command_run, "close", {"close", "alice", "--force"}, c)
      if not ok and tostring(out):find("Next:", 1, true) then failures = failures + 1 end
    end
    local nil_ok = pcall(remuda._butler_command_run, "close", {"close", "alice", "--force"}, nil)
    local bob = remuda._butler_bus.agents.bob
    local saved_session = bob.session_name
    bob.session_name = remuda._butler_bus.agents.butler.session_name
    local ambiguous = pcall(remuda._butler_command_run, "close", {"close", "alice", "--force"},
      {kind = "session", session = bob.session_name})
    bob.session_name = saved_session
    remuda.caller, remuda.close = saved_caller, saved_close
    return failures .. "|" .. tostring(nil_ok) .. "|" .. tostring(ambiguous) .. "|" .. attempts
  ]])
  T.eq(result, "4|false|false|0")
end)

T.test("native_timer_cannot_close_a_live_member", function()
  eval([[
    remuda._butler_timer_close_probe = nil
    remuda.after(0.01, function()
      local c = remuda.caller()
      local ok, out = pcall(remuda._extension_commands.butler, {"close", "alice", "--force"}, c)
      remuda._butler_timer_close_probe = tostring(c.kind) .. "|" .. tostring(ok) .. "|" .. tostring(out)
    end)
  ]])
  T.wait_until(function() return eval("return remuda._butler_timer_close_probe ~= nil"):match("^%s*true%s*$") end,
    5, "native timer close probe")
  local result = eval("return remuda._butler_timer_close_probe")
  T.ok(result:find("unknown|false|", 1, true) and result:find("Next:", 1, true), "timer must refuse: " .. result)
  T.eq(eval("return remuda._butler_bus.agents.alice ~= nil"), "true", "timer left the member registered")
  T.eq(eval([[for _, row in ipairs(remuda.ls()) do if row.name == "alice" then return row.alive end end]]), "true",
    "timer left the session alive")
end)

T.test("callback_mutation_verbs_refuse_unknown_callers_before_touching_members", function()
  local result = eval([[
    local probes = {
      {"launch", "codex", "unknown-child"},
      {"topic", "delegate", "unknown-topic", "task"},
      {"send", "alice", "callback probe"},
      {"send-to-leader", "callback probe"},
      {"typed-lines", "off"},
      {"schedule", "rm", "callback-probe"},
    }
    local failures = 0
    for _, args in ipairs(probes) do
      local ok, out = pcall(remuda._butler_command_run, args[1], args, {kind = "unknown"})
      if not ok and tostring(out):find("Next:", 1, true) then failures = failures + 1 end
    end
    return failures
  ]])
  T.eq(result, "6")
end)
