-- remuda-butler: runs one Claude Code session, optionally bridged to Matrix.
-- Matrix commands and the MCP reply tool share the Lua async request vocabulary.

-- This is the one service session installed by the package, not an ordinary
-- user-created session. Its stable name is its public control surface:
-- `remuda send butler ...`, installer liveness checks, and restart recovery
-- must never depend on the directory that happened to start the daemon.
local system = assert(remuda._butler_system)
local function initial_butler_name()
  return "butler"
end

remuda._butler_initial_name = initial_butler_name()

-- The command handler runs in the daemon, so identity comes only from the
-- caller's `REMUDA_*` variables that core forwards in `caller.env` (#95) --
-- never `os.getenv`, which is whatever session happened to birth the daemon.
-- No forwarded identity (a plain shell, or an older core) is the operator.
local OPERATOR = "operator"
local function current_agent(caller)
  local env = caller and caller.env or {}
  for _, key in ipairs({ "REMUDA_BUTLER_AGENT_ID", "REMUDA_BUTLER_SESSION_NAME" }) do
    if env[key] and env[key] ~= "" then return env[key] end
  end
end
local function call_callback(fn, ...)
  local args, unpack_args = {...}, table.unpack or unpack
  local ok, value = pcall(fn, remuda, unpack_args(args, 1, #args))
  if ok then return true, value end
  return pcall(fn, unpack_args(args, 1, #args))
end
local function registered_agent_kind(kind)
  if remuda.contributions then
    for _, row in ipairs(remuda.contributions("butler.agent")) do
      if row.id == kind then return row.entry end
    end
  end
  local bus = remuda._butler_bus
  for id, entry in pairs(bus and bus.contributions and bus.contributions["butler.agent"] or {}) do
    if id == kind then return entry end
  end
end
local function registered_agent_working(entry, screen)
  if not entry or type(entry.working) ~= "function" then return true, false end
  return call_callback(entry.working, screen)
end
remuda._butler_current_agent = current_agent

-- Compaction policy and its helpers live in compaction.lua.
remuda._butler_compaction_module_config = {
  registered_agent_kind = registered_agent_kind, registered_agent_working = registered_agent_working,
}
remuda.exec("butler/compaction")
local compaction = remuda._butler_compaction
local compaction_config = compaction.compaction_config
local compaction_mail_defers = compaction.compaction_mail_defers
local compaction_mail_alert = compaction.compaction_mail_alert
local numbered_option = compaction.numbered_option
local bottom_screen_lines = compaction.bottom_screen_lines
local unknown_dialog_signature = compaction.unknown_dialog_signature
local read_claude_settings = compaction.read_claude_settings
local statusline_model_matches = compaction.statusline_model_matches
local clear_legacy_restore_state = compaction.clear_legacy_restore_state

if remuda._butler_test_mode == true then
  return
end

-- Cancel the existing Matrix relay before resolving new config;
-- matrix.lua will start exactly one relay after the new config is installed.
local old_matrix = remuda.butler and remuda.butler.matrix
local old_relay = old_matrix and old_matrix.relay
if old_relay and old_relay.stop then pcall(old_relay.stop)
end

-- Replace handles created imperatively by the previous Butler version. The
-- lifecycle declaration owns these schedules from this activation onward.
local legacy_compaction_schedule = remuda._butler_compaction_schedule
for _, key in ipairs({ "_butler_notice_schedule", "_butler_reconcile_schedule", "_butler_compaction_schedule" }) do
  if remuda[key] then
    remuda.cancel(remuda[key])
    remuda[key] = nil
  end
end
if legacy_compaction_schedule and remuda._butler_state then
  remuda._butler_state.compaction_enabled = true
end
if not remuda._butler_state then
  remuda._butler_compaction_state = remuda._butler_compaction_state or {}
end
remuda._butler_compaction_reset_idle(remuda._butler_state or remuda._butler_compaction_state)
do
  local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
  local members = lifecycle.compaction_members or remuda._butler_compaction_members_state or {}
  for _, member_state in pairs(members) do clear_legacy_restore_state(member_state) end
  lifecycle.compaction_members = members
  remuda._butler_compaction_members_state = members
end

-- Config/data paths, Matrix credential paths and path helpers live in paths.lua.
remuda.exec("butler/paths")
local paths = remuda._butler_paths
-- One daemon owns a Butler home (#195). A second daemon stops here, before any
-- shared state (the registry, the MCP config, the root Butler, the relay).
remuda.exec("butler/guard")
if not remuda.butler.guard.boot(paths) then return end
remuda.exec("butler/launch_failure")
local launch_failure_lines = assert(remuda.butler.launch_failure_lines)
local topic_config = paths.topic_config
local data_home = paths.data_home
local butler_session_cwd = paths.butler_session_cwd
local mail_root = paths.mail_root
local file_exists = paths.file_exists
local load_topic_config = paths.load_topic_config
local token_path = paths.token_path
local config_path = paths.config_path
local mcp_config_path = paths.mcp_config_path
local shell_quote = paths.shell_quote
local valid_child_name = paths.valid_child_name
local create_fresh_directory = paths.create_fresh_directory
local directory_is_under = paths.directory_is_under
local json_quote = paths.json_quote
-- This internal module is the single inbound Matrix entry point. It registers
-- only the optional relay and remains inert when credentials are absent.
remuda.exec("butler/matrix_request")
remuda.exec("butler/matrix")
-- The root Butler's permission rule and the write-only-when-changed helper
-- live in permissions.lua; these are the file helpers it is handed.
remuda.exec("butler/permissions")
local permissions = remuda._butler_permissions
local butler_fs = {
  read = function(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
  end,
  -- ponytail: asks `test -L` (an argument vector, no shell). nil when it cannot
  -- tell (no `test`, as on Windows; an old core): then nothing is written.
  is_symlink = function(path)
    local ok, result = pcall(function() return remuda.process.run({ argv = { "test", "-L", path }, timeout = 5 }) end)
    if not ok or type(result) ~= "table" or result.timed_out then return nil end
    if result.code == 0 then return true end
    if result.code == 1 then return false end
    return nil
  end,
  json = remuda.json,
  -- A private directory where the core can make one (as paths.lua's create_fresh_directory does).
  mkdir = function(path)
    if remuda.fs and remuda.fs.mkdir_new and remuda.fs.mkdir_new(path) == true then return end
    return remuda.mkdir(path)
  end,
  write = function(path, text, private)
    if remuda.fs and type(remuda.fs.write_atomic) == "function" then
      return remuda.fs.write_atomic(path, text, private and { private = true } or nil)
    end
    if private then return nil, "atomic writes are unavailable on this core" end
    local f, why = io.open(path, "w")
    if not f then return nil, why end
    f:write(text)
    f:close()
    return true
  end,
}

-- The session needs an `--mcp-config` pointing back at this same daemon, or
-- it has no way to reach the Butler MCP tools at all — a bare `remuda.new(nil,
-- {"claude"})` starts a session with no MCP server configured. `claude`
-- only accepts that config as a file path, never inline JSON, so this is a
-- legitimate, unavoidable use of `io`/`os` (unlike embedding a companion
-- script, which argv already handles without touching a file).
-- `REMUDA_BUTLER_SERVER` names the running daemon's own `-s <name>`, so the
-- spawned `remuda ... mcp` reaches the exact instance running this code,
-- not some other "default" one; it defaults to "default" to match the CLI's
-- own default when no `-s` flag was given. `--permission-mode auto` skips
-- the second, tool-call permission dialog entirely (its default is "Yes",
-- the opposite framing from the trust dialog's "No, exit" — measured in
-- native/tests/claude_session.rs) since nothing here can answer it.
local server = os.getenv("REMUDA_BUTLER_SERVER") or "default"
local runtime_dir = os.getenv("REMUDA_RUNTIME_DIR")
local status_path = remuda._butler_status_path
  or (config_path and (config_path .. ".status") or (os.tmpname() .. ".status"))
local function status_settings(path)
  local settings_path = path .. ".settings.json"
  local settings = assert(io.open(settings_path, "w"))
  settings:write('{"statusLine":{"type":"command","command":'
    .. json_quote("remuda -s " .. shell_quote(server) .. " --stdin butler statusline " .. shell_quote(path))
    .. '}}')
  settings:close()
  return settings_path
end

local function statusline_tag(value)
  if type(value) ~= "string" or value == "" then return "?" end
  local tag = value:gsub("[^A-Za-z0-9_.-]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return tag ~= "" and tag or "?"
end

local function statusline_integer(value)
  if type(value) ~= "number" then return "?" end
  local integer = value < 0 and math.ceil(value) or math.floor(value)
  if integer == 0 then return "0" end
  return string.format("%.0f", integer)
end

local function statusline(args, caller)
  local snapshot = {}
  local input = caller and caller.stdin
  if type(input) == "string" then
    local decoded = remuda.json.decode(input)
    if type(decoded) == "table" then snapshot = decoded end
  end

  local window = type(snapshot.context_window) == "table" and snapshot.context_window or {}
  local used = window.total_input_tokens
  if type(used) ~= "number" then
    local current = type(window.current_usage) == "table" and window.current_usage or {}
    local total, count = 0, 0
    for _, key in ipairs({ "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens" }) do
      local part = current[key]
      if type(part) == "number" then total, count = total + part, count + 1 end
    end
    if count > 0 then used = total end
  end

  local model = type(snapshot.model) == "table" and snapshot.model or {}
  local model_name = model.display_name
  if not model_name or model_name == "" then model_name = model.id end
  local line = string.format("MODEL:%s CTX:%s CTXWIN:%s CTXPCT:%s",
    statusline_tag(model_name), statusline_integer(used),
    statusline_integer(window.context_window_size), statusline_integer(window.used_percentage))
  local limits = remuda._butler_quota and remuda._butler_quota.rate_limits_line(snapshot, os.time())

  local path = args[2]
  local drive_rooted = type(path) == "string" and path:match("^%a:")
    and (path:sub(3, 3) == "/" or path:sub(3, 3) == "\\")
  local absolute = type(path) == "string" and (
    path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\" or drive_rooted
  )
  if absolute and path:match("%.status$") then
    pcall(remuda.fs.write_atomic, path, line .. "\n" .. (limits and (limits .. "\n") or ""))
  end
  return line
end
remuda._butler_status_path = status_path

remuda.tool{
  name = "butler_status",
  about = "Read Butler's latest Claude Code status-line telemetry: model, context tokens, window, and percentage.",
  run = function()
    local root = remuda._butler_bus and remuda._butler_bus.agents.butler or {}
    local skipped = {}
    for _, attempt in ipairs(remuda._butler_attempts or {}) do
      if attempt.reason ~= "ready" then skipped[#skipped + 1] = attempt.kind .. "=" .. attempt.reason end
    end
    local launch = " AGENT:" .. tostring(root.kind or "?")
      .. (#skipped > 0 and (" SKIPPED:" .. table.concat(skipped, ",")) or "")
    local f = io.open(remuda._butler_status_path or "", "r")
    if not f then
      return "MODEL:? CTX:? CTXWIN:? CTXPCT:? (no status reading yet)" .. launch
    end
    local line = f:read("*l")
    f:close()
    -- The helper owns this file.  Refuse a malformed or externally replaced
    -- record instead of presenting arbitrary file contents as Claude status.
    if not line or not line:match("^MODEL:[A-Za-z0-9_.%-?]+ CTX:[0-9?]+ CTXWIN:[0-9?]+ CTXPCT:[0-9?]+$") then
      error("butler status record is malformed", 0)
    end
    return line .. launch
  end,
}

-- A small, cooperative post office for every agent Butler launches.  This is
-- deliberately live-image state, like Emacs: callers may inspect or extend it
-- through `run_script`.  `caller.capability` is attribution supplied by that
-- session's MCP child, not an access-control boundary.
remuda._butler_bus = remuda._butler_bus or {
  agents = {}, tokens = {}, inboxes = {}, messages = {}, objects = {}, next = 0,
}
local bus = remuda._butler_bus
bus.pending_tasks = bus.pending_tasks or {}
bus.codex_update_state = bus.codex_update_state or { claimed = false, done = false }
bus.codex_update_relaunches = bus.codex_update_relaunches or {}
bus.codex_update_state.waiting = bus.codex_update_state.waiting or {}
bus.codex_update_state.restart_waiting = bus.codex_update_state.restart_waiting or {}

-- Contribution points (hook-design §4): core's owned registry when this core
-- has one (remuda#141), else Butler's own with the same order rules, on bus.
bus.contributions = bus.contributions or {}
function remuda._butler_contribute(point, id, entry)
  if remuda.contribute then return remuda.contribute(point, id, entry) end
  bus.contributions[point] = bus.contributions[point] or {}
  bus.contributions[point][id] = entry
end
local function contributions(point)
  if remuda.contributions then return remuda.contributions(point) end
  local rows = {}
  for id, entry in pairs(bus.contributions[point] or {}) do rows[#rows + 1] = { id = id, entry = entry } end
  table.sort(rows, function(a, b)
    local left, right = a.entry.order or 0, b.entry.order or 0
    if left ~= right then return left < right end
    return a.id < b.id
  end)
  return rows
end
bus.messages = bus.messages or {}
bus.objects = bus.objects or {}
-- Loaded before identity_record so agents.jsonl shares mail.lua's append.
remuda._butler_mail_config = { bus = bus, root = mail_root, json_quote = json_quote }
remuda.exec("butler/mail")
-- ULIDs, identity records and caller identity live in identity.lua.
remuda._butler_identity_config = { bus = bus, current_agent = current_agent, data_home = data_home,
  json_quote = json_quote }
remuda.exec("butler/identity")
local identity = remuda._butler_identity
local identity_path = identity.identity_path
local identity_record = identity.identity_record
local json_field = identity.json_field
local register_identity = identity.register_identity
local resolve = identity.resolve
local mail_address = identity.mail_address
local mail_id = identity.mail_id
local next_token = identity.next_token
local caller_name = identity.caller_name
local caller_agent = identity.caller_agent
local caller_leader = identity.caller_leader
local mail = assert(remuda._butler_mail)
local mailbox = mail.mailbox
local queue_message = mail.queue
local migrate_legacy_mail = mail.migrate_legacy
remuda._butler_migrate_legacy_mail = migrate_legacy_mail
local delivery_events = type(remuda.emit_until_success) == "function"
local delivery_notice_results = {}
local function delivery_notice_key(message_id, alias)
  return tostring(message_id) .. "\0" .. tostring(alias)
end
local function take_delivery_notice_result(message, alias)
  local key = delivery_notice_key(message.id, alias)
  local result = delivery_notice_results[key]
  delivery_notice_results[key] = nil
  return result
end
local function notify_mail_delivery(message, delivered, recipient_alias, what)
  local result = {}
  local recipient_ref = recipient_alias or (type(message.to) == "table" and message.to.alias or message.to)
  local recipient_ok, _, recipient = pcall(mail_id, recipient_ref, false)
  result.recipient_live = recipient_ok
  if recipient_ok then
    local notice = remuda._butler_notice.mail_notice_text({
      id = delivered.id,
      from = message.from,
      kind = message.kind,
      in_reply_to = message.in_reply_to,
      matrix = message.matrix,
    }, what, recipient.kind)
    local notify_ok, notified, notify_error =
      pcall(remuda._butler_notify, recipient.alias, notice, delivered.id)
    if notify_ok then
      result.delivered, result.error = notified, notify_error
    else
      result.error = notified
      _butler_session_trace("notice_delivery_error", recipient.alias .. " " .. tostring(notified))
    end
  end
  if message.from.host ~= "matrix" then
    delivery_notice_results[delivery_notice_key(delivered.id, recipient_ok and recipient.alias or recipient_ref)] = result
  end
  return delivered
end
local function inbox_delivery(message)
  local delivered, why
  if message.kind == "matrix_reply" then
    local queued, queue_error = remuda.butler.matrix.mail_reply({
      mail_id = message.in_reply_to, reply_mail_id = message.reply_id,
      text = message.text, route = message.matrix_route,
    })
    if not queued then
      message.delivery_error = queue_error
      return nil
    end
    return { id = message.reply_id, matrix_reply = true, source_mail_id = message.in_reply_to }
  elseif message.kind == "forward" then
    delivered, why = mail.forward_delivery(message)
  else
    delivered, why = queue_message(message.from, message.to, message.text, message.subject,
      message.in_reply_to, message.references, message.matrix)
  end
  if not delivered then
    message.delivery_error = why
    return nil
  end
  return notify_mail_delivery(message, delivered)
end
remuda._butler_inbox_delivery = inbox_delivery
local function deliver_message(message)
  if delivery_events then
    local delivered = remuda.emit_until_success("butler/deliver", message)
    if delivered == nil then
      error(message.delivery_error or "no Butler channel installed (try remuda-butler-inbox)", 0)
    end
    return delivered
  end
  if message.kind == "matrix_reply" then
    error("Matrix reply delivery requires the Butler delivery event hook", 0)
  end
  local delivered, why
  if message.kind == "forward" then
    delivered, why = mail.forward_delivery(message)
  else
    delivered, why = queue_message(message.from, message.to, message.text, message.subject,
      message.in_reply_to, message.references, message.matrix)
  end
  if not delivered then error(why or "no Butler channel installed (try remuda-butler-inbox)", 0) end
  return notify_mail_delivery(message, delivered)
end
local function agent_mcp_json(token)
  local env = '"REMUDA_SESSION_CAPABILITY":' .. json_quote(token)
  if runtime_dir then env = env .. ',"REMUDA_RUNTIME_DIR":' .. json_quote(runtime_dir) end
  return '{"mcpServers":{"remuda":{"command":"remuda","args":["-s",'
    .. json_quote(server) .. ',"mcp"],"env":{' .. env .. '}}}}'
end
local function agent_mcp_path(name, token)
  local path = os.tmpname() .. "." .. name .. ".mcp.json"
  -- The file carries this member's capability: owner-only (0600).
  remuda.butler.guard.write_private(path, agent_mcp_json(token))
  return path
end
-- json_quote escapes backslash and quote, which is also right for a TOML
-- basic string: a Windows runtime dir is otherwise an invalid value.
local function agent_mcp_flags(token)
  local env = "REMUDA_SESSION_CAPABILITY=" .. json_quote(token)
  if runtime_dir then env = env .. ",REMUDA_RUNTIME_DIR=" .. json_quote(runtime_dir) end
  local flags = {
    "-c", 'mcp_servers.remuda.command="remuda"',
    "-c", 'mcp_servers.remuda.args=["-s",' .. json_quote(server) .. ',"mcp"]',
    "-c", "mcp_servers.remuda.env={" .. env .. "}",
  }
  if runtime_dir then
    flags[#flags + 1] = "-c"
    flags[#flags + 1] = "shell_environment_policy.set={REMUDA_RUNTIME_DIR=" .. json_quote(runtime_dir) .. "}"
  end
  return flags
end
local function agent_mcp_config(token)
  local env = '"REMUDA_SESSION_CAPABILITY":' .. json_quote(token)
  if runtime_dir then env = env .. ',"REMUDA_RUNTIME_DIR":' .. json_quote(runtime_dir) end
  return '{"mcp_servers":{"remuda":{"command":"remuda","args":["-s",'
    .. json_quote(server) .. ',"mcp"],"env":{' .. env .. '}}}}'
end
remuda._butler_agent_builders = remuda._butler_agent_builders or {}
remuda._butler_agent_startup = remuda._butler_agent_startup or {}
remuda._butler_agent_support = {
  mcp_config_path = agent_mcp_path,
  mcp_flags = agent_mcp_flags,
  mcp_config = agent_mcp_config,
  status_settings = status_settings,
}
remuda.exec("butler/telemetry")
remuda.exec("butler/agents/claudecode")
remuda.exec("butler/agents/codex")
remuda.exec("butler/agents/monocle")
remuda.exec("butler/prompt")
-- The launch chooser, member guidance and startup modals live in agents_launch.lua.
local startup_action_safe
remuda._butler_chooser_config = { bus = bus, call_callback = call_callback, numbered_option = numbered_option,
  bottom_screen_lines = bottom_screen_lines, file_exists = file_exists, contributions = contributions,
  fs = butler_fs, startup_action_safe = function(...) return startup_action_safe(...) end }
remuda.exec("butler/agents_launch")
local chooser = remuda._butler_chooser
local build_agent_argv = chooser.build_agent_argv
local one_line = chooser.one_line
local choose = chooser.choose
local configured_agent_order = chooser.configured_agent_order
local readiness_chain_budget = chooser.readiness_chain_budget
local setup_telemetry = chooser.setup_telemetry
local write_agent_guidance = chooser.write_agent_guidance
local codex_update_complete = chooser.codex_update_complete
-- Member launch and topic creation live in launch.lua.
remuda._butler_launch_config = { bus = bus,
  topic_config = topic_config,
  data_home = data_home,
  load_topic_config = load_topic_config,
  shell_quote = shell_quote,
  valid_child_name = valid_child_name,
  create_fresh_directory = create_fresh_directory,
  directory_is_under = directory_is_under,
  identity_record = identity_record,
  register_identity = register_identity,
  resolve = resolve,
  mail_address = mail_address,
  next_token = next_token,
  mailbox = mailbox,
  queue_message = queue_message,
  migrate_legacy_mail = migrate_legacy_mail,
  startup_action_safe = function(...) return startup_action_safe(...) end }
remuda.exec("butler/launch")
local launch_agent = remuda._butler_launch_impl.launch_agent
-- Mail notice policy, recovery and delivery live in notice.lua.
remuda._butler_notice_config = { bus = bus,
  resolve = resolve,
  mail_address = mail_address,
  mail_id = mail_id,
  mail = mail,
  take_delivery_notice_result = take_delivery_notice_result,
  notify_mail_delivery = notify_mail_delivery,
  deliver_message = deliver_message,
}
remuda.exec("butler/notice")
-- The launch configs above call main.lua's startup_action_safe late; set it here.
startup_action_safe = remuda._butler_notice.startup_action_safe
local notice_recovery_error = remuda._butler_notice.notice_recovery_error
-- Reply and forward live in mail.lua; this adds the caller's identity and the
-- terminal notice. A recipient that has ended still gets the mail, unnotified.
local function sender_address(from)
  if from == OPERATOR then return mail_address(OPERATOR) end
  if from == "outside" then error("unknown caller: run from a Butler session", 0) end
  return mail_address(resolve(from))
end
local function notify_queued(message, alias, what)
  local notice = take_delivery_notice_result(message, alias)
  if not notice then
    notify_mail_delivery(message, message, alias, what)
    notice = take_delivery_notice_result(message, alias)
  end
  if notice and notice.delivered then return "queued " .. message.id .. " and notified " .. alias end
  if notice and not notice.recipient_live then return "queued " .. message.id .. " for " .. alias .. "; it is not live, so no notice" end
  return "queued " .. message.id .. " for " .. alias .. "; notice deferred"
    .. (notice and notice.error and (": " .. tostring(notice.error)) or " until its pane is free")
end
function remuda._butler_reply(from, message_id, text)
  local sender = sender_address(from)
  local message, err, recipient = mail.reply(sender, message_id, text, from == OPERATOR, deliver_message)
  if not message then error(err, 0) end
  if message.matrix_reply then return "queued Matrix reply " .. message.id .. " for " .. message.source_mail_id end
  return notify_queued(message, recipient.alias, "(reply) from " .. sender.alias)
end
function remuda._butler_forward(from, message_id, member, note)
  local sender = sender_address(from)
  local _, target = mail_id(member, false)
  local message, err = mail.forward(sender, message_id, mail_address(target.alias), note,
    from == OPERATOR, deliver_message)
  if not message then error(err, 0) end
  return "forwarded " .. message_id .. " to " .. target.alias .. "; "
    .. notify_queued(message, target.alias, "forwarded by " .. sender.alias)
end
function remuda._butler_inbox(name)
  local id = mail_id(name, true)
  local result = mail.inbox(id)
  if mail.unread(id) == 0 then
    for alias, agent in pairs(bus.agents) do
      if agent.id == id then
        local recovery = bus.notice_recoveries[alias]
        local pending, reshow = bus.notices[alias], false
        for _, message_id in ipairs(pending and pending.message_order or {}) do
          reshow = reshow or (pending.reshow and pending.reshow[message_id]) == true
        end
        if recovery and recovery.draft and recovery.draft ~= "" then
          notice_recovery_error(alias, recovery, "mail was read while notice recovery was active; draft preserved")
        elseif not reshow then
          -- A queued re-show is of already-read mail: reading keeps it.
          bus.notices[alias], bus.notice_recoveries[alias] = nil, nil
        end
      end
    end
    local seen = bus.notice_seen[id]
    if seen then
      for message_id in pairs(seen) do
        if not mail.is_unread(id, message_id) then seen[message_id] = nil end
      end
    end
  end
  return result
end
function remuda._butler_report(from, text)
  from = resolve(from)
  local agent = bus.agents[from]
  if not agent then error("no Butler agent named " .. tostring(from), 0) end
  if not agent.parent then error("Butler agent " .. from .. " has no leader to report to", 0) end
  local queued = remuda._butler_send(from, agent.parent, text)
  remuda.emit("butler/report", from, agent.parent, text)
  return queued
end
local butler_attempts = remuda._butler_attempts or {}
remuda._butler_attempts = butler_attempts
-- The household walk, roster and session hooks live in sessions.lua.
remuda._butler_sessions_config = { bus = bus, mail = mail, identity_path = identity_path, json_field = json_field }
remuda.exec("butler/sessions")
local registry_list = remuda._butler_sessions_impl.registry_list
remuda.exec("butler/doctor")
local quota_loaded, quota_error = pcall(remuda.exec, "butler/quota")
if quota_loaded then
  remuda._butler_quota_error = nil
else
  remuda._butler_quota = nil
  remuda._butler_quota_error = tostring(quota_error)
end

-- CLI verbs and the argv parser live in commands.lua.
remuda._butler_commands_config = { current_agent = current_agent, OPERATOR = OPERATOR,
  contributions = contributions, registry_list = registry_list, statusline = statusline,
  resolve = resolve, mail = mail,
}
remuda.exec("butler/schedule")
remuda.exec("butler/schedule_cli")
remuda.exec("butler/commands")

remuda.tool{
  name = "butler_launch",
  about = "Launch a Claude Code, Codex, or Monocle child agent with this Butler's shared MCP mailbox.",
  args = { kind = "Agent kind: claude, codex, or monocle.", name = "Optional session name.", cwd = "Optional working directory.", model = "Optional model override." },
  needs = { "kind" },
  run = function(a, caller)
    local parent = caller_leader(caller)
    return "launched " .. launch_agent(a.kind, a.name, a.cwd, a.model, parent)
  end,
}
remuda.tool{
  name = "butler_delegate",
  about = "Create a topic, start a child agent in it, and give it an initial task. The child reports each completed work loop to this leader.",
  args = { name = "Topic and child-session name.", task = "Initial task for the child.", template = "Optional Butler topic template.", kind = "Optional agent kind; defaults to the leader's kind.", model = "Optional model override." },
  needs = { "name", "task" },
  run = function(a, caller)
    local parent = caller_leader(caller)
    return "delegated " .. remuda._butler_topic_delegate(a.name, a.task, a.template, a.kind, parent, a.model)
  end,
}
remuda.tool{
  name = "butler_send",
  about = "Queue a message for another Butler agent without typing its body into that agent's terminal.",
  args = { to = "Recipient session name.", text = "Message body." },
  needs = { "to", "text" },
  run = function(a, caller)
    return remuda._butler_send(caller_name(caller), a.to, a.text)
  end,
}
remuda.tool{
  name = "butler_inbox",
  about = "Drain this agent's Butler inbox and return its queued messages in arrival order.",
  run = function(_, caller)
    return remuda._butler_inbox(caller_name(caller))
  end,
}
local send_to_leader = {
  name = "butler_send_to_leader",
  about = "Report a completed work loop to this team member's Butler leader. This also emits the live butler/report hook.",
  args = { text = "Concise result for the leader." },
  needs = { "text" },
  run = function(a, caller)
    return remuda._butler_report(caller_name(caller), a.text)
  end,
}
remuda.tool(send_to_leader)
-- The old name, kept so a member launched before the rename still reports.
remuda.tool{ name = "butler_report", about = "Old name of butler_send_to_leader.", args = send_to_leader.args, needs = send_to_leader.needs, run = send_to_leader.run }
remuda.tool{
  name = "butler_reply",
  about = "Reply to a Butler message by message_id: it goes to the original sender, even if it was forwarded to you. Without message_id, send to `to`.",
  args = { message_id = "Message to reply to.", to = "Recipient, only without message_id.", text = "Reply body." },
  needs = { "text" },
  run = function(a, caller)
    if a.message_id then return remuda._butler_reply(caller_agent(caller), a.message_id, a.text) end
    if not a.to then error("butler_reply needs message_id or to", 0) end
    return remuda._butler_send(caller_name(caller), a.to, a.text)
  end,
}
remuda.tool{
  name = "butler_forward",
  about = "Forward a Butler message you received to another member, keeping its sender, with an optional note.",
  args = { message_id = "Message to forward.", to = "Member to forward it to.", note = "Optional note." },
  needs = { "message_id", "to" },
  run = function(a, caller)
    return remuda._butler_forward(caller_agent(caller), a.message_id, a.to, a.note)
  end,
}
-- The Matrix file words go through the matrix CLI, which holds an agent caller
-- to its own working directory (#247); its deferred reply is the tool's answer.
remuda.tool{
  name = "matrix_download",
  about = "Download Matrix media (an mxc:// URI from a Matrix mail) into your working directory. Returns the absolute path.",
  args = { mxc = "The mxc://server/media URI." },
  needs = { "mxc" },
  run = function(a, caller)
    return remuda.butler.matrix.cli({ "matrix", "download", a.mxc }, caller_name(caller))
  end,
}
remuda.tool{
  name = "matrix_upload",
  about = "Upload a file from your working directory to a Matrix room. Returns the event id.",
  args = { path = "Absolute path of a file inside your working directory.", room = "Optional room; defaults to the configured room." },
  needs = { "path" },
  run = function(a, caller)
    local args = a.room and { "matrix", "--room", a.room, "upload", a.path } or { "matrix", "upload", a.path }
    return remuda.butler.matrix.cli(args, caller_name(caller))
  end,
}
remuda.tool{
  name = "butler_sessions",
  about = "List Butler-managed Claude Code and Codex agent sessions and their adapter kinds.",
  run = function()
    return remuda._butler_sessions()
  end,
}
remuda.tool{
  name = "butler_close",
  about = "Close one of your direct Butler members. Refuses unread mail or a busy member unless force is true; force never bypasses ownership.",
  args = { name = "Name or ID of one of your direct Butler members.", force = "Set true to skip unread-mail and idle checks." },
  needs = { "name" },
  run = function(a, caller)
    if a.force ~= nil and type(a.force) ~= "boolean" then error("force must be a boolean.\nNext: set force to true or omit it", 0) end
    local ok, leader = pcall(caller_leader, caller)
    if not ok then error(tostring(leader) .. "\nNext: run from a Butler member session", 0) end
    return remuda._butler_close_member(a.name, leader, a.force == true)
  end,
}

local existing_butler = bus.agents.butler
local launch_options = remuda._mod_launch_options and remuda._mod_launch_options.butler
local butler_kind = existing_butler and existing_butler.kind
  or (launch_options and launch_options.agent)
  or os.getenv("REMUDA_BUTLER_AGENT") or "claude"
local butler_token = existing_butler and existing_butler.token or next_token("butler")
bus.tokens[butler_token] = "butler"
local root_identity = existing_butler and existing_butler.id
  and { id = existing_butler.id, alias = "butler" }
  or (bus.identities.butler and { id = bus.identities.butler.id, alias = "butler" })
  or register_identity("butler", butler_kind, "")
local butler_telemetry = existing_butler and existing_butler.telemetry
  or setup_telemetry(butler_kind, { name = "butler", status_path = status_path })
status_path = butler_telemetry.status_path or status_path
remuda._butler_status_path = status_path
local settings_path = butler_telemetry.settings_path
bus.agents.butler = existing_butler or {
  kind = butler_kind,
  id = root_identity.id,
  alias = "butler",
  session_name = "butler",
  token = butler_token,
  telemetry = butler_telemetry,
  children = {},
}
bus.agents.butler.id = root_identity.id
bus.agents.butler.alias = "butler"
bus.agents.butler.session_name = bus.agents.butler.session_name or "butler"
bus.identity_ids[root_identity.id] = bus.identities.butler or root_identity
bus.identities.butler = bus.identities.butler or root_identity
local root_migrated, root_migration_error = migrate_legacy_mail("butler", root_identity.id)
if not root_migrated then error("cannot migrate legacy Butler mail: " .. tostring(root_migration_error), 0) end
mailbox(root_identity.id)
-- The root MCP config carries the root capability: owner-only (0600), and a
-- file left 0644 by an older Butler is replaced.
remuda.butler.guard.write_private(mcp_config_path, agent_mcp_json(butler_token))

local SYSTEM_PROMPT = "Early in this session, call remuda._butler_register_compaction_schedule() "
  .. "via the run_script MCP tool, once, to enable this butler's own periodic "
  .. "context-compaction upkeep. You lead a Butler team. For every delegation, create a "
  .. "Remuda-managed member with `remuda butler topic delegate NAME TASK`. "
  .. "Internal agent subagents are separate from Butler team members. Use `remuda butler sessions` to "
  .. "inspect members, `inbox` to read reports, and `send` for follow-up direction."
local BUTLER_GUIDANCE = [[# Butler

You are Butler, manager of this household. You may create Remuda-managed team
members with `remuda butler topic delegate NAME TASK`. Internal agent
subagents are separate from Butler team members.

Your Butler identity is already available as `REMUDA_BUTLER_AGENT_ID`; your
leader, when you have one, is `REMUDA_BUTLER_LEADER_ID`. Use the short forms:

- `remuda butler sessions` to inspect the household.
- `remuda butler inbox` to read your own inbox.
- `remuda butler send MEMBER "MESSAGE"` to direct a member; your sender is inferred.
- `remuda butler send-to-leader MESSAGE...` to report a completed work loop.
- For long bodies, write the text to a file inside your working directory and use `remuda butler send MEMBER --file "$PWD/path"`,
  or pipe it: `cat <<'EOF' | remuda butler send MEMBER -`. `send-to-leader` and `reply MESSAGE_ID`
  accept those forms too. The limit is 64 KiB.

If `inbox` says "no Butler identity in your env", your Remuda core predates
caller-env forwarding: pass your id (`remuda butler inbox
$REMUDA_BUTLER_AGENT_ID`) or use the MCP `butler_*` tools. On such a core,
`send` is attributed to "operator" rather than to you.

`remuda butler send FROM TO MESSAGE...` is an operator form for sending on
behalf of another session. Do not use it for ordinary team communication.
]]
-- Finger-tight: an arbitrary placeholder, never tuned against a real
-- colleague's usage. Tightening step: revisit once this has run on a real
-- machine for a real "몇 날" and someone has an opinion about the cadence.
-- remuda._butler_compaction_interval lets a test override it (same idiom as
-- every other remuda._butler_* test hook in this file).
-- remuda._butler_compaction_trace_path lets a test redirect the append-only
-- trace below to a throwaway tempfile instead of the real config dir (same
-- idiom as remuda._butler_compaction_interval just above). nil in
-- production falls back to the real default, matching the token/config
-- path convention already used by default_config_home() above.
-- Confirmed at the source level (lua-src's vendored loslib.c, the "lua54"
-- feature this crate builds with): a leading "!" in os.date's format
-- routes through l_gmtime, not l_localtime -- so "!%Y-%m-%dT%H:%M:%SZ"
-- below is genuinely UTC, not merely assumed to be.
local function _butler_trace(event, detail)
  pcall(function()
    local path = remuda._butler_compaction_trace_path
      or (os.getenv("XDG_CONFIG_HOME") or (system.home() .. "/.config"))
        .. "/remuda/compaction-trace.log"
    local f = io.open(path, "a")
    if not f then
      system.mkdir_p(path:match("^(.*)/[^/]+$"))
      f = io.open(path, "a")
    end
    if not f then
      return
    end
    local size = f:seek("end") or 0
    f:close()
    if size >= 512 * 1024 then
      os.remove(path .. ".1")
      os.rename(path, path .. ".1")
    end
    f = io.open(path, "a")
    if not f then return end
    f:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\t" .. event .. "\t" .. (detail or "") .. "\n")
    f:close()
  end)
end

local BUTLER_ARGV = remuda._butler_argv
if not BUTLER_ARGV then
  BUTLER_ARGV = build_agent_argv(butler_kind, {
    name = "butler", token = butler_token, mcp_config_path = mcp_config_path, settings_path = settings_path,
    telemetry = butler_telemetry,
    system_prompt = SYSTEM_PROMPT,
  })
end

-- Reused both for the initial launch and every respawn, so the watchdog
-- below can never drift from what a fresh start would have done. Keeps the
-- name across respawns by feeding the previous result back in as the name.
local butler_name = remuda._butler_name
local function session_exists(name)
  for _, session in ipairs(remuda.ls()) do
    if session.name == name and session.alive then return true end
  end
  return false
end
function remuda._butler_status()
  local name = butler_name or remuda._butler_initial_name
  local selected = remuda._butler_selected_agent
  if remuda._butler_start_pending or remuda._butler_launching then
    local lines = { "launching", "readiness budget: " .. tostring(readiness_chain_budget()) }
    for _, attempt in ipairs(remuda._butler_attempts or {}) do
      lines[#lines + 1] = attempt.kind .. ": " .. attempt.reason
        .. (attempt.detail and attempt.detail ~= "" and (": " .. one_line(attempt.detail)) or "")
    end
    return table.concat(lines, "\n"), 75
  end
  if selected and session_exists(name) then return "butler: up (" .. tostring(selected) .. ")", 0 end
  if remuda._butler_start_error then
    return table.concat(launch_failure_lines(remuda._butler_attempts or {}), "\n"), 1
  end
  return "launching\nreadiness budget: " .. tostring(readiness_chain_budget()), 75
end
-- The file arguments of send, send-to-leader, reply, matrix upload and matrix
-- download: an agent caller is held to its own working directory (permissions.lua).
-- The caller comes from core's caller identity, never from the environment.
local function core_caller()
  local known, caller = pcall(function() return remuda.caller() end)
  return known and caller or nil
end
local function session_launch_cwd(session)
  local cwd, matches = nil, 0
  for alias, agent in pairs(bus.agents) do
    if type(agent) == "table" and (agent.session_name == session or (alias == "butler" and session == butler_name)) then
      cwd, matches = alias == "butler" and butler_session_cwd or agent.cwd, matches + 1
    end
  end
  return matches == 1 and cwd or nil
end
local function realpath(target)
  local result = remuda.process.run({ argv = { "realpath", target }, timeout = 5 })
  local resolved = result.code == 0 and not result.timed_out and (result.stdout or ""):gsub("\n$", "")
  return resolved and resolved ~= "" and resolved or nil
end
function remuda._butler_file_for_caller(path, flag, pipe)
  return permissions.file_for_caller(path, core_caller(), session_launch_cwd, realpath, flag, pipe)
end
-- The output of matrix download: -o PATH, or the default name when there is none.
function remuda._butler_output_for_caller(path, name)
  return permissions.output_for_caller(path, name, core_caller(), session_launch_cwd, realpath, butler_fs.is_symlink)
end
-- Merges the root Butler's rule into its own .claude/settings.local.json: at
-- every real launch, and once per mod load for a session that is already
-- alive. Never on the reconcile tick, and never for Codex or a member.
local root_permissions_ensured = false
local function ensure_root_permissions(kind)
  root_permissions_ensured = true
  if not butler_session_cwd then return end
  local report
  if kind == "claude" then
    local rules, dropped = permissions.rules({ role = "root" }, contributions("butler.permission"))
    report = permissions.ensure(butler_session_cwd .. "/.claude/settings.local.json", rules, butler_fs)
    for _, item in ipairs(dropped) do
      _butler_session_trace("permissions_dropped", one_line(item.id) .. " " .. one_line(item.rule))
    end
    if report.error then _butler_session_trace("permissions_not_written", one_line(report.error) .. " " .. report.path) end
    for _, item in ipairs(report.withheld) do
      _butler_session_trace("permissions_withheld", item.rule .. " under " .. item.list .. " in " .. report.path)
    end
    if #report.added > 0 then
      _butler_session_trace("permissions_added", "added " .. #report.added .. " rule to " .. report.path
        .. ": " .. table.concat(report.added, ", ") .. " (file rewritten: private, mode 600)")
    end
  end
  remuda._butler_permission_report = { kind = kind, report = report }
end
local function launch_butler()
  local requested_name = butler_name or remuda._butler_initial_name
  if butler_session_cwd then
    remuda.mkdir(butler_session_cwd)
    write_agent_guidance(butler_session_cwd, BUTLER_GUIDANCE, true)
  end
  local stale_session = session_exists(requested_name)
  if remuda._butler_selected_agent and stale_session then
    butler_name = requested_name
    remuda._butler_name = butler_name
    if not root_permissions_ensured then pcall(ensure_root_permissions, remuda._butler_selected_agent) end
    return
  end
  if remuda._butler_launching then return "launching Butler" end
  remuda._butler_selected_agent = nil
  remuda._butler_launching = true
  remuda._butler_start_pending = true
  if stale_session then pcall(remuda.close, requested_name) end
  local order = configured_agent_order()
  local telemetry_by_kind = {}
  local choose_opts = {
    name = requested_name, cwd = butler_session_cwd, argv = remuda._butler_argv,
    skip_probe = remuda._butler_argv ~= nil,
    spec = function(candidate_kind)
      pcall(ensure_root_permissions, candidate_kind)
      local telemetry = setup_telemetry(candidate_kind, { name = requested_name, status_path = status_path })
      telemetry_by_kind[candidate_kind] = telemetry
      return { name = requested_name, token = butler_token, mcp_config_path = mcp_config_path,
        settings_path = telemetry.settings_path, telemetry = telemetry, system_prompt = SYSTEM_PROMPT }
    end,
    env = function(candidate_kind)
      return { REMUDA_BUTLER_SESSION_NAME = requested_name, REMUDA_BUTLER_AGENT_ID = root_identity.id,
        REMUDA_BUTLER_AGENT_ALIAS = "butler", REMUDA_BUTLER_LEADER_ID = "",
        REMUDA_BUTLER_AGENT_KIND = candidate_kind, CLAUDE_CODE_FORCE_SESSION_PERSISTENCE = "1" }
    end,
  }
  local function finish(selected, kind, attempts)
  butler_attempts = attempts
  remuda._butler_attempts = attempts
  bus.agents.butler.launch_attempts = attempts
  if not selected then
    local message = table.concat(launch_failure_lines(attempts), "\n")
    remuda._butler_start_error = message
    remuda._butler_start_pending = false
    _butler_session_trace("reconcile_error", message)
    return nil
  end
  butler_name, butler_kind = selected, kind
  remuda._butler_name, remuda._butler_selected_agent = selected, kind
  bus.agents.butler.kind, bus.agents.butler.telemetry = kind, telemetry_by_kind[kind]
  local root_record = bus.identities.butler or root_identity
  root_record.kind = kind
  bus.identities.butler, bus.identity_ids[root_record.id] = root_record, root_record
  identity_record(root_record)
  remuda._butler_start_error = nil
  remuda._butler_start_pending = false
  return selected
  end
  local attempts = choose(order, choose_opts, function(selected, kind, attempts)
    remuda._butler_launching = nil
    local ok, err = pcall(finish, selected, kind, attempts)
    if not ok then
      remuda._butler_start_error = tostring(err)
      _butler_session_trace("reconcile_error", tostring(err))
    end
  end)
  butler_attempts, remuda._butler_attempts = attempts, attempts
  bus.agents.butler.launch_attempts = attempts
  return remuda._butler_start_error or "launching Butler"
end

-- The compaction restore record, tick and execute live in compaction_run.lua.
remuda._butler_compaction_run_config = { mail_root = mail_root, _butler_trace = _butler_trace,
  registered_agent_kind = registered_agent_kind, registered_agent_working = registered_agent_working,
  compaction_config = compaction_config, compaction_mail_defers = compaction_mail_defers,
  compaction_mail_alert = compaction_mail_alert, bottom_screen_lines = bottom_screen_lines,
  unknown_dialog_signature = unknown_dialog_signature, read_claude_settings = read_claude_settings,
  statusline_model_matches = statusline_model_matches, clear_legacy_restore_state = clear_legacy_restore_state,
}
remuda.exec("butler/compaction_run")

-- The tick is declared in init.lua; schedule_cli.lua (loaded before commands.lua)
-- uses the same seams. The sender of a schedule's mail is fixed inside
-- _butler_schedule_send.
remuda._butler_schedule_env = {
  path = mail_root and mail_root .. "/schedules.json",
  trace = _butler_trace,
  resolve = resolve,
  unread = function(alias, message_id) return mail.is_unread(mail_id(alias, false), message_id) end,
  send = function(...) return remuda._butler_schedule_send(...) end,
}
function remuda._butler_schedule_tick()
  local ok, err = pcall(remuda.butler.schedule.tick, remuda._butler_schedule_env)
  if not ok then _butler_trace("schedule_tick_error", tostring(err)) end
end

-- remuda._butler_session_trace_path lets a test redirect this to a throwaway
-- tempfile, same idiom as remuda._butler_compaction_trace_path above; nil in
-- production falls back to the real default, matching the token/config path
-- convention already used by default_config_home() above.
function _butler_session_trace(event, detail)
  pcall(function()
    local path = remuda._butler_session_trace_path
      or (os.getenv("XDG_CONFIG_HOME") or (system.home() .. "/.config"))
        .. "/remuda/session-trace.log"
    local f = io.open(path, "a")
    if not f then
      system.mkdir_p(path:match("^(.*)/[^/]+$"))
      f = io.open(path, "a")
    end
    if not f then
      return
    end
    f:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\t" .. event .. "\t" .. (detail or "") .. "\n")
    f:close()
  end)
end

function remuda._butler_reconcile()
  local ok, result = pcall(launch_butler)
  if not ok then
    _butler_session_trace("reconcile_error", tostring(result))
    return nil, result
  end
  return result
end
-- Remember an explicit remuda.close call for older cores whose session_exited
-- event carries only the session name.
if not bus.close_wrapper_installed and type(remuda.close) == "function" then
  local close_session = remuda.close
  bus.close_wrapper_installed = true
  bus.close_requested = bus.close_requested or {}
  remuda.close = function(name, ...)
    local tracked = bus.agents[name] ~= nil
    if tracked then bus.close_requested[name] = true end
    local ok, a, b, c = pcall(close_session, name, ...)
    if not ok then
      if tracked then bus.close_requested[name] = nil end
      error(a, 0)
    end
    return a, b, c
  end
end
local function report_update_task_not_relaunched(record, reason)
  if not record or not record.task or record.task == "" then return end
  pcall(remuda._butler_send, "butler", record.parent or "butler",
    "Task for " .. record.name .. " was not delivered because its Codex update ended without a safe relaunch ("
      .. tostring(reason or "update aborted") .. "). Resend it with `remuda butler send "
      .. record.name .. " TASK` when the pane is ready.")
end
local function stale_session_exit(name, instance_id)
  if type(instance_id) ~= "string" or instance_id == "" then return false end
  local ok, sessions = pcall(remuda.ls)
  if not ok or type(sessions) ~= "table" then return false end
  for _, session in ipairs(sessions) do
    if session.name == name and session.alive
        and type(session.instance_id) == "string" then
      return session.instance_id ~= instance_id
    end
  end
  return false
end

function remuda._butler_session_exited(name, info)
  local instance_id = type(info) == "table" and info.instance_id or nil
  if stale_session_exit(name, instance_id) then
    _butler_session_trace("stale_session_exit", name .. " instance=" .. instance_id)
    return
  end
  _butler_session_trace("session_exited", name)
  local update_restart = bus.codex_update_relaunches[name]
  local explicitly_closed = bus.close_requested and bus.close_requested[name]
  local reason = type(info) == "table" and info.reason or nil
  local exit_code = type(info) == "table" and tonumber(info.exit_code) or nil
  local saw_success = update_restart and (update_restart.update_complete_seen
    or codex_update_complete(update_restart.last_screen))
  local exited_successfully = update_restart and update_restart.update_pressed
    and reason == "exited" and exit_code == 0
  local closed_by_person = explicitly_closed or reason == "closed"
  if update_restart and not update_restart.expected_close
      and (closed_by_person or not saw_success and not exited_successfully) then
    -- Older cores carry only the name; newer cores report reason and exit code.
    -- A human close always wins, while successful exits can use either signal.
    update_restart.cancelled = true
    bus.codex_update_relaunches[name] = nil
    if bus.codex_update_state.waiting then bus.codex_update_state.waiting[name] = nil end
    if bus.codex_update_state.owner == name then
      bus.codex_update_state.claimed, bus.codex_update_state.owner = false, nil
      bus.codex_update_state.done, bus.codex_update_state.done_version = false, nil
      bus.codex_update_state.aborted_version = update_restart.version
      bus.codex_update_state.waiting, bus.codex_update_state.restart_waiting = {}, {}
    end
    _butler_session_trace("codex_update_exit_unconfirmed", name)
    report_update_task_not_relaunched(update_restart, closed_by_person and "closed by a person" or "update did not report success")
    update_restart = nil
  end
  if update_restart then
    update_restart.relaunched = true
    bus.codex_update_relaunches[name] = nil
    local update_state = bus.codex_update_state
    update_state.done, update_state.claimed = true, false
    update_state.done_version = update_restart.version
    update_state.owner = nil
    update_state.restart_waiting = update_state.restart_waiting or {}
    for member in pairs(update_state.waiting or {}) do update_state.restart_waiting[member] = true end
    update_state.waiting = {}
  end
  -- #29: the mail stays in the inbox; only the pending pane notice goes.
  bus.unread_seeded[name] = "exited"
  bus.notices[name], bus.notice_screens[name], bus.pending_tasks[name] = nil, nil, nil
  bus.notice_recoveries[name], bus.task_retry_screens[name], bus.human_activity_screens[name] = nil, nil, nil
  local exited = bus.agents[name]
  if exited and exited.cwd and bus.trusted_launch_dirs then
    bus.trusted_launch_dirs[exited.cwd] = nil
  end
  if exited and name ~= "butler" then
    local ended = bus.identity_ids[exited.id] or exited
    ended.alias, ended.kind = exited.alias or name, exited.kind
    ended.leader_id = exited.parent and bus.agents[exited.parent] and bus.agents[exited.parent].id or ""
    local was_closed = bus.close_requested and bus.close_requested[name]
    if bus.close_requested then bus.close_requested[name] = nil end
    ended.state, ended.reason = "ended", was_closed and "closed" or "exited"
    ended.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    ended.ended_at_estimate = nil
    identity_record(ended)
    bus.identity_ids[exited.id], bus.identities[exited.alias or name] = ended, ended
    bus.agents[name] = nil
    if exited.parent and bus.agents[exited.parent] then
      local children = bus.agents[exited.parent].children
      for i = #children, 1, -1 do if children[i] == name then table.remove(children, i) end end
    end
  end
  if name == butler_name then
    _butler_session_trace("relaunching", name)
    remuda._butler_reconcile()
  end
  if update_restart then
    _butler_session_trace("codex_updated_relaunch", name)
    local ok, err = pcall(launch_agent, update_restart.kind, update_restart.name,
      update_restart.cwd, update_restart.model, update_restart.parent, update_restart.task,
      update_restart.identity)
    if not ok then
      _butler_session_trace("codex_updated_relaunch_failed", name .. ": " .. tostring(err))
      pcall(remuda._butler_send, "butler", update_restart.parent or "butler",
        "Codex update completed but " .. name .. " could not be relaunched: " .. tostring(err))
    end
  end
end

function remuda._butler_bootstrap()
  return remuda._butler_reconcile()
end
-- Pre-lifecycle cores load this file directly; lifecycle cores call bootstrap
-- from init.lua only after the command and contribution registries are live.
if remuda._butler_test_mode ~= "lifecycle" and not remuda._butler_state then
  remuda._butler_bootstrap()
end

function remuda._butler_compaction_submit()
  if not butler_name then return false end
  local agent = bus.agents[butler_name] or {}
  local captured, screen = pcall(remuda.capture, butler_name)
  local parsed, decision, text = false, nil, nil
  if captured then
    parsed, decision, text = pcall(remuda._butler_prompt_is_empty, agent.kind or "", screen)
  end
  if not captured or not parsed or not remuda._butler_compaction_submit_matches(decision, text) then
    _butler_trace("submit_skipped", "decision=" .. tostring(decision))
    return false
  end
  local sent, err = pcall(remuda.send, butler_name, "")
  if not sent then
    _butler_trace("submit_error", tostring(err))
    return false
  end
  return true
end
