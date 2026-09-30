-- The module owns every hook and schedule. main.lua loads the implementation
-- from the lifecycle start event, where #143 also owns its imperative command
-- and contribution registrations.
if not getmetatable(_G) then
  -- Cores before warmblood-kr/remuda#98 send this entry as a plain chunk.
  return remuda.exec("butler")
end

local host = getmetatable(_G).__index.remuda
local booted, main_loaded = false, false
local function load_main()
  if main_loaded then return end
  main_loaded = true
  host.exec("butler/main")
end
local function start_matrix_relay()
  local matrix = host.butler and host.butler.matrix
  if host._butler_matrix_config and matrix and matrix.relay and not host._butler_skip_relay
    and type(host.http) == "table" and type(host.http.request) == "function" then
    matrix.relay.start(host._butler_matrix_config)
  end
end

local function boot()
  if booted then return end
  booted = true
  load_main()
  if host._butler_bootstrap and host._butler_test_mode ~= "lifecycle" then host._butler_bootstrap() end
  host.emit("butler-start")
  start_matrix_relay()
end

-- Retire only the process handle recorded by the legacy Matrix relay. The
-- handle is scoped to this Remuda image; require its old script location to
-- match the exact path that the Butler module used under its install dir.
local function stop_legacy_matrix_relay()
  -- The pre-extraction Butler stored its relay in this host slot.
  -- It has no script-path argv to verify; the daemon-owned handle and current
  -- process membership are the identity boundary for this one-time upgrade stop.
  local old_id = host._butler_relay
  if old_id ~= nil then
    if type(host.processes) == "function" and type(host.kill) == "function" then
      for _, running_id in ipairs(host.processes()) do
        if running_id == old_id then
          pcall(host.kill, old_id)
          break
        end
      end
    end
    host._butler_relay = nil
  end

  local id = host._butler_matrix_relay
  if id == nil or type(host.processes) ~= "function" or type(host.kill) ~= "function" then return end
  local data_home = os.getenv("XDG_DATA_HOME")
  if not data_home or data_home == "" then data_home = (os.getenv("HOME") or "") .. "/.local/share" end
  local mod_dir = data_home .. "/remuda/mods/butler"
  local expected_script = mod_dir .. "/packages/butler/matrix_relay.py"
  local script = host._butler_matrix_relay_script_path or expected_script
  if script ~= expected_script or not script:match("^" .. mod_dir:gsub("([^%w])", "%%%1") .. "/") then return end
  for _, running_id in ipairs(host.processes()) do
    if running_id == id then
      pcall(host.kill, id)
      break
    end
  end
  host._butler_matrix_relay = nil
  host._butler_matrix_relay_script_path = nil
end

