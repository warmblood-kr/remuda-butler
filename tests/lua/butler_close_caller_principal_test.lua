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

T.test("native_timer_cannot_create_any_topic_member", function()
  eval([[
    remuda._butler_timer_topic_probe = nil
    remuda.after(0.01, function()
      local c, results = remuda.caller(), {}
      local cli = remuda.cli
      for i = 1, 2 do
        if i == 2 then remuda.cli = nil end
        local ok, out = pcall(remuda._extension_commands.butler,
          {"topic", "new", "timer-topic-" .. i, "--agent", "codex"}, c)
        results[#results + 1] = tostring(not ok and tostring(out):find("Next:", 1, true) ~= nil)
      end
      remuda.cli = cli
      remuda._butler_timer_topic_probe = tostring(c.kind) .. "|" .. table.concat(results, "|")
    end)
  ]])
  T.wait_until(function() return eval("return remuda._butler_timer_topic_probe ~= nil"):match("^%s*true%s*$") end,
    5, "native timer topic probe")
  T.eq(eval("return remuda._butler_timer_topic_probe"), "unknown|true|true")
  T.eq(eval([[local n = 0; for _ in pairs(remuda._butler_bus.agents) do n = n + 1 end; return n]]), "3",
    "timer created zero members")
  T.eq(eval([[for _, row in ipairs(remuda.ls()) do if row.name:find("timer-topic", 1, true) then return false end end; return true]]),
    "true", "timer created zero native sessions")
end)

T.test("every_mutating_command_refuses_every_unidentified_caller_before_mutation", function()
  local result = eval([=[
    local probes = {
      {"launch", "codex", "unknown-child"},
      {"topic", "new", "unknown-topic", "--agent", "codex"},
      {"topic", "delegate", "unknown-topic", "task"},
      {"close", "alice", "--force"},
      {"compact", "alice", "--force"},
      {"send", "alice", "callback probe"},
      {"send", "bob", "alice", "callback probe"},
      {"send-to-leader", "callback probe"},
      {"inbox", "alice"},
      {"reply", "missing-id", "callback probe"},
      {"reply", "missing-id", "--attach", "/missing-file"},
      {"forward", "missing-id", "alice"},
      {"typed-lines", "off"}, {"shell-lines", "off"}, {"status-commands", "off"},
      {"approve-text", "off"}, {"approve-text", "request", "alice", "-"},
      {"approvals"}, {"approve", "missing-id"}, {"deny", "missing-id"},
      {"schedule", "add", "callback-probe", "* * * * *", "probe"},
      {"schedule", "rm", "callback-probe"},
      {"matrix", "send", "callback probe"}, {"matrix", "join", "!room:example.org"},
      {"quota", "--report"},
      {"guard", "on"}, {"guard", "off"},
      {"guard", "approvals", "on"}, {"guard", "approvals", "off"},
      {"guard", "deny", "on"}, {"guard", "deny", "off"},
      {"guard", "grants", "on"}, {"guard", "grants", "off"},
    }
    local bob = remuda._butler_bus.agents.bob
    local saved_session, saved_cli, saved_caller = bob.session_name, remuda.cli, remuda.caller
    bob.session_name = remuda._butler_bus.agents.butler.session_name
    remuda.caller = function() return {kind = "outside"} end
    local callers = {
      {kind = "unknown"}, {}, {kind = "session", session = "unregistered"},
      {kind = "service", service = "timer"}, {kind = "timer"},
      {kind = "session", session = bob.session_name}, false,
    }
    local calls, saved = 0, {}
    local function spy(host, key)
      saved[#saved + 1] = {host, key, host[key]}
      host[key] = function() calls = calls + 1; return "mutation reached" end
    end
    for _, key in ipairs({"_butler_launch", "_butler_topic_new", "_butler_topic_delegate",
      "_butler_send", "_butler_report", "_butler_inbox", "_butler_reply", "_butler_reply_target",
      "_butler_forward", "close"}) do spy(remuda, key) end
    spy(remuda.butler, "compact")
    for _, mod in ipairs({"typed_lines_cli", "approve_text", "schedule_cli", "approval", "matrix"}) do
      spy(remuda.butler[mod], "cli")
    end
    spy(remuda._butler_quota, "collect")
    for _, key in ipairs({"set", "set_approvals", "set_deny", "set_grants"}) do spy(remuda.butler.guard_policy, key) end
    local failures = {}
    for _, fallback in ipairs({false, true}) do
      if fallback then remuda.cli = nil end
      for ci, c in ipairs(callers) do
        for _, args in ipairs(probes) do
          local ok, out = pcall(remuda._extension_commands.butler, args, c or nil)
          if ok or not tostring(out):find("cannot identify this caller", 1, true)
              or not tostring(out):find("Next:", 1, true) then
            failures[#failures + 1] = (fallback and "fallback" or "parser") .. "/" .. ci .. "/" .. table.concat(args, " ")
          end
        end
      end
    end
    for _, row in ipairs(saved) do row[1][row[2]] = row[3] end
    bob.session_name, remuda.cli, remuda.caller = saved_session, saved_cli, saved_caller
    return calls .. "|" .. table.concat(failures, ";")
  ]=])
  T.eq(result, "0|", "every command/caller combination must refuse before reaching mutation")
end)

T.test("identified_topic_new_preserves_root_parent_in_both_parser_paths", function()
  T.eq(eval([[
    local cli = remuda.cli
    local callers = {{kind = "outside"}, {kind = "session", session = remuda._butler_bus.agents.alice.session_name}}
    local parents = {}
    for i, c in ipairs(callers) do
      if i == 2 then remuda.cli = nil end
      remuda._extension_commands.butler({"topic", "new", "identified-topic-" .. i, "--agent", "codex"}, c)
      parents[#parents + 1] = remuda._butler_bus.agents["identified-topic-" .. i].parent
    end
    remuda.cli = cli
    return table.concat(parents, "|")
  ]]), "butler|butler")
end)
