-- The module owns every hook and schedule. main.lua loads the implementation
-- from the lifecycle start event, where #143 also owns its imperative command
-- and contribution registrations.
if not getmetatable(_G) then
  -- Cores before warmblood-kr/remuda#98 send this entry as a plain chunk.
  return remuda.exec("butler")
end

local host = getmetatable(_G).__index.remuda
local cli_parse = assert(host.cli and host.cli.parse,
  "Butler CLI requires remuda.cli.parse (Remuda core #465 or later); upgrade Remuda")
local system, dialogs, input_originals
local booted, main_loaded = false, false
-- The exact compiled Matrix request client API from this activation. A failed
-- reload may overwrite the shared butler.matrix table; resume must republish
-- this handle rather than reread a possibly broken helper.
local request_client_api
local function capture_request_client()
  local matrix = host.butler and host.butler.matrix
  if matrix and type(matrix.request_resume) == "function" then
    request_client_api = { retire = matrix.request_retire, resume = matrix.request_resume }
  end
end
local function load_main()
  if main_loaded then return end
  main_loaded = true
  host.exec("butler/system")
  system = assert(host._butler_system)
  host.exec("butler/main")
  dialogs = host.butler and host.butler.dialogs
  input_originals = host._butler_dialog_originals
  capture_request_client()
end
local function start_matrix_relay()
  local matrix = host.butler and host.butler.matrix
  if host._butler_matrix_config and matrix and matrix.relay and not host._butler_skip_relay
    and not host._butler_standby
    and type(host.http) == "table" and type(host.http.request) == "function" then
    matrix.relay.start(host._butler_matrix_config)
  end
end

local function boot()
  if booted then return end
  -- A commands-only standby loaded only the refusal verbs. Explicit start
  -- must re-ask the home locks inside this lifecycle transaction.
  if host._butler_standby then main_loaded = false end
  load_main()
  if host._butler_standby then
    main_loaded = false
    error(host.butler.guard.refusal(host._butler_standby), 0)
  end
  booted = true
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
  if not data_home or data_home == "" then
    local ok, home = pcall(system.home)
    if not ok then return end
    data_home = home .. "/.local/share"
  end
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

-- Core instantiates declared schedules only for an accepted activation. A
-- discarded exec candidate must neither create nor cancel a fallback timer.
local commands_only = false
local function cancel_start_fallback()
  -- Declared callbacks receive state, not their schedule handle. Find this
  -- activation's timer in the registry; older cores do not record an owner.
  for handle, schedule in pairs(host.schedules) do
    if schedule.name == "butler-start-fallback"
      and (schedule.owner == nil or schedule.owner == "butler") then
      host.cancel(handle)
    end
  end
  -- Retire the imperative timer left by a Butler version predating this fix.
  if host._butler_start_fallback then host.cancel(host._butler_start_fallback) end
  host._butler_start_fallback = nil
