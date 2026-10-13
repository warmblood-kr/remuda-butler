-- CLI verbs: the usage text, every `butler.command` verb, _butler_command_run
-- and the `remuda butler` argv parser. main.lua passes its locals in (the
-- mail.lua pattern).
local config = assert(remuda._butler_commands_config)
local current_agent = assert(config.current_agent)
local cli_parser = assert(remuda.cli and remuda.cli.parse,
  "Butler CLI requires remuda.cli.parse (Remuda core #465 or later); upgrade Remuda")
local OPERATOR = assert(config.OPERATOR)
local contributions = assert(config.contributions)
local registry_list = assert(config.registry_list)
local statusline = assert(config.statusline)
local resolve_principal = assert(config.resolve_principal)
local resolve = assert(config.resolve)
local mail = assert(config.mail)
local typed_lines_cli = assert(remuda.butler and remuda.butler.typed_lines_cli,
  "load butler/typed_lines_cli before butler/commands")
local approve_text = assert(remuda.butler and remuda.butler.approve_text,
  "load butler/approve_text before butler/commands")
local schedule_cli = assert(remuda.butler and remuda.butler.schedule_cli,
  "load butler/schedule_cli before butler/commands")
local USAGE_NOTES = [[
Agent sessions receive REMUDA_BUTLER_AGENT_ID and REMUDA_BUTLER_LEADER_ID.
In an agent session, use `inbox`, `send <to> "..."`, and `send-to-leader ...`;
the identity comes from the daemon's registered caller session. For a long message, use
`cat <<'EOF' | remuda butler send MEMBER -` or `--file "$PWD/path"`; `reply` accepts
the same forms. Bodies are limited to 64 KiB. An outside caller uses the audited
transitional operator policy: `send` is from "operator" and `inbox` needs a name.
Unknown callers and older cores without caller fields refuse member actions;
run from a registered Butler session or upgrade core. Environment variables never
select CLI identity. Caller attribution is advisory, not an isolation boundary.
`reply` answers a message's original sender, even when it was forwarded to you;
`forward` re-delivers a message you received, keeping its sender, with a note.
`reply <message-id> --attach PATH` posts a file into that Matrix message's thread.
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
-- Zero-argument verbs: the declared spec decides whether argv fits. Help, extras and
-- unknown words all decline (nil), so the caller prints the global usage exactly as before.
local ZERO_ARG_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    doctor = { about = "Check the Butler installation", next = "remuda butler doctor" },
    sessions = { about = "List Butler sessions", next = "remuda butler doctor" },
    status = { about = "Report whether the Butler is up", next = "remuda butler doctor" },
  },
}
local function fits_spec(spec, args)
  -- clap treats a bare `--` as the end-of-options separator; today it is just an unexpected word.
  for _, word in ipairs(args) do if word == "--" then return false end end
  local report = cli_parser(spec, args)
  return report.ok and report.kind ~= "help", report