local fallback
if host._butler_start_fallback then host.cancel(host._butler_start_fallback) end
fallback = host.schedule({ name = "butler-start-fallback", every = 0.05, run = function()
  host.cancel(fallback)
  if host._butler_start_fallback == fallback then host._butler_start_fallback = nil end
  if not booted then
    io.stderr:write("butler: this remuda core ignores the lifecycle start hook"
      .. " (warmblood-kr/remuda#104); booted by fallback -- run `remuda upgrade`\n")
    boot()
  end
end })
host._butler_start_fallback = fallback

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return { compaction_enabled = false, active_choosers = {}, next_chooser_id = 0 } end,
  start = function(state)
    host._butler_state = state
    boot()
    stop_legacy_matrix_relay()
  end,
  stop = function(state)
    if host._butler_cancel_active_choosers then host._butler_cancel_active_choosers(state) end
    local matrix = host.butler and host.butler.matrix
    if matrix and matrix.relay then pcall(matrix.relay.stop)
    end
    stop_legacy_matrix_relay()
    if host._butler_start_fallback then host.cancel(host._butler_start_fallback) end
    host._butler_start_fallback = nil
  end,
  hooks = {
    { event = "butler-start", id = "boot", run = load_main },
    { event = "butler/deliver", id = "inbox", depth = 0,
      run = function(_, message)
        local ok, result = pcall(host._butler_inbox_delivery, message)
        if not ok then return { __butler_delivery_hook_error = tostring(result) } end
        return result
      end },
    { event = "session_exited", id = "identity", depth = -50,
      run = function(_, name, info)
        return host._butler_session_exited(name, info)
      end },
    { event = "butler-compaction-submit", id = "submit",
      run = function() return host._butler_compaction_submit() end },
  },
  schedules = {
    { name = "butler-notices", every = 1, run = function()
      if host._butler_deliver_notices then host._butler_deliver_notices() end
    end },
    { name = "butler-reconcile", every = host._butler_reconcile_interval or 2, run = function()
      if host._butler_reconcile then host._butler_reconcile() end
    end },
    { name = "butler-compaction", every = host._butler_compaction_interval or 45, run = function()
      local state = host._butler_state or host._butler_compaction_state
      if state and state.compaction_enabled and host._butler_compaction_tick then host._butler_compaction_tick() end
    end },
  },
  contributes = {
    ["butler.agent"] = {
      { id = "claude", order = 10, executable = "claude", requires = "claude",
        argv = function(_, spec) return host._butler_agent_builders.claude(spec) end,
        ready = function(_, screen) return screen:find("─\n❯", 1, true) ~= nil end,
        working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
        login = { "Please log in", "not logged in", "Authentication required", "Invalid API key", "Please run /login", "Select login method" },
        dialogs = function() return host._butler_agent_startup.claude.modals end },
      { id = "codex", order = 20, executable = "codex", requires = "codex",
        argv = function(_, spec) return host._butler_agent_builders.codex(spec) end,
        ready = function(_, screen) return screen:find("Ask Codex", 1, true) ~= nil end,
        working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
        login = { "Please log in", "not logged in", "Authentication required", "Sign in to continue", "Not authenticated" },
        dialogs = function() return host._butler_agent_startup.codex.modals end },
    },
    ["butler.guidance"] = {
      { id = "header", order = 10,
        agents_md = function(_, ctx)
          return [[# Butler team member

You are a Butler team member. Your leader is ]] .. ctx.parent .. [[. Work on the
task sent to this terminal. Your Butler identity is already in
`REMUDA_BUTLER_AGENT_ID`, and your leader is in `REMUDA_BUTLER_LEADER_ID`.
Start by running `remuda butler inbox` to read your welcome message.

]]
        end,
        prompt = function()
          return "You are a Butler team member. Start by running `remuda butler inbox` to read "
            .. "your welcome message, then read AGENTS.md in your working directory. "
        end },
      { id = "cli", order = 20,
        agents_md = function()
          return [[Use Butler's CLI for communication:

- `remuda butler inbox` reads your own queued messages.
- `remuda butler send MEMBER "MESSAGE"` sends a message; your sender is inferred.
- For long bodies, use `cat <<'EOF' | remuda butler send MEMBER -` or `--file "$PWD/path"`.
- `send-to-leader` and `reply MESSAGE_ID` accept `-` and `--file "$PWD/path"` too.
- Message bodies are limited to 64 KiB; short quoted messages can stay positional.
- `remuda butler send-to-leader RESULT...` reports a completed work loop.
- `remuda butler sessions` shows the household.
- `remuda butler reply MESSAGE-ID "TEXT"` answers a message in its thread (prefer this over send when answering)
- `remuda butler forward MESSAGE-ID MEMBER [NOTE]` passes a message on with an optional note

]]
        end,
        prompt = function()
          return "Use `remuda butler inbox`, `remuda butler send MEMBER \"MESSAGE\"`, and "
            .. "`remuda butler send-to-leader RESULT...` for coordination. Long bodies use "
            .. 'stdin (`-`) or `--file "$PWD/path"`; message bodies are limited to 64 KiB. '
        end },
      { id = "old-core", order = 30,
        agents_md = function()
          return [[If `inbox` says "no Butler identity in your env", your Remuda core predates
caller-env forwarding: pass your id (`remuda butler inbox
$REMUDA_BUTLER_AGENT_ID`) or use the MCP `butler_*` tools. On such a core,
`send` is attributed to "operator" rather than to you.

]]
        end },
      { id = "delegation", order = 40,
        agents_md = function()
          return [[You may create a Remuda-managed child team with `remuda butler topic delegate
NAME TASK...` when useful. Internal agent subagents are separate from Butler
team members. `remuda butler send FROM TO MESSAGE...` is an operator form, not
the normal way for a member to communicate.
]]
        end },
      { id = "matrix", order = 50,
        agents_md = function()
          return [[Matrix is the human-facing adapter: never call the homeserver REST API or curl directly; use `remuda butler matrix [OPTIONS] VERB ARGS`. Options go BEFORE the verb (`--json` for machine output; `--room ROOM` defaults to the configured room).
- `status`: whoami, joined rooms, and the sync cursor.
- `[-n N] history`: recent messages in the room.
- `rooms`: joined rooms (read-only).
- `thread EVENT_ID`: all replies in a thread.
- `event EVENT_ID` (alias `get`): one event.
- `send TEXT`: post a message (long text is split, rate-limited); `send -` is refused until core #213.
- `reply EVENT_ID TEXT` / `react EVENT_ID KEY`: answer or react (same room only).
- `upload PATH`: post a file (up to 20 MB). `[-o PATH] download MXC`: fetch media.
- `redact EVENT_ID [--reason TEXT]`: remove your message.
]]
        end,
        prompt = function()
          return "For Matrix, use `remuda butler matrix VERB`; never call Matrix REST or curl directly. "
        end },
      { id = "leader", order = 90,
        prompt = function(_, ctx) return "Your leader is " .. ctx.parent .. "." end },
    },
    ["butler.command"] = {
      { id = "close", order = 8, verb = "close", usage = "  remuda butler close <name> [--force]",
        run = function(_, args, caller) return host._butler_command_run("close", args, caller) end },
      { id = "doctor", order = 5, verb = "doctor", usage = "  remuda butler doctor",
        run = function(_, args, caller) return host._butler_command_run("doctor", args, caller) end },
      { id = "compact", order = 16, verb = "compact", usage = "  remuda butler compact <session> [--dry-run|--force]",
        run = function(_, args)
          if not args[2] or args[2] == "" then return nil end
          if not host._butler_compaction_has_session(args[2]) then
            local message = "unknown session: " .. args[2]
            if type(host.fail) == "function" then return host.fail(message, 1) end
            error(message, 0)
          end
          if #args == 3 and args[3] == "--dry-run" then
            return host._butler_compaction_tick(args[2], true)
          end
          if #args == 3 and args[3] == "--force" then
            return host.butler.compact(args[2], true)
          end
          if #args ~= 2 then return nil end
          return host.butler.compact(args[2], false)
        end },
      { id = "sessions", order = 10, verb = "sessions", usage = "  remuda butler sessions",
        run = function(_, args, caller) return host._butler_command_run("sessions", args, caller) end },
      { id = "status", order = 12, verb = "status", usage = "  remuda butler status  (0=up, 75=launching, 1=failed)",
        run = function(_, args, caller) return host._butler_command_run("status", args, caller) end },
      { id = "agents", order = 15, verb = "agents", usage = "  remuda butler agents [--all]",
        run = function(_, args, caller) return host._butler_command_run("agents", args, caller) end },
      { id = "launch", order = 20, verb = "launch", usage = "  remuda butler launch <claude|codex> [name] [--model M]",
        run = function(_, args, caller) return host._butler_command_run("launch", args, caller) end },
      { id = "topic", order = 30, verb = "topic", usage = "  remuda butler topic new <name> [--template T] [--agent A] [--model M]\n"
          .. "  remuda butler topic delegate <name> [--agent A] [--leader L] [--model M] <task...>",
        run = function(_, args, caller) return host._butler_command_run("topic", args, caller) end },
      { id = "send", order = 40, verb = "send", usage = '  remuda butler send <to> "<message>" | <to> - | <to> --file PATH\n'
          .. '  remuda butler send <from> <to> <message...> | <from> <to> - | <from> <to> --file PATH',
        run = function(_, args, caller) return host._butler_command_run("send", args, caller) end },
      { id = "send-to-leader", order = 50, verb = "send-to-leader", usage = "  remuda butler send-to-leader <message...> | - | --file PATH",
        run = function(_, args, caller) return host._butler_command_run("send-to-leader", args, caller) end },
      { id = "inbox", order = 60, verb = "inbox", usage = "  remuda butler inbox [name]",
        run = function(_, args, caller) return host._butler_command_run("inbox", args, caller) end },
      { id = "reply", order = 70, verb = "reply", usage = "  remuda butler reply <message-id> <message...> | - | --file PATH",
        run = function(_, args, caller) return host._butler_command_run("reply", args, caller) end },
      { id = "forward", order = 80, verb = "forward", usage = "  remuda butler forward <message-id> <member> [note...]",
        run = function(_, args, caller) return host._butler_command_run("forward", args, caller) end },
      { id = "matrix", order = 100, verb = "matrix",
        usage = [[  remuda butler matrix [--json] status
  remuda butler matrix [--json] rooms
  remuda butler matrix [--json] [--room ROOM] [-n N] history
  remuda butler matrix [--json] [--room ROOM] thread EVENT_ID
  remuda butler matrix [--json] [--room ROOM] event|get EVENT_ID
  remuda butler matrix [--json] [-o PATH] download MXC
  remuda butler matrix [--json] [--room ROOM] send TEXT
  remuda butler matrix [--json] [--room ROOM] reply EVENT_ID TEXT
  remuda butler matrix [--json] [--room ROOM] react EVENT_ID KEY
  remuda butler matrix [--json] [--room ROOM] upload PATH
  remuda butler matrix [--json] [--room ROOM] redact EVENT_ID [--reason TEXT]
  remuda butler matrix [--json] join ROOM (operator)
  remuda butler matrix [--json] leave ROOM (operator)]],
        run = function(_, args, caller) return host._butler_command_run("matrix", args, caller) end },
    },
  },
}
