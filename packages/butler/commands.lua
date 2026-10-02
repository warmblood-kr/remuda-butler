-- CLI verbs: the usage text, every `butler.command` verb, _butler_command_run
-- and the `remuda butler` argv parser. main.lua passes its locals in (the
-- mail.lua pattern).
local config = assert(remuda._butler_commands_config)
local current_agent = assert(config.current_agent)
local OPERATOR = assert(config.OPERATOR)
local contributions = assert(config.contributions)
local registry_list = assert(config.registry_list)
local statusline = assert(config.statusline)
local resolve = assert(config.resolve)
local mail = assert(config.mail)
local typed_lines_cli = assert(remuda.butler and remuda.butler.typed_lines_cli,
  "load butler/typed_lines_cli before butler/commands")
local schedule_cli = assert(remuda.butler and remuda.butler.schedule_cli,
  "load butler/schedule_cli before butler/commands")
local USAGE_NOTES = [[
Agent sessions receive REMUDA_BUTLER_AGENT_ID and REMUDA_BUTLER_LEADER_ID.
In an agent session, use `inbox`, `send <to> "..."`, and `send-to-leader ...`;
the identity comes from the caller's environment. For a long message, use
`cat <<'EOF' | remuda butler send MEMBER -` or `--file "$PWD/path"`; `reply` accepts
the same forms. Bodies are limited to 64 KiB. Without a forwarded Butler
identity (a plain shell, or a core that does not forward the caller's env),
`send` is from "operator" and `inbox` needs a name (`inbox <name>`).
`reply` answers a message's original sender, even when it was forwarded to you;
`forward` re-delivers a message you received, keeping its sender, with a note.
]]
-- Help lists every `butler.command` entry's usage in order, so it names only
-- the verbs that are installed.
local function butler_usage()
  local lines = {}
  for _, item in ipairs(contributions("butler.command")) do lines[#lines + 1] = item.entry.usage end
  return "remuda butler — coordination for managed agents\n\n" .. table.concat(lines, "\n") .. "\n\n" .. USAGE_NOTES
end

local function words_after(args, first)
  local words = {}
  for i = first, #args do words[#words + 1] = args[i] end
  return table.concat(words, " ")
end

local MAX_MESSAGE_BYTES = 64 * 1024
local function checked_message_body(body)
  if type(body) ~= "string" or #body == 0 then error("message body must not be empty", 0) end
  if #body > MAX_MESSAGE_BYTES then error("message body exceeds the 64 KiB limit", 0) end
  return body
end
local function message_body(args, first, caller)
  if args[first] == "-" then
    if #args ~= first then error("stdin message form takes no extra arguments", 0) end
    local body = caller and caller.stdin
    if type(body) ~= "string" then
      error("no message body received on stdin; use `--file PATH` or a Remuda core with caller stdin support", 0)
    end
    return checked_message_body(body)
  elseif args[first] == "--file" then
    if #args ~= first + 1 or not args[first + 1] or args[first + 1] == "" then
      error("expected one path after --file", 0)
    end
    local path = args[first + 1]
    local absolute = path:sub(1, 1) == "/" or path:sub(1, 1) == "\\"
      or path:match("^%a:[/\\]") ~= nil
    if not absolute then error('message file path must be absolute; use `--file "$PWD/path"`', 0) end
    -- ponytail: io.open blocks on a named FIFO outside /dev and /proc and would
    -- hang the daemon; upgrade to a core non-blocking fs read word when it exists.
    if path:match("^/dev/") or path:match("^/proc/") then
      error("--file must be a regular file; for a pipe, use - and redirect stdin (Next: remuda butler send NAME - < FILE)", 0)
    end
    local allowed, refusal = remuda._butler_file_for_caller(path, "--file ", true)
    if not allowed then error(refusal, 0) end
    local file, open_err = io.open(allowed, "rb")
    if not file then error("cannot read message file: " .. tostring(open_err), 0) end
    local body, read_err = file:read(MAX_MESSAGE_BYTES + 1)
    file:close()
    if read_err then error("cannot read message file: " .. tostring(read_err), 0) end
    return checked_message_body(body or "")
  end
  return checked_message_body(words_after(args, first))
end
local function cli_result(callback)
  local ok, result = pcall(callback)
  if ok then return result end
  local message = tostring(result)
  if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
  error(message, 0)
end

-- Each verb is a `butler.command` entry (hook-design §4.1); `run` returns nil
-- when its arguments do not fit, and the caller gets the usage text.
local command_entries = {}
local function command(order, verb, usage, run)
  local entry = { id = verb, order = order, verb = verb, usage = usage, run = run }
  command_entries[verb] = entry
  if not remuda.contribute then remuda._butler_contribute("butler.command", verb, entry) end
end
command(5, "doctor", "  remuda butler doctor", function(args)
  if #args == 1 then
    local doctor = remuda._butler_doctor
    local lines = doctor.render(doctor.probe())
    -- What the mod did to the root Butler's settings.local.json at its last launch or load.
    local state = remuda._butler_permission_report or {}
    for _, line in ipairs(doctor.permission_lines(state.report, state.kind)) do
      lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
  end
end)
command(6, "quota", "  remuda butler quota [--report]", function(args, caller)
  local quota = remuda._butler_quota
  if type(quota) ~= "table" then
    local reason = remuda._butler_quota_error or "not loaded"
    reason = (tostring(reason):gsub("[^\032-\126]", "?")):sub(1, 200)
    return remuda.fail("quota is unavailable: " .. reason .. "\nNext: remuda butler doctor", 1)
  end
  if #args == 2 and (args[2] == "--help" or args[2] == "-h") then return quota.help() end
  if #args ~= 1 and not (#args == 2 and args[2] == "--report") then
    return remuda.fail(quota.usage_error(args[2] == "--report" and args[3] or args[2]), 2)
  end
  local report_flag = args[2] == "--report"
  if report_flag then
    local identity = current_agent(caller)
    if identity ~= nil then
      local resolved, alias = pcall(resolve, identity)
      if not resolved or alias ~= "butler" then
        return remuda.fail(quota.report_denied(), 1)
      end
    end
  end
  if type(remuda.pending) ~= "function" then
    return remuda.fail("remuda butler quota needs a Remuda core with deferred replies.\nNext: remuda upgrade", 1)
  end
  local reply = remuda.pending({ timeout = 30 })
  local collected, collect_error = pcall(quota.collect, function(report, err)
    if not report then
      return reply:resolve(1, "", "quota report failed: " .. quota.safe_text(err)
        .. "\nNext: remuda butler doctor\n")
    end
    if not report_flag then
      return reply:resolve(0, quota.terminal(report) .. "\n", "")
    end
    remuda.butler.matrix.send({ text = quota.render(report), plain = true }, function(result)
      if result.error then
        reply:resolve(1, quota.terminal(report, { failed = tostring(result.error) }) .. "\n", "")
      else
        reply:resolve(0, quota.terminal(report, { sent = true }) .. "\n", "")
      end
    end)
  end)
  if not collected then
    reply:resolve(1, "", "quota report failed: " .. quota.safe_text(collect_error)
      .. "\nNext: remuda butler doctor\n")
  end
  return reply
end)
local CLOSE_USAGE = "Usage: remuda butler close <name> [--force]\nExample: remuda butler close worker-1"
local function close_member(name, leader, force)
  local ok, alias = pcall(resolve, name)
  if not ok then error("cannot close " .. tostring(name) .. ": unknown Butler member.\nNext: remuda butler sessions", 0) end
  local agents = remuda._butler_bus and remuda._butler_bus.agents or {}
  local agent = agents[alias]
  -- Direct members only; the root (or a person) may also close leader-less rows
  -- (no parent, or a parent that is gone). The root row itself is never closable.
  local root_row = alias == "butler" or alias == remuda._butler_name
  local leaderless = agent and (not agent.parent or not agents[agent.parent])
  if not agent or root_row or not (agent.parent == leader or (leader == "butler" and leaderless)) then
    error("cannot close " .. tostring(alias) .. ": only your direct members can be closed (you and your leader are excluded).\nNext: remuda butler sessions", 0)
  end
  if not force then
    local unread_ok, unread = pcall(mail.unread, agent.id)
    if not unread_ok or type(unread) ~= "number" then
      error("cannot check unread Butler mail for " .. alias .. ".\nNext: inspect the member inbox and retry", 0)
    end
    if unread > 0 then
      error(alias .. " has unread Butler mail (" .. tostring(unread) .. " message(s)).\nNext: read the inbox, or use --force", 0)
    end
    local idle_ok, idle, reason = pcall(remuda.butler.is_idle, alias)
    if not idle_ok or idle ~= true then
      local detail = idle_ok and (": " .. tostring(reason or "state unknown")) or " (state check failed)"
      local status = idle_ok and reason == "busy" and " is busy" or " is not idle"
      error(alias .. status .. detail .. ".\nNext: wait for it to become idle, or use --force", 0)
    end
  end
  local closed, result = pcall(remuda.close, alias)
  if not closed then error("could not close " .. alias .. ": " .. tostring(result) .. ".\nNext: retry remuda butler close " .. alias, 0) end
  return "Closed " .. alias .. ".\nNext: remuda butler sessions"
end
remuda._butler_close_member = close_member

local function close_caller_leader()
  local function refuse()
    error("cannot identify the Butler caller.\nNext: run from a Butler member session", 0)
  end
  if type(remuda.caller) ~= "function" then refuse() end
  local ok, caller = pcall(remuda.caller)
  if not ok or type(caller) ~= "table" then refuse() end
  if caller.kind == "outside" or caller.kind == "unknown" then return "butler" end
  if caller.kind ~= "session" or type(caller.session) ~= "string" or caller.session == "" then refuse() end
  local agents = remuda._butler_bus and remuda._butler_bus.agents
  if type(agents) ~= "table" then refuse() end
  local leader
  for alias, agent in pairs(agents) do
    if type(agent) == "table" and agent.session_name == caller.session then
      if leader then refuse() end
      leader = alias
    end
  end
  if not leader then refuse() end
  return leader
end

command(8, "close", "  remuda butler close <name> [--force]", function(args, caller)
  if args[2] == "--help" or args[2] == "-h" then return CLOSE_USAGE end
  if #args < 2 or #args > 3 or (args[3] ~= nil and args[3] ~= "--force") then
    error(CLOSE_USAGE .. "\nNext: remuda butler sessions", 0)
  end
  return cli_result(function()
    return close_member(args[2], close_caller_leader(), args[3] == "--force")
  end)
end)
command(10, "sessions", "  remuda butler sessions", function(args)
  if #args == 1 then return remuda._butler_sessions() end
end)
command(12, "status", "  remuda butler status  (0=up, 75=launching, 1=failed)", function(args)
  if #args == 1 then
    local message, code = remuda._butler_status()
    if code ~= 0 then
      if type(remuda.fail) == "function" then return remuda.fail(message, code) end
      error(message, 0)
    end
    return message
  end
end)
command(13, "typed-lines", "  remuda butler typed-lines on|off", function(args, caller)
  return typed_lines_cli.cli(args, current_agent(caller))
end)
command(14, "shell-lines", "  remuda butler shell-lines on|off", function(args, caller)
  return typed_lines_cli.cli(args, current_agent(caller))
end)
command(15, "agents", "  remuda butler agents [--all]", function(args)
  if #args == 1 then return registry_list(false) end
  if #args == 2 and args[2] == "--all" then return registry_list(true) end
end)
command(17, "status-commands", "  remuda butler status-commands on|off", function(args, caller)
  return typed_lines_cli.cli(args, current_agent(caller))
end)
command(18, "schedule", "  remuda butler schedule list\n"
  .. '  remuda butler schedule add <name> "<M H * * *>" <text> | - [--to SESSION]\n'
  .. "  remuda butler schedule rm <name>", function(args, caller)
  return schedule_cli.cli(args, current_agent(caller), caller and caller.stdin)
end)
command(20, "launch", "  remuda butler launch <claude|codex|monocle> [name] [--model M]", function(args, caller)
  if not args[2] then return nil end
  local registered = false
  for _, row in ipairs(contributions("butler.agent")) do if row.id == args[2] then registered = true end end
  if not registered then return nil end
  local model
  if args[#args - 1] == "--model" then model = args[#args]; args[#args] = nil; args[#args] = nil end
  -- The calling member leads the child; only the operator's falls to butler (#24).
  local parent = current_agent(caller)
  if #args == 2 then return remuda._butler_launch(args[2], nil, model, parent) end
  if #args == 3 then return remuda._butler_launch(args[2], args[3], model, parent) end
end)
command(30, "topic", "  remuda butler topic new <name> [--template T] [--agent A] [--model M]\n"
  .. "  remuda butler topic delegate <name> [--agent A] [--leader L] [--model M] [--cwd DIR] <task...>", function(args, caller)
  if args[2] == "new" and args[3] then
    local template, kind, model, i = nil, nil, nil, 4
    while i <= #args do
      if args[i] == "--template" then template = args[i + 1]
      elseif args[i] == "--agent" then kind = args[i + 1]
      elseif args[i] == "--model" then model = args[i + 1]
      else return nil end
      i = i + 2
    end
    return remuda._butler_topic_new(args[3], template, kind, model)
  end
  if args[2] == "delegate" and args[3] then
    local kind, parent, model, cwd, i = nil, current_agent(caller) or "butler", nil, nil, 4
    while i <= #args and (args[i] == "--agent" or args[i] == "--leader" or args[i] == "--model" or args[i] == "--cwd") do
      if args[i] == "--agent" then kind = args[i + 1]
      elseif args[i] == "--model" then model = args[i + 1]
      elseif args[i] == "--cwd" then cwd = args[i + 1]
      else parent = args[i + 1] end
      if not args[i + 1] or args[i + 1] == "" then return nil end
      i = i + 2
    end
    if i <= #args then return remuda._butler_topic_delegate(args[3], words_after(args, i), nil, kind, parent, model, cwd) end
  end
end)
command(40, "send", '  remuda butler send <to> "<message>" | <to> - | <to> --file PATH\n'
  .. '  remuda butler send <from> <to> <message...> | <from> <to> - | <from> <to> --file PATH', function(args, caller)
  if #args < 3 then return nil end
  local from, to, first = current_agent(caller) or OPERATOR, args[2], 3
  if args[3] ~= "-" and args[3] ~= "--file" and #args >= 4 then
    from, to, first = args[2], args[3], 4
  elseif args[3] ~= "-" and args[3] ~= "--file" and #args < 4 then
    -- Positional short messages retain the caller-inferred sender form.
  elseif args[4] == "-" or args[4] == "--file" then
    from, to, first = args[2], args[3], 4
  end
  return cli_result(function()
    return remuda._butler_send(from, to, message_body(args, first, caller))
  end)
end)
command(50, "send-to-leader", "  remuda butler send-to-leader <message...> | - | --file PATH", function(args, caller)
  if #args < 2 then return nil end
  local from = current_agent(caller)
  if not from then
    local message = OPERATOR .. " has no leader; send-to-leader is for Butler agents"
    if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
    error(message, 0)
  end
  return cli_result(function()
    return remuda._butler_report(from, message_body(args, 2, caller))
  end)
end)
command(60, "inbox", "  remuda butler inbox [name]", function(args, caller)
  if args[2] == "--help" or args[2] == "-h" then
    return "Usage: remuda butler inbox [name]\n"
      .. "       remuda butler inbox <message-id>  show one of your messages again; read state is unchanged\n"
  end
  if #args > 2 then return nil end
  -- Only a ULID may reach a message lookup (it opens messages/<id>.json).
  -- An agent id is also a ULID and falls through to the name form.
  if remuda._butler_identity.is_ulid(args[2]) and mail.find_message(args[2]) then
    local me = current_agent(caller)
    return cli_result(function()
      if not me then
        error("inbox " .. args[2] .. " shows a message only to the member it was delivered to."
          .. " Next: run it from that member's session, or remuda butler inbox <name>", 0)
      end
      return remuda._butler_inbox_message(me, args[2])
    end)
  end
  return cli_result(function()
    return remuda._butler_inbox(args[2] or assert(current_agent(caller), "no Butler identity in your env; use `inbox <name>`"))
  end)
end)
command(70, "reply", "  remuda butler reply <message-id> <message...> | - | --file PATH", function(args, caller)
  if #args < 3 then return nil end
  return cli_result(function()
    return remuda._butler_reply(current_agent(caller) or OPERATOR, args[2], message_body(args, 3, caller))
  end)
end)
command(80, "forward", "  remuda butler forward <message-id> <member> [note...]", function(args, caller)
  if #args < 3 then return nil end
  return cli_result(function()
    return remuda._butler_forward(current_agent(caller) or OPERATOR, args[2], args[3],
      #args >= 4 and words_after(args, 4) or nil)
  end)
end)
command(90, "approvals", "  remuda butler approvals", function(args, caller)
  return remuda.butler.approval.cli(args, current_agent(caller))
end)
command(91, "approve", "  remuda butler approve <ID>", function(args, caller)
  return remuda.butler.approval.cli(args, current_agent(caller))
end)
command(92, "deny", "  remuda butler deny <ID>", function(args, caller)
  return remuda.butler.approval.cli(args, current_agent(caller))
end)
command(100, "matrix", remuda.butler.matrix.cli_usage(), function(args, caller)
  -- `matrix send -`: the text is stdin minus the one newline a heredoc or echo appends.
  return remuda.butler.matrix.cli(args, current_agent(caller), function()
    local body = caller and caller.stdin
    if type(body) ~= "string" then
      error("no message body received on stdin; `send -` needs a Remuda core with caller stdin support", 0)
    end
    return checked_message_body((body:gsub("\r?\n$", "")))
  end, function(path)
    -- `matrix send --file PATH`: the same bounded, caller-confined read as the mail verbs.
    return (message_body({ "--file", path }, 1, caller):gsub("\r?\n$", ""))
  end)
end)
remuda._butler_command_run = function(verb, args, caller)
  local entry = command_entries[verb]
  if entry then return entry.run(args, caller) end
end

-- The generic Remuda extension-command bridge passes an argv-like Lua table.
-- This parser lives with Butler, not in the Remuda executable.
remuda.extension_command("butler", function(args, caller)
  if #args == 0 or args[1] == "help" or args[1] == "-h" or args[1] == "--help" then return butler_usage() end
  if args[1] == "statusline" then return statusline(args, caller) end
  if args[1] == "status-hook" then return remuda.butler.status_hook.run(args, caller) end
  for _, item in ipairs(contributions("butler.command")) do
    if item.entry.verb == args[1] then
      local result = item.entry.run(args, caller)
      if result ~= nil then return result end
    end
  end
  return remuda.fail(butler_usage(), 2)
end)