end
command(5, "doctor", "  remuda butler doctor", function(args)
  if fits_spec(ZERO_ARG_CLI_SPEC, args) then
    local doctor = remuda._butler_doctor
    local lines = doctor.render(doctor.probe())
    local state = remuda._butler_permission_report or {}
    for _, line in ipairs(doctor.permission_lines(state.report, state.kind, state)) do
      lines[#lines + 1] = line
    end
    for _, line in ipairs(doctor.coordination_lines(remuda._butler_root_coordination_report)) do
      lines[#lines + 1] = line
    end
    return table.concat(lines, "\n")
  end
end)
local QUOTA_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    quota = {
      about = "Report claude and codex quota",
      options = { { long = "report", help = "Also post the report to Matrix" } },
      next = "remuda butler doctor",
    },
  },
}
command(6, "quota", "  remuda butler quota [--report]", function(args, caller)
  local quota = remuda._butler_quota
  local fits, parsed = fits_spec(QUOTA_CLI_SPEC, args)
  if parsed and parsed.kind == "help" then return parsed.text end
  if type(quota) ~= "table" then
    local reason = remuda._butler_quota_error or "not loaded"
    reason = (tostring(reason):gsub("[^\032-\126]", "?")):sub(1, 200)
    return remuda.fail("quota is unavailable: " .. reason .. "\nNext: remuda butler doctor", 1)
  end
  if not fits then
    return remuda.fail(parsed and parsed.text or "Usage: remuda butler quota [--report]", 2)
  end
  -- Parsing is pure and happens before authorization or report collection.
  local report_flag = args[2] == "--report"
  if parsed then report_flag = parsed.values.report == true end
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
local CLOSE_USAGE = "Usage: remuda butler close <name> [--force]\n"
  .. "Example: remuda butler close worker-1"
local CLOSE_CLI_USAGE = "Usage: remuda butler close <name> [--force]\n"
  .. "       remuda butler close --force <name>\nExample: remuda butler close worker-1"
local function close_usage_text(text)
  text = text:gsub("Usage: remuda butler close [^\n]*", "")
  local next_start = text:find("\nNext:", 1, true)
  if next_start then
    return text:sub(1, next_start - 1) .. "\n\n" .. CLOSE_CLI_USAGE .. text:sub(next_start)
  end
  return text .. "\n\n" .. CLOSE_CLI_USAGE .. "\nNext: remuda butler sessions"
end
local RELAUNCH_WINDOW = 120
local function session_exited(alias, agent)
  if type(remuda.ls) ~= "function" then return false end
  local ok, rows = pcall(remuda.ls)
  if not ok or type(rows) ~= "table" then return false end
  local dead = false
  for _, row in ipairs(rows) do
    if type(row) == "table" and (row.name == alias or row.name == agent.session_name) then
      -- A live row for the name is authoritative over any stale exited one.
      if row.alive ~= false then return false end
      dead = true
    end
  end
  return dead
end
local function close_member(name, leader, force, leaderless_ok)
  local ok, alias = pcall(resolve, name)
  if not ok then error("cannot close " .. tostring(name) .. ": unknown Butler member.\nNext: remuda butler sessions", 0) end
  local agents = remuda._butler_bus and remuda._butler_bus.agents or {}
  local agent = agents[alias]
  -- Members and their descendants only (remuda#606: a leader-of-leader closes a
  -- finished grandchild); the root (or a person) may also close leader-less rows
  -- (no parent, or a parent that is gone and not relaunching), from the CLI only:
  -- an MCP caller uses the existing capability path. The root row itself is
  -- never closable.
  local relaunching = remuda._butler_relaunching or {}
  local function gone(parent)
    return not agents[parent] and not (relaunching[parent] and os.time() - relaunching[parent] < RELAUNCH_WINDOW)
  end
  -- Strict descendant: walk the whole lineage; a caller match never skips the
  -- cycle check. Past the first hop each edge must be bound to the parent's
  -- durable id (parent_id), so a reused alias cannot inherit an old branch.
  local function descends_from(row)
    local seen, found, cur = { [alias] = true }, false, row
    while cur.parent ~= nil do
      local parent, up = cur.parent, agents[cur.parent]
      if seen[parent] then return false end -- cycle: refuse even when the caller was met
      seen[parent] = true
      -- A present parent_id must match the parent's durable id on every edge below the
      -- leader; only a direct edge with NO parent_id (legacy row) is trusted by alias.
      local legacy_direct = cur == row and parent == leader and cur.parent_id == nil
      if not found and not legacy_direct and (not up or cur.parent_id == nil or cur.parent_id ~= up.id) then return false end
      if parent == leader then found = true end
      if not up then break end
      cur = up
    end
    return found
  end
  -- Note: leader "butler" (the root, and an outside CLI caller the core maps to it)
  -- is an ancestor of every non-root row; deeper rows need an exited session (below).
  local root_row = alias == "butler" or alias == remuda._butler_name
  local leaderless = leaderless_ok and agent and (not agent.parent or gone(agent.parent))
  if not agent or root_row or alias == leader or not (descends_from(agent) or (leader == "butler" and leaderless)) then
    error("cannot close " .. tostring(alias) .. ": only your members and their descendants can be closed (you and your leaders are excluded).\nNext: remuda butler sessions", 0)
  end
  -- Exited sessions retain their final screen, which may look busy or contain
  -- an unsent draft. They cannot do more work, so those live-session gates do
  -- not apply and must not strand the roster row.
  local exited = session_exited(alias, agent)
  -- Lineage authority over a deeper descendant (not a direct member, not a leaderless
  -- row) reaches only exited sessions; --force does not widen it.
  if not exited and agent.parent ~= leader and not (leader == "butler" and leaderless) then
    error(alias .. " is a deeper descendant and still live; only exited descendants can be closed by lineage (use close on its direct leader).\nNext: remuda butler sessions", 0)
  end
  if not force and not exited then
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

local function close_caller_leader(caller)
  local identity = current_agent(caller) -- same fail-closed resolver as every CLI member action
  return identity and resolve(identity) or "butler"
end

local CLOSE_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    close = {
      about = "Close a Butler member or descendant",
      options = { { long = "force", help = "Skip unread-mail and idle checks" } },
      args = { { name = "NAME", help = "Member name (direct members: idle with no unread mail; deeper descendants: exited only; --force skips the direct-member checks only)" } },
      next = "remuda butler sessions",
    },
  },
}
command(8, "close", "  remuda butler close <name> [--force]\n  remuda butler close --force <name>", function(args, caller)
  do
    local report = cli_parser(CLOSE_CLI_SPEC, args)
    if report.kind == "help" then return close_usage_text(report.text) end
    if not report.ok then
      local message = close_usage_text(report.text)
      if type(remuda.fail) == "function" then return remuda.fail(message, report.code) end
      error(message, 0)
    end
    return cli_result(function()
      return close_member(report.values.NAME, close_caller_leader(caller), report.values.force, true)
    end)
  end
end)
command(10, "sessions", "  remuda butler sessions", function(args)
  if fits_spec(ZERO_ARG_CLI_SPEC, args) then return remuda._butler_sessions() end
end)
command(12, "status", "  remuda butler status  (0=up, 75=launching, 1=failed)", function(args)
  if fits_spec(ZERO_ARG_CLI_SPEC, args) then
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
command(21, "guard", "  remuda butler guard on|off|status | approvals on|off|status | deny on|off|status | grants [on|off|status] | stats | verify  (off by default)", function(args, caller)
  -- Resolve hooks and switches once, before policy, approval, or audit state can change.
  local hook = args[2] == nil
  local switch = (#args == 2 and (args[2] == "on" or args[2] == "off"))
      or (#args == 3 and (args[2] == "approvals" or args[2] == "deny" or args[2] == "grants")
        and (args[3] == "on" or args[3] == "off"))
  local principal
  if hook or switch then principal = resolve_principal(caller) end
  if hook or switch then
    return remuda.butler.guard_policy.run(args, caller, principal)
  end
  return remuda.butler.guard_policy.run(args, caller)
end)
local AGENTS_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    agents = {
      about = "List Butler agents",
      options = { { long = "all", help = "Include ended agents" } },
      next = "remuda butler sessions",
    },
  },
}
command(15, "agents", "  remuda butler agents [--all]", function(args)
  local fits, report = fits_spec(AGENTS_CLI_SPEC, args)
  if fits then return registry_list(report.values.all == true) end
end)
command(17, "status-commands", "  remuda butler status-commands on|off", function(args, caller)
  return typed_lines_cli.cli(args, current_agent(caller))
end)
command(19, "approve-text", "  remuda butler approve-text request SESSION - | on|off", function(args, caller)
  -- The verb receives the whole argv; approve_text.cli takes what follows the verb.
  local rest = {}
  for i = 2, #args do rest[#rest + 1] = args[i] end
  return approve_text.cli(rest, current_agent(caller), caller and caller.stdin)
end)
command(18, "schedule", "  remuda butler schedule list\n"
  .. '  remuda butler schedule add <name> "<M H * * *>" <text> | - [--to SESSION]\n'
  .. "  remuda butler schedule rm <name>", function(args, caller)
  local principal = resolve_principal(caller)
  if principal.tag ~= "member" and principal.tag ~= "operator" then
    return remuda.fail("Butler cannot identify this caller. Next: run from a registered Butler session or upgrade Remuda core.", 1)
  end
  if principal.tag == "operator" then principal = nil end
  return schedule_cli.cli(args, principal, caller and caller.stdin)
end)
local function refuse(message)
  if type(remuda.fail) == "function" then return remuda.fail(tostring(message), 1) end
  error(tostring(message), 0)