end

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return { compaction_enabled = false, active_choosers = {}, next_chooser_id = 0 } end,
  source_refresh_ready = function(state)
    if host._module_resume_supported ~= true then return "core lacks lifecycle resume; upgrade Remuda before source refresh" end
    if state.compaction_fleet_active then return "compaction is active" end
    for _, member in pairs(state.compaction_members or {}) do
      if member.compaction_in_progress or member.dialog_operation or member.restore_pending_attempt_active then
        return "compaction or model restoration is active"
      end
    end
    if dialogs and dialogs.source_refresh_busy and dialogs.source_refresh_busy() then return "input recovery is active" end
    if next(state.active_choosers or {}) then return "a launch chooser is active" end
    local controls = host.butler and host.butler.startup_controls
    if controls and type(controls.active_count) == "function" and controls.active_count() > 0 then
      return "a Codex startup control is active"
    end
    if host._butler_launching or host._butler_start_pending then return "Butler is starting" end
    local bus = host._butler_bus or {}
    -- A reload replaces the Lua image. Do not drop a native publication
    -- watcher or an in-flight native dispatch mid-delivery; the message is
    -- already durable mail, so waiting one refresh costs nothing.
    if next(bus.notice_native_watchers or {}) then
      return "native publication is waiting"
    end
    if next(bus.notice_native_dispatching or {}) then
      return "native delivery is in flight"
    end
    if next(bus.pending_tasks or {}) then return "mail delivery is pending" end
    for _, dialog in pairs(bus.dialog_states or {}) do
      if dialog.blocked or dialog.id or dialog.reporting then return "a managed dialog is active" end
    end
    local matrix = host.butler and host.butler.matrix
    if matrix and matrix.relay and matrix.relay.instance then return "Matrix relay is active" end
    local approval = host.butler and host.butler.approval
    if approval and type(approval.source_refresh_busy) == "function" and approval.source_refresh_busy() then
      return "an approval is pending"
    end
  end,
  -- Registers the CLI verbs only; `start` boots. Cores without the hook ignore this field.
  commands = function(state)
    commands_only = true
    host._butler_state = state
    if host._butler_standby then
      -- A refused start rolls back. Rediscovery preserves its refusal even
      -- if the owner has since gone; only an explicit start may take over.
      host.butler.guard.standby(host._butler_standby, host._butler_paths)
    else
      load_main()
    end
  end,
  start = function(state)
    host._butler_state = state
    boot()
    capture_request_client()
    stop_legacy_matrix_relay()
  end,
  -- Rollback restores this activation's registrations. Reinstall only resources
  -- stop() unwrapped; cached start/main closures must not reread a broken helper.
  resume = function(state)
    local ok, err = pcall(function()
      host._butler_state = state
      if dialogs then
        host.butler.dialogs = dialogs
        host._butler_dialog_originals = input_originals
        dialogs.install()
      end
      if request_client_api and type(request_client_api.resume) == "function" then
        -- Fresh empty epoch from the retained compiled client; no reread of a
        -- helper a failed activation may have replaced, and no replay of work
        -- the old stop already settled.
        request_client_api.resume()
      end
      if booted then start_matrix_relay() end
    end)
    if not ok then
      -- Never leave raw input exposed if the old activation cannot resume.
      -- Keep the originals for a later explicit, corrected activation.
      host._butler_dialog_originals = input_originals
      local function refuse() error("Butler input gate recovery failed; reload Butler when idle", 0) end
      host.key, host.type_text = refuse, refuse
      if input_originals and input_originals.send then host.send = refuse end
      error(err, 0)
    end
  end,
  stop = function(state)
    if dialogs then dialogs.stop() end
    local controls = host.butler and host.butler.startup_controls
    if controls and type(controls.stop_all) == "function" then pcall(controls.stop_all) end
    if host._butler_cancel_active_choosers then host._butler_cancel_active_choosers(state) end
    local matrix = host.butler and host.butler.matrix
    if matrix and matrix.relay then pcall(matrix.relay.stop)
    end
    -- Relay stop above fences generic retries; retire this request generation
    -- only after that, so a queued pre-dispatch item settles terminally instead
    -- of being retried by an outbox that is no longer active.
    local retire = request_client_api and request_client_api.retire
    if type(retire) ~= "function" and matrix then retire = matrix.request_retire end
    if type(retire) == "function" then pcall(retire) end
    stop_legacy_matrix_relay()
    cancel_start_fallback()
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
        if host._butler_session_exited then return host._butler_session_exited(name, info) end
      end },
    { event = "butler-compaction-submit", id = "submit",
      run = function()
        if host._butler_compaction_submit then return host._butler_compaction_submit() end
      end },
  },
  schedules = {
    -- Commands-only loads boot nothing. A core that ignores `start` still
    -- boots an accepted exec/reload once through this compatibility timer.
    { name = "butler-start-fallback", every = 0.05, run = function()
      cancel_start_fallback()
      if not booted and not commands_only then
        io.stderr:write("butler: this remuda core ignores the lifecycle start hook"
          .. " (warmblood-kr/remuda#104); booted by fallback -- run `remuda upgrade`\n")
        boot()
      end
    end },
    { name = "butler-notices", every = 1, run = function()
      if booted and host._butler_deliver_notices then host._butler_deliver_notices() end
    end },
    { name = "butler-dialogs", every = 1, run = function()
      if booted and host._butler_dialog_tick then host._butler_dialog_tick() end
    end },
    { name = "butler-reconcile", every = host._butler_reconcile_interval or 2, run = function()
      if booted and host._butler_reconcile and host._butler_reconcile_retry
          and host._butler_reconcile_retry.remaining_ms() <= 0 then
        host._butler_reconcile()
      end
    end },
    { name = "butler-done-autoclose", every = 30, run = function()
      if booted and host._butler_done_tick then host._butler_done_tick() end
    end },
    { name = "butler-schedule", every = 30, run = function()
      if booted and host._butler_schedule_tick then host._butler_schedule_tick() end
    end },
    { name = "butler-compaction", every = host._butler_compaction_interval or 45, run = function()
      local state = host._butler_state or host._butler_compaction_state
      if booted and state and state.compaction_enabled and host._butler_compaction_tick then host._butler_compaction_tick() end
    end },
  },
  contributes = {
    ["butler.agent"] = {
      { id = "claude", order = 10, executable = "claude", requires = "claude",
        argv = function(_, spec) return host._butler_agent_builders.claude(spec) end,
        -- Launch readiness only says the session reached a Claude composer, so it also accepts the joined
        -- dim 'Try "' hint (ConPTY). It is not permission to type: agents/claudecode.lua startup.ready keeps
        -- the empty-suffix match, and the unchanged composer gate (notice.lua) decides when to type.
        ready = function(_, screen)
          if screen:find("─\n❯", 1, true) then return true end
          for line in (screen .. "\n"):gmatch("(.-)\n") do
            local offset = 1
            while line:sub(offset, offset + 2) == "─" do offset = offset + 3 end
            if offset > 1 and line:sub(offset, offset + 2) == "❯" then
              local suffix = line:sub(offset + 3):gsub("^[ \t\194\160]+", "")
              if suffix == "" or suffix:sub(1, 5) == 'Try "' then return true end
            end
          end
          return false
        end,
        working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
        login = { "Please log in", "not logged in", "Authentication required", "Invalid API key", "Please run /login", "Select login method" },
        dialogs = function() return host._butler_agent_startup.claude.modals end },
      { id = "codex", order = 20, executable = "codex", requires = "codex",
        argv = function(_, spec) return host._butler_agent_builders.codex(spec) end,
        ready = function(_, screen) return screen:find("Ask Codex", 1, true) ~= nil end,
        working = function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
        login = { "Please log in", "not logged in", "Authentication required", "Sign in to continue", "Not authenticated" },
        dialogs = function() return host._butler_agent_startup.codex.modals end },
      { id = "opencode", order = 25, executable = "opencode", requires = "opencode", automatic = false,
        argv = function(_, spec) return host._butler_agent_builders.opencode(spec) end,
        -- The agent module owns the composer grammar. Delegate at call time so
        -- this declaration cannot drift from the startup/notice parser.
        ready = function(_, screen)
          local grammar = host._butler_agent_startup and host._butler_agent_startup.opencode
          return type(grammar) == "table" and type(grammar.ready) == "function"
            and grammar.ready(screen) == true
        end,
        working = function(_, screen)
          local grammar = host._butler_agent_startup and host._butler_agent_startup.opencode
          return type(grammar) == "table" and type(grammar.working) == "function"
            and grammar.working(screen) == true
        end,
        login = { "Authentication required", "Not authenticated", "Please log in" } },
      { id = "monocle", order = 30, executable = "monocle", requires = "monocle", automatic = false,
        argv = function(_, spec) return host._butler_agent_builders.monocle(spec) end,
        ready = function(_, screen) return host._butler_agent_startup.monocle.ready(screen) end,
        working = function(_, screen) return host._butler_agent_startup.monocle.working(screen) end,
        login = { "monocle login" } },
    },
    ["butler.guidance"] = {
      { id = "header", order = 10,
        agents_md = function(_, ctx)
          return [[# Butler team member

You are a Butler team member. Your leader is ]] .. ctx.parent .. [[. Work on the
task sent to this terminal. Your Butler identity is already in
`REMUDA_BUTLER_AGENT_ID`, and your leader is in `REMUDA_BUTLER_LEADER_ID`.
Start by running `remuda butler inbox` to read your welcome message.

## Memory

Keep useful notes under `docs/`. Put stable, reusable facts and decisions in
`docs/concepts/`; put dated events, progress, and context that may expire in
`docs/journal/YYYY-MM-DD.md`. Keep source files concise: each concepts file and
daily note must stay at or below 5,000 characters. Use at most 50 concepts
files; when full, delete low-value material, consolidate or compress existing
notes, or decline lower-priority material.

Summarize daily notes older than two ISO weeks into
`docs/journal/YYYY-Www.md` (use the correct ISO week year and week number), then
gzip the summarized daily files under `docs/journal/archive/`. These are
manual file practices; do not assume a process performs them automatically.

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
- For long bodies, write the text to a file inside your working directory and use `remuda butler send MEMBER --file "$PWD/path"`, or pipe it: `cat <<'EOF' | remuda butler send MEMBER -`.
- `send-to-leader` and `reply MESSAGE_ID` accept `-` and `--file "$PWD/path"` too.
- Message bodies are limited to 64 KiB; short quoted messages can stay positional.
- `remuda butler send-to-leader RESULT...` reports a completed work loop.
- `remuda butler sessions` shows the household.
- `remuda butler reply MESSAGE-ID -` (or `--file PATH`) answers a message in its thread; for Matrix mail it keeps the room and thread (prefer this over send when answering); answers to Matrix mail ALWAYS use this, never `remuda butler matrix send`.
- `remuda butler forward MESSAGE-ID MEMBER [NOTE]` passes a message on with an optional note
- Run `remuda butler ...` exactly as shown. Do not prefix it with REMUDA_NO_UPDATE_CHECK=1 or other VAR=value assignments: managed sessions never print the update banner, and a leading assignment can stop an allow rule such as Bash(remuda butler *) from matching.

]]
        end,
        prompt = function()
          return "Use `remuda butler inbox`, `remuda butler send MEMBER \"MESSAGE\"`, and "
            .. "`remuda butler send-to-leader RESULT...` for coordination; answer mail with "
            .. "`remuda butler reply MESSAGE-ID -` (or `--file PATH`). Long bodies use "
            .. 'stdin (`-`) or `--file "$PWD/path"`; message bodies are limited to 64 KiB. '
        end },
      { id = "schedule", order = 22,
        agents_md = function()
          return [[Use Butler's persistent schedule for recurring checks or delayed follow-ups
that should survive a Claude/Codex/OpenCode/Monocle session or harness change.
First check `remuda butler schedule list`. A schedule sends its fixed text as
timed mail; it does not run a shell command or CI job by itself. Read the mail
and perform the check it describes.

Schedules repeat. You can add one for your own session and remove the schedules
created by your current Butler identity:

`remuda butler schedule add NAME "*/20 * * * *" "Check CI and report its status."`

Your session is the target and the command itself is the confirmation. Adding
one starts standing mail from the reserved sender `schedule` at every due time,
also after restarts, until you remove it with `remuda butler schedule rm NAME`.
Ask the owner to add or remove a schedule for another session, or to manage
schedules from the terminal; there the add asks for confirmation and
`--to SESSION` names the target.

The schedule has five fields in the machine's local time: the minute is `N` or
`*/N` (steps 5, 6, 10, 12, 15, 20 or 30), the hour is `N` or `*`, then `* * *`.
This is not a one-shot timer or a general cron runner. Schedules can be skipped
if the target session is absent or still has unread mail from the previous
firing.

]]
        end },
      { id = "codex", order = 25,
        agents_md = function()
          return [[Codex members: use the MCP `butler_*` tools first (`butler_inbox`,
`butler_send`, `butler_reply`, `butler_send_to_leader`, `butler_forward`,
`butler_sessions`; `matrix_download` and `matrix_upload` for Matrix files). The
`remuda butler` CLI fails inside the Codex sandbox by
design (`Operation not permitted`). If you must use the CLI and get that error,
re-run the command requesting escalated permissions.

]]
        end },
      { id = "opencode", order = 26,
        agents_md = function()
          return [[OpenCode members: use the Butler MCP `butler_*` tools for coordination
and mailbox work. The Butler MCP server is configured for this member; first run
`remuda butler inbox` to read the task and recent mail.

]]
        end },
      { id = "old-core", order = 30,
        agents_md = function()
          return [[CLI identity comes from the daemon's caller session, never environment variables.
If Butler cannot identify the caller, run from a registered Butler session or
upgrade Remuda core. Older cores without caller fields refuse CLI member actions;
use the MCP `butler_*` tools with the session's configured capability instead.
Caller attribution is advisory within one user account, not an isolation boundary.

]]
        end },
      { id = "delegation", order = 40,
        agents_md = function()
          return [[You may create a Remuda-managed child team with `remuda butler topic delegate
NAME TASK...` when useful. Internal agent subagents are separate from Butler
team members. `remuda butler send --from FROM TO MESSAGE...` is an operator form, not
the normal way for a member to communicate.

## Delegation: STICC

When directing a member, explain the assignment using STICC, scaled to the task:

- **Situation:** the relevant context and current state.
- **Task:** the concrete work and expected deliverable.
- **Intent:** the objective and why it matters.
- **Concern:** constraints, risks, and known uncertainties.
- **Calibrate:** ask the member to confirm their understanding, raise concerns,
  and report progress or results so the plan can be adjusted.

Give enough context for independent action without unnecessary ceremony. If you
direct your own members, use STICC and tell them to propagate it.

### 5W1H as a planning aid

STICC frames a delegation. When the task is broad or ambiguous, use 5W1H inside it:

- **What:** the concrete deliverable and the done test.
- **Why:** the objective and the decision it supports.
- **Who:** the owner, requester, recipients, and who must approve.
- **When:** the deadline, ETA, and checkpoints.
- **Where:** the repo, path, environment, and where the result goes.
- **How:** the approach, constraints, and verification.

This is an optional thinking aid, not a required message format. Do not pad a
short or sensitive task with ceremony; ask only the questions that change the work.

### ETA and self-reminder

When you accept a delegated task, estimate a rough ETA before you start and state
it in your first progress note. If the work will likely take more than about 15
minutes or has an external wait, add a reminder to your own session at the ETA:

```
remuda butler schedule add eta-check "<M> <H> * * *" \
  "ETA reached: report progress to your leader or the owner, then remove this reminder: remuda butler schedule rm eta-check" --once
```

Use a short unique name in place of `eta-check`. This is a self-targeted reminder:
do not pass `--to`. With `--once` it delivers at the next matching time and then
disables itself; until it delivers it retries if your session is absent or its
previous mail is unread. It is still a minute/hour slot, not an absolute deadline:
use it only when the next matching minute/hour is within 24 hours, and pick the
next future minute (the current minute waits for the next day). For a longer ETA
use a nearer checkpoint or state the date in your report. Remove it after reporting
to keep the list clean, and replace it if the ETA moves. Skip it for short,
sensitive, or no-report tasks; state the ETA in the first report instead. Only your
own session is in scope; ask the owner for another session.

]]
        end,
        prompt = function()
          return "When you direct your own members, explain the assignment using STICC "
            .. "(Situation, Task, Intent, Concern, Calibrate) and tell them to propagate it. "
            .. "Use 5W1H as an optional planning aid when a task is broad. When you accept a "
            .. "task, estimate an ETA and, for work over about 15 minutes, add a self-targeted "
            .. "`remuda butler schedule` reminder; remove it after reporting. "
        end },
      { id = "matrix", order = 50,
        agents_md = function()
          return [[Matrix is the human-facing adapter: never call the homeserver REST API or curl directly; use `remuda butler matrix [OPTIONS] VERB ARGS`. Options go BEFORE the verb (`--json` for machine output; `--room ROOM` defaults to the configured room).
- `status`: whoami, joined rooms, and the sync cursor.
- `[-n N] history`: recent messages in the room.
- `rooms`: joined rooms (read-only).
- `thread EVENT_ID`: all replies in a thread.
- `follow EVENT_ID` / `unfollow EVENT_ID`: manage thread replies; HOME always delivers replies, while other rooms require a follow or mention. Replying, sending and a mention from an allowlisted sender follow automatically.
- `event EVENT_ID` (alias `get`): one event.
- `send TEXT`: start a NEW post only (name the room with `--room ROOM`); long text is split, rate-limited; `send -` reads the text from stdin (up to 64 KiB). Answers ALWAYS go via `remuda butler reply MESSAGE-ID -`, never send.
- `reply EVENT_ID TEXT` / `react EVENT_ID KEY`: answer or react (same room only).
- `upload PATH`: post a file (up to 20 MB). `[-o PATH] download MXC`: fetch media.
- `redact EVENT_ID [--reason TEXT]`: remove your message.
]]
        end,
        prompt = function()
          return "For Matrix, use `remuda butler matrix VERB`; never call Matrix REST or curl directly. `send TEXT` starts a NEW post only (name the room with `--room ROOM`); long text is split, rate-limited; `send -` reads the text from stdin (up to 64 KiB). Answers ALWAYS go via `remuda butler reply MESSAGE-ID -`, never send. "
        end },
      { id = "prepared-text", order = 60,
        agents_md = function()
          return [[

## Prepared text for owner approval

Use the `butler_approve_text` MCP tool or
`remuda butler approve-text request SESSION -` with the exact text on stdin to
register up to 8 KiB of normalized text for the owner to review in Matrix.
Registration needs live Matrix sync and prepared-text approval on. The
allowlisted owner approves or denies the posted request by reply or reaction;
the terminal `remuda butler approve` does not approve prepared text. Register
only the intended content and target, explain its purpose to the owner, and
never treat a request as approval. The post shows the request's expiry (default
30 minutes; the owner can configure `approval_ttl_minutes`). On approval Butler
checks the target session and attempts to type the stored, normalized text
once. `typed (seen)` is a screen observation, not proof that the agent acted;
an uncertain outcome requires inspection before a new request. The owner
controls the `approve-text on|off` switch at a terminal; `remuda butler doctor`
reports it.
]]
        end },
      { id = "leader", order = 90,
        prompt = function(_, ctx) return "Your leader is " .. ctx.parent .. "." end },
    },
    -- The rule merged into the root Butler's settings.local.json; an extension adds its own row.
    ["butler.permission"] = {
      { id = "cli", order = 10, rules = function(_, ctx) return host._butler_permissions.builtin(ctx) end },
    },
    ["butler.command"] = {
      { id = "close", order = 8, verb = "close",
        usage = "  remuda butler close <name> [--force]\n  remuda butler close --force <name>",
        run = function(_, args, caller) return host._butler_command_run("close", args, caller) end },
      { id = "doctor", order = 5, verb = "doctor", usage = "  remuda butler doctor",
        run = function(_, args, caller) return host._butler_command_run("doctor", args, caller) end },
      -- commands.lua registers the verb, but the exported catalog is what the
      -- host dispatches; an unlisted verb is unreachable from `remuda butler`.
      -- The forwarded run keeps the root-only caller check inside commands.lua.
      { id = "native", order = 5.9, verb = "native",
        usage = "  remuda butler native adopt-codex ALIAS --socket PATH --thread UUID"
          .. " | adopt-opencode ALIAS --endpoint URL --conversation SES_ID --password-stdin",
        run = function(_, args, caller) return host._butler_command_run("native", args, caller) end },
      { id = "quota", order = 6, verb = "quota", usage = "  remuda butler quota [--report]",
        run = function(_, args, caller) return host._butler_command_run("quota", args, caller) end },
      { id = "compact", order = 16, verb = "compact", usage = "  remuda butler compact <session> [--dry-run|--force]",
        run = function(_, args, caller)
          local spec = {
            name = "remuda butler",
            verbs = { compact = {
              about = "Compact a Butler session. Example: remuda butler compact worker-1 --dry-run",
              options = {
                { long = "dry-run", help = "Show compaction changes without applying them" },
                { long = "force", help = "Compact even when automatic rules would defer" },
              },
              args = { { name = "SESSION", help = "Session to compact" } },
              next = "remuda butler compact --help",
            } },
          }
          local report = cli_parse(spec, args)
          if report.kind == "help" then return report.text end
          if not report.ok then
            if type(host.fail) == "function" then return host.fail(report.text, report.code) end
            error(report.text, 0)
          end
          local session = report.values.SESSION
          local dry_run, force = report.values["dry-run"] == true, report.values.force == true
          if dry_run and force then
            local message = "--dry-run and --force cannot be used together.\nNext: remuda butler compact --help"
            if type(host.fail) == "function" then return host.fail(message, 2) end
            error(message, 0)
          end
          if not host._butler_compaction_has_session(session) then
            local message = "unknown session: " .. (session == "" and "<empty>" or session)
            if type(host.fail) == "function" then return host.fail(message, 1) end
            error(message, 0)
          end
          if dry_run then return host._butler_compaction_tick(session, true) end
          host._butler_current_agent(caller)
          return host.butler.compact(session, force)
        end },
      { id = "sessions", order = 10, verb = "sessions", usage = "  remuda butler sessions",
        run = function(_, args, caller) return host._butler_command_run("sessions", args, caller) end },
      { id = "status", order = 12, verb = "status", usage = "  remuda butler status  (0=up, 75=launching, 1=failed)",
        run = function(_, args, caller) return host._butler_command_run("status", args, caller) end },
      { id = "guard", order = 21, verb = "guard", usage = "  remuda butler guard on|off|status | approvals on|off|status | deny on|off|status | grants [on|off|status] | stats | verify (guard and approvals are on by default; deny and grants are off)",
        run = function(_, args, caller) return host._butler_command_run("guard", args, caller) end },
      { id = "typed-lines", order = 13, verb = "typed-lines", usage = "  remuda butler typed-lines on|off",
        run = function(_, args, caller) return host._butler_command_run("typed-lines", args, caller) end },
      { id = "shell-lines", order = 14, verb = "shell-lines", usage = "  remuda butler shell-lines on|off",
        run = function(_, args, caller) return host._butler_command_run("shell-lines", args, caller) end },
      { id = "agents", order = 15, verb = "agents", usage = "  remuda butler agents [--all]",
        run = function(_, args, caller) return host._butler_command_run("agents", args, caller) end },
      { id = "status-commands", order = 17, verb = "status-commands", usage = "  remuda butler status-commands on|off",
        run = function(_, args, caller) return host._butler_command_run("status-commands", args, caller) end },
      { id = "approve-text", order = 19, verb = "approve-text", usage = "  remuda butler approve-text request SESSION - | on|off",
        run = function(_, args, caller) return host._butler_command_run("approve-text", args, caller) end },
      { id = "schedule", order = 18, verb = "schedule", usage = "  remuda butler schedule list\n"
          .. '  remuda butler schedule add <name> "<M H * * *>" <text> | - [--to SESSION] [--once]\n'
          .. "  remuda butler schedule rm <name>",
        run = function(_, args, caller) return host._butler_command_run("schedule", args, caller) end },
      { id = "input-queue", order = 22, verb = "input-queue", usage = "  remuda butler input-queue status [ID] | cancel ID | resolve ID not_sent|delivered",
        run = function(_, args, caller) return host._butler_command_run("input-queue", args, caller) end },
      { id = "launch", order = 20, verb = "launch", usage = "  remuda butler launch <claude|codex|monocle> [name] [--model M] [--writable DIR]... [--sandbox full]",
        run = function(_, args, caller) return host._butler_command_run("launch", args, caller) end },
      { id = "topic", order = 30, verb = "topic", usage = "  remuda butler topic new <name> [--template T] [--agent A] [--model M]\n"
          .. "  remuda butler topic delegate <name> [--agent A] [--leader L] [--model M] [--cwd DIR] [--writable DIR]... [--sandbox full] <task...>",
        run = function(_, args, caller) return host._butler_command_run("topic", args, caller) end },
      { id = "send", order = 40, verb = "send", usage = '  remuda butler send <to> "<message>" | <to> - | <to> --file PATH\n'
          .. '  remuda butler send --from <from> <to> <message...> | --from <from> --file PATH <to>',
        run = function(_, args, caller) return host._butler_command_run("send", args, caller) end },
      { id = "send-to-leader", order = 50, verb = "send-to-leader", usage = "  remuda butler send-to-leader [--done] <message...> | - | --file PATH\n"
          .. "  Without --done, creates no new auto-close request and keeps an earlier one.\n"
          .. "  To send text that starts with -, put -- first: remuda butler send-to-leader -- -text",
        run = function(_, args, caller) return host._butler_command_run("send-to-leader", args, caller) end },
      { id = "inbox", order = 60, verb = "inbox", usage = "  remuda butler inbox [name]",
        run = function(_, args, caller) return host._butler_command_run("inbox", args, caller) end },
      { id = "reply", order = 70, verb = "reply", usage = "  remuda butler reply <message-id> <message...> | - | --file PATH\n"
          .. "  remuda butler reply <message-id> --attach PATH [caption...]",
        run = function(_, args, caller) return host._butler_command_run("reply", args, caller) end },
      { id = "forward", order = 80, verb = "forward", usage = "  remuda butler forward <message-id> <member> [note...]",
        run = function(_, args, caller) return host._butler_command_run("forward", args, caller) end },
      { id = "approvals", order = 90, verb = "approvals", usage = "  remuda butler approvals",
        run = function(_, args, caller) return host._butler_command_run("approvals", args, caller) end },
      { id = "approve", order = 91, verb = "approve", usage = "  remuda butler approve <ID>",
        run = function(_, args, caller) return host._butler_command_run("approve", args, caller) end },
      { id = "deny", order = 92, verb = "deny", usage = "  remuda butler deny <ID>",
        run = function(_, args, caller) return host._butler_command_run("deny", args, caller) end },
      { id = "matrix", order = 100, verb = "matrix",
        -- One source of truth: matrix_cli's own grouped help (commands.lua
        -- lists the pointer instead, via its Matrix section summary).
        usage = function() return host.butler.matrix.cli_usage() end,
        run = function(_, args, caller) return host._butler_command_run("matrix", args, caller) end },
    },
  },
}
