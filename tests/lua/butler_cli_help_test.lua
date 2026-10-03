local function start_butler()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "Butler root start")
  T.eval([[
    remuda._butler_cli_action_calls = {}
    local function record(kind, ...)
      local args = { ... }
      remuda._butler_cli_action_calls[#remuda._butler_cli_action_calls + 1] = { kind = kind, args = args }
      return "stub:" .. kind
    end
    remuda._butler_send = function(...) return record("send", ...) end
    remuda._butler_report = function(...) return record("report", ...) end
    remuda._butler_reply = function(...) return record("reply", ...) end
    remuda._butler_forward = function(...) return record("forward", ...) end
    remuda._butler_topic_new = function(...) return record("topic-new", ...) end
    remuda.close = function(...) return record("close", ...) end
    return "actions stubbed"
  ]])
end

T.test("message verbs treat --help as help without actions", function()
  start_butler()
  local out = T.eval([[
    local caller = { env = { REMUDA_BUTLER_AGENT_ID = "agent-test" } }
    local cases = {
      { "send", { "send" } },
      { "topic", { "topic", "new", "work" }, "topic new" },
      { "close", { "close", "worker" } },
    }
    local lines = {}
    for _, case in ipairs(cases) do
      for _, flag in ipairs({ "--help", "-h" }) do
        local argv = {}
        for _, word in ipairs(case[2]) do argv[#argv + 1] = word end
        argv[#argv + 1] = flag
        remuda._butler_cli_action_calls = {}
        local ok, result = pcall(remuda._butler_command_run, case[1], argv, caller)
        local text = ok and type(result) == "string" and result or ""
        local help = text:find("Usage:", 1, true) and text:find("remuda butler " .. case[1], 1, true)
        lines[#lines + 1] = (case[3] or case[1]) .. ":" .. flag .. ":help=" .. tostring(not not help)
          .. ",actions=" .. #remuda._butler_cli_action_calls
      end
    end

    remuda._butler_cli_action_calls = {}
    local result = remuda._butler_command_run("send",
      { "send", "sender", "recipient", "--", "--help" }, caller)
    local action = remuda._butler_cli_action_calls[1]
    local body = action and action.args[3] or "(missing)"
    local from = action and action.args[1] or "(missing)"
    local to = action and action.args[2] or "(missing)"
    lines[#lines + 1] = "literal=" .. tostring(result) .. ",from=" .. from .. ",to=" .. to .. ",body=" .. body
    remuda._butler_cli_action_calls = {}
    local real_fail = remuda.fail
    remuda.fail = function(text, code) return "failure:" .. tostring(code) .. ":" .. tostring(text) end
    local invalid = remuda._butler_command_run("send", { "send", "--bogus", "recipient" }, caller)
    remuda.fail = real_fail
    lines[#lines + 1] = "unknown=" .. tostring(invalid)
      .. ",actions=" .. #remuda._butler_cli_action_calls
    return table.concat(lines, "\n")
  ]])
  for _, verb in ipairs({ "send", "topic new", "close" }) do
    for _, flag in ipairs({ "--help", "-h" }) do
      T.expect(out:find(verb .. ":" .. flag .. ":help=true,actions=0", 1, true),
        verb .. " " .. flag .. " was not help-only: " .. out)
    end
  end
  T.expect(out:find("literal=stub:send,from=sender,to=recipient,body=--help", 1, true),
    "-- --help was not delivered as literal body text: " .. out,
    "ok - message verbs keep help flags out of actions and preserve literal body text")
  T.expect(out:find("unknown=failure:2:", 1, true) and out:find("Next: remuda butler send --help", 1, true)
      and out:find("Next: remuda butler send --help,actions=0", 1, true),
    "send unknown option did not return usage exit 2 with Next: " .. out)
end)