end
-- Parses --writable DIR (repeatable) and --sandbox full out of a flag list; refuses
-- `full` from any Butler agent session (only a person at a terminal grants it).
local function sandbox_flag(args, i, state)
  if args[i] ~= "--writable" and args[i] ~= "--sandbox" then return false end
  local value = args[i + 1]
  if not value or value == "" then error(args[i] .. " needs a value.\nNext: remuda butler help", 0) end
  if args[i] == "--writable" then
    state.writable = state.writable or {}
    state.writable[#state.writable + 1] = value
  else
    state.sandbox = value
  end
  return true
end
-- verb_words is the owner's command up to the flags, for the refusal message.
local function checked_profile(kind, state, caller, verb_words, cwd, suffix)
  if state.sandbox == "full" and current_agent(caller) ~= nil then
    local profile = { writable = state.writable }
    remuda._butler_sandbox.refuse_full(remuda._butler_sandbox.owner_command(verb_words, profile, cwd) .. (suffix or ""))
  end
  return remuda._butler_profile(kind, state.sandbox, state.writable)
end
command(20, "launch", "  remuda butler launch <claude|codex|monocle> [name] [--model M] [--writable DIR]... [--sandbox full]", function(args, caller)
  if not args[2] then return nil end
  local registered = false
  for _, row in ipairs(contributions("butler.agent")) do if row.id == args[2] then registered = true end end
  if not registered then return nil end
  local model, name, state, i = nil, nil, {}, 3
  while i <= #args do
    if args[i] == "--model" and args[i + 1] then model = args[i + 1]; i = i + 2
    elseif sandbox_flag(args, i, state) then i = i + 2
    elseif not name and args[i]:sub(1, 2) ~= "--" then name = args[i]; i = i + 1
    else return nil end
  end
  -- The calling member leads the child; only the operator's falls to butler (#24).
  local parent = current_agent(caller)
  local words = "remuda butler launch " .. args[2] .. " " .. (name or "NAME")
  local ok, profile = pcall(checked_profile, args[2], state, caller, words)
  if not ok then return refuse(profile) end
  return remuda._butler_launch(args[2], name, model, parent, profile)
end)
local TOPIC_NEW_CLI_SPEC = {
  name = "remuda butler topic",
  verbs = {
    new = {
      about = "Create a Butler topic",
      options = {
        { long = "template", value = "TEMPLATE", help = "Topic template" },
        { long = "agent", value = "AGENT", help = "Agent kind to launch" },
        { long = "model", value = "MODEL", help = "Model for the launched agent" },
      },
      args = { { name = "NAME", help = "Topic name" } },
      next = "remuda butler topic new --help",
    },
  },
}
command(30, "topic", "  remuda butler topic new <name> [--template T] [--agent A] [--model M]\n"
  .. "  remuda butler topic delegate <name> [--agent A] [--leader L] [--model M] [--cwd DIR] [--writable DIR]... [--sandbox full] <task...>", function(args, caller)
  if args[2] == "new" then
    local argv = {}
    for index = 2, #args do argv[#argv + 1] = args[index] end
    local report = cli_parser(TOPIC_NEW_CLI_SPEC, argv)
    if report.kind == "help" then return report.text end
    if not report.ok then
      if type(remuda.fail) == "function" then return remuda.fail(report.text, report.code) end
      error(report.text, 0)
    end
    current_agent(caller)
    return remuda._butler_topic_new(report.values.NAME, report.values.template, report.values.agent, report.values.model)
  end
  if args[2] == "delegate" and args[3] then
    local kind, parent, model, cwd, i = nil, current_agent(caller) or "butler", nil, nil, 4
    local state = {}
    while i <= #args and (args[i] == "--agent" or args[i] == "--leader" or args[i] == "--model" or args[i] == "--cwd"
        or args[i] == "--writable" or args[i] == "--sandbox") do
      if sandbox_flag(args, i, state) then -- recorded in state
      elseif args[i] == "--agent" then kind = args[i + 1]
      elseif args[i] == "--model" then model = args[i + 1]
      elseif args[i] == "--cwd" then cwd = args[i + 1]
      else parent = args[i + 1] end
      if not args[i + 1] or args[i + 1] == "" then return nil end
      i = i + 2
    end
    if i <= #args then
      local words = "remuda butler topic delegate " .. args[3] .. " --agent " .. tostring(kind or "codex")
      local ok, profile = pcall(checked_profile, kind, state, caller, words, cwd, " <task...>")
      if not ok then return refuse(profile) end
      return remuda._butler_topic_delegate(args[3], words_after(args, i), nil, kind, parent, model, cwd, profile)
    end
  end
end)
local SEND_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    send = {
      about = "Send a message to a Butler member",
      options = { { long = "file", value = "PATH", help = "Read message text from a file" } },
      args = {
        { name = "WORDS", help = "Recipient, sender, and message words", multiple = true },
      },
      next = "remuda butler send --help",
    },
  },
}
local function send_sender_matches_caller(from, caller)
  local identity = current_agent(caller)
  if not identity then return true end
  local caller_ok, caller_alias = pcall(resolve, identity)
  local sender_ok, sender_alias = pcall(resolve, from)
  return caller_ok and sender_ok and caller_alias == sender_alias
end
command(40, "send", '  remuda butler send <to> "<message>" | <to> - | <to> --file PATH\n'
  .. '  remuda butler send <from> <to> <message...> | <from> <to> - | <from> <to> --file PATH', function(args, caller)
  local report = cli_parser(SEND_CLI_SPEC, args)
  if report.kind == "help" then return report.text end
  if not report.ok then
    if type(remuda.fail) == "function" then return remuda.fail(report.text, report.code) end
    error(report.text, 0)
  end
  if report.values.file then
    if args[2] == "--file" and report.values.file then
      local words = report.values.WORDS
      if type(words) == "string" then words = { words } end
      if #words > 2 then
        local message = 'send --file accepts at most two words after PATH.\n'
          .. 'Usage: remuda butler send --file PATH <to> [<from> <to>]\n'
          .. 'Example: remuda butler send --file "$PWD/message.txt" lead\n'
          .. 'Next: remuda butler send --help'
        if type(remuda.fail) == "function" then return remuda.fail(message, 2) end
        error(message, 0)
      end
      local from, to = current_agent(caller) or OPERATOR, nil
      if #words == 1 then to = words[1]
      elseif #words >= 2 then from, to = words[1], words[2] end
      if not to then return nil end
      if not send_sender_matches_caller(from, caller) then
        return cli_result(function() error("cannot send with a different sender", 0) end)
      end
      return cli_result(function()
        return remuda._butler_send(from, to, message_body({ "send", "--file", report.values.file }, 2, caller))
      end)
    end
  end
  if #args < 3 then return nil end
  local from, to, first = current_agent(caller) or OPERATOR, args[2], 3
  if args[3] ~= "-" and args[3] ~= "--file" and args[3] ~= "--" and #args >= 4 then
    from, to, first = args[2], args[3], 4
  elseif args[3] ~= "-" and args[3] ~= "--file" and args[3] ~= "--" and #args < 4 then
    -- Positional short messages retain the caller-inferred sender form.
  elseif args[3] ~= "--" and (args[4] == "-" or args[4] == "--file") then
    from, to, first = args[2], args[3], 4
  end
  if not send_sender_matches_caller(from, caller) then
    return cli_result(function() error("cannot send with a different sender", 0) end)
  end
  return cli_result(function()
    local body
    if args[first] == "--" then
      body = checked_message_body(words_after(args, first + 1))
    else
      body = message_body(args, first, caller)
    end
    return remuda._butler_send(from, to, body)
  end)
end)
local SEND_TO_LEADER_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    ["send-to-leader"] = {
      about = "Send a message to your Butler leader",
      options = { { long = "file", value = "PATH", help = "Read message text from a file" },
        { long = "done", help = "Your task is finished: Butler closes you once your inbox is drained and you are idle. Omitting this keeps an earlier request" } },
      args = { { name = "WORDS", help = "Message words", multiple = true, required = false } },
      next = "remuda butler send-to-leader --help",
    },
  },
}
command(50, "send-to-leader", "  remuda butler send-to-leader [--done] <message...> | - | --file PATH\n"
  .. "  Without --done, creates no new auto-close request and keeps an earlier one.\n"
  .. "  To send text that starts with -, put -- first: remuda butler send-to-leader -- -text", function(args, caller)
  local report = cli_parser(SEND_TO_LEADER_CLI_SPEC, args)
  if report.kind == "help" then
    return (report.text:gsub("\nNext:",
      "\nTo send text that starts with -, put -- first: remuda butler send-to-leader -- -text\n\nNext:", 1))
  end
  if not report.ok then
    if type(remuda.fail) == "function" then return remuda.fail(report.text, report.code) end
    error(report.text, 0)
  end
  local done = report.values.done == true
  local words = report.values.WORDS
  if type(words) == "string" then words = { words } end
  words = type(words) == "table" and words or {}
  local file_path = report.values.file
  if #words == 0 and not file_path then return nil end
  local from = current_agent(caller)
  if not from then
    local message = OPERATOR .. " has no leader; send-to-leader is for Butler agents"
    if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
    error(message, 0)
  end
  if file_path then
    if #words > 0 then
      local message = 'send-to-leader --file accepts no message words after PATH.\n'
        .. 'Usage: remuda butler send-to-leader --file PATH\n'
        .. 'Example: remuda butler send-to-leader --file "$PWD/message.txt"\n'
        .. 'Next: remuda butler send-to-leader --help'
      if type(remuda.fail) == "function" then return remuda.fail(message, 2) end
      error(message, 0)
    end
    return cli_result(function()
      return remuda._butler_report(from, message_body({ "send-to-leader", "--file", file_path }, 2, caller), done or nil)
    end)
  end
  return cli_result(function()
    local body = table.concat(words, " ")
    if words[1] == "-" then
      if #words ~= 1 then error("stdin message form takes no extra arguments", 0) end
      body = message_body({ "send-to-leader", "-" }, 2, caller)
    else
      body = checked_message_body(body)
    end
    return remuda._butler_report(from, body, done or nil)
  end)
end)
local INBOX_CLI_SPEC = { name = "remuda butler", verbs = { inbox = { about = "Read your Butler inbox or show one delivered message",
  args = { { name = "NAME", help = "Member name or delivered message ID", required = false } }, next = "remuda butler inbox [name]" } } }
command(60, "inbox", "  remuda butler inbox [name]", function(args, caller)
  local argv = args
  local selector = args[2]
  if type(selector) == "string" and selector:sub(1, 1) == "-" and selector ~= "--help" and selector ~= "-h" then
    argv = { args[1], "--", selector }
    for index = 3, #args do argv[#argv + 1] = args[index] end
  end
  local report = cli_parser(INBOX_CLI_SPEC, argv)
  if report.kind == "help" then
    return report.text .. "\nA message ID shows one of your delivered messages without changing its read state."
  end
  if not report.ok then
    if type(remuda.fail) == "function" then return remuda.fail(report.text, report.code) end
    error(report.text, 0)
  end
  selector = report.values.NAME
  local caller_identity = current_agent(caller)
  -- Only a ULID may reach a message lookup (it opens messages/<id>.json).
  -- An agent id is also a ULID and falls through to the name form.
  if remuda._butler_identity.is_ulid(selector) and mail.find_message(selector) then
    return cli_result(function()
      if not caller_identity then
        error("inbox " .. selector .. " shows a message only to the member it was delivered to."
          .. " Next: run it from that member's session, or remuda butler inbox <name>", 0)
      end
      return remuda._butler_inbox_message(caller_identity, selector)
    end)
  end
  return cli_result(function()
    local name = selector or assert(caller_identity, "outside operator inbox needs a name; use `inbox <name>`")
    if caller_identity and selector then
      -- Check only the caller's own identifiers before inbox resolution. An
      -- unknown target gets the same refusal as any other cross-member name.
      local own_id, own_agent
      local ok, id, agent = pcall(remuda._butler_identity.mail_id, caller_identity, true)
      if ok then own_id, own_agent = id, agent end
      local own_alias = own_agent and own_agent.alias
      local own_session = own_agent and own_agent.session_name
      if own_id and not own_agent then
        -- An ended member still reads its own mail by alias (#23), unless the alias now belongs to a new holder.
        local bus = remuda._butler_bus or {}
        local record = (bus.identity_ids or {})[own_id]
        local alias = record and record.alias
        local live = alias and (bus.agents or {})[alias]
        local latest = alias and (bus.identities or {})[alias]
        if alias and not live and latest and latest.id == own_id then own_alias = alias end
      end
      if name ~= caller_identity and name ~= own_id and name ~= own_alias and name ~= own_session then
        error("agents may only read their own Butler inbox.\nNext: remuda butler inbox", 0)
      end
    end
    return remuda._butler_inbox(name)
  end)
end)
local REPLY_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    reply = {
      about = "Reply to a Butler message",
      options = {
        { long = "file", value = "PATH", help = "Read reply text from a file (place before MESSAGE-ID)" },
        { long = "attach", value = "PATH", help = "Attach a file to the Matrix thread (place before MESSAGE-ID)" },
      },
      args = { { name = "WORDS", help = "Message ID followed by reply text or an optional attachment caption", multiple = true } },
      next = "remuda butler reply --help",
    },
  },
}
command(70, "reply", "  remuda butler reply <message-id> <message...> | -\n"
  .. "  remuda butler reply --file PATH <message-id>\n"
  .. "  remuda butler reply --attach PATH <message-id> [caption...]", function(args, caller)
  if (#args == 2 and (args[2] == "--help" or args[2] == "-h")) or args[#args] == "--help" then
    return cli_parser(REPLY_CLI_SPEC, { args[1], "--help" }).text
  end
  local report = cli_parser(REPLY_CLI_SPEC, args)
  if report.kind == "help" then return report.text end
  if not report.ok then
    if type(remuda.fail) == "function" then return remuda.fail(report.text, report.code) end
    error(report.text, 0)
  end
  local words = report.values.WORDS
  if type(words) == "string" then words = { words } end
  words = type(words) == "table" and words or {}
  local message_id = words[1]
  if not message_id then return nil end
  if #words < 2 and not report.values.file and not report.values.attach then return nil end
  if report.values.attach then
    local caption = {}
    for i = 2, #words do caption[#caption + 1] = words[i] end
    return cli_result(function()
      local agent = current_agent(caller)
      local room, event = remuda._butler_reply_target(agent or OPERATOR, message_id)
      local upload = { "matrix", "--room", room, "upload", "--thread", event }
      if #caption > 0 then upload[#upload + 1] = "--caption"; upload[#upload + 1] = table.concat(caption, " ") end
      upload[#upload + 1] = report.values.attach
      return remuda.butler.matrix.cli(upload, agent)
    end)
  end
  local body_words = {}
  for i = 2, #words do body_words[#body_words + 1] = words[i] end
  if body_words[1] == "--" then table.remove(body_words, 1) end
  local body
  if report.values.file then
    if #body_words > 0 then return remuda.fail("reply --file takes only the message ID after PATH.\nNext: remuda butler reply --help", 2) end
    body = message_body({ "reply", "--file", report.values.file }, 2, caller)
  elseif body_words[1] == "-" then
    if #body_words ~= 1 then return remuda.fail("stdin message form takes no extra arguments", 2) end
    body = message_body({ "reply", "-" }, 2, caller)
  else
    body = checked_message_body(table.concat(body_words, " "))
  end
  return cli_result(function() return remuda._butler_reply(current_agent(caller) or OPERATOR, message_id, body) end)
end)
local FORWARD_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    forward = {
      about = "Forward a Butler message to a member",
      args = { { name = "WORDS", help = "Message ID, member, and optional note", multiple = true } },
      next = "remuda butler forward --help",
    },
  },
}
command(80, "forward", "  remuda butler forward <message-id> <member> [note...]", function(args, caller)
  if (#args == 2 and (args[2] == "--help" or args[2] == "-h")) or args[#args] == "--help" then
    return cli_parser(FORWARD_CLI_SPEC, { args[1], "--help" }).text
  end
  local report = cli_parser(FORWARD_CLI_SPEC, args)
  if report.kind == "help" then return report.text end
  if not report.ok then
    if type(remuda.fail) == "function" then return remuda.fail(report.text, report.code) end
    error(report.text, 0)
  end
  local words = report.values.WORDS
  if type(words) == "string" then words = { words } end
  words = type(words) == "table" and words or {}
  if #words < 2 then return nil end
  return cli_result(function()
    local note_words = {}
    for i = 3, #words do note_words[#note_words + 1] = words[i] end
    if note_words[1] == "--" then table.remove(note_words, 1) end
    return remuda._butler_forward(current_agent(caller) or OPERATOR, words[1], words[2], #note_words > 0 and table.concat(note_words, " ") or nil)
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
