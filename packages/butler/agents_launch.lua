-- The launch chooser, member guidance and startup-modal helpers. main.lua passes
-- its locals in (the mail.lua pattern) and rebinds the exported ones.
local config = assert(remuda._butler_chooser_config)
local bus = assert(config.bus)
local call_callback = assert(config.call_callback)
local numbered_option = assert(config.numbered_option)
local bottom_screen_lines = assert(config.bottom_screen_lines)
local file_exists = assert(config.file_exists)
local contributions = assert(config.contributions)
local system = assert(remuda._butler_system)

local AGENT_BUILDERS = remuda._butler_agent_builders
local TELEMETRY_ADAPTERS = remuda._butler_telemetry_adapters
local PROMPT_DELIVERY = assert(remuda._butler_prompt_delivery)
local BUILTIN_AGENT_BUILDERS = {}
for kind, builder in pairs(AGENT_BUILDERS) do BUILTIN_AGENT_BUILDERS[kind] = builder end
if not remuda.contribute then
  for order, kind in ipairs({ "claude", "codex", "monocle" }) do
    local kind_id = kind
    local startup = remuda._butler_agent_startup[kind_id] or {}
    remuda._butler_contribute("butler.agent", kind_id, {
      order = order * 10, executable = kind_id, automatic = kind_id ~= "monocle",
      argv = function(_, spec) return AGENT_BUILDERS[kind_id](spec) end,
      ready = startup.ready and function(_, screen) return startup.ready(screen) end or nil,
      working = startup.working and function(_, screen) return startup.working(screen) end
        or function(_, screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
      login = startup.login or (kind_id == "claude"
        and { "Please log in", "not logged in", "Authentication required", "Invalid API key", "Please run /login", "Select login method" }
        or { "Please log in", "not logged in", "Authentication required", "Sign in to continue", "Not authenticated" }),
      dialogs = startup.modals,
    })
  end
end
local function build_agent_argv(kind, spec)
  local builder = AGENT_BUILDERS[kind]
  if not builder then error("unknown agent kind: " .. tostring(kind), 0) end
  return builder(spec)
end
local function one_line(value)
  return (tostring(value or ""):match("^[^\r\n]*") or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end
-- Diagnostics that reach detail/sessions/launch trace show ROW 1 of the screen only: control
-- sequences stripped, cut at 80 characters, "<empty first row>" when it is blank. Never a later row.
local function screen_detail(screen)
  local row = tostring(screen or ""):gsub("\27%[[%d;?]*[%a]", ""):match("^[^\r\n]*") or ""
  row = row:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if row == "" then return "<empty first row>" end
  local chars, count = {}, 0
  for char in row:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    count = count + 1
    if count > 80 then break end
    chars[#chars + 1] = char
  end
  return table.concat(chars)
end
local function readiness_timeout()
  local configured = tonumber(remuda._butler_readiness_timeout or os.getenv("REMUDA_BUTLER_READINESS_TIMEOUT"))
  if configured and configured > 0 then return configured end
  return 15
end
-- main.lua assigns startup_action_safe with the notice policy; read it late.
local startup_action_safe = config.startup_action_safe
local trust_modal_state, trust_plan, trust_path_matches, TRUST_AFFIRMATIVE
local claude_workspace_path
-- The one generic launch chooser serves Butler and every managed member. Kinds
-- are lifecycle contributions; the chooser only reads their data and callbacks.
-- Member launches must not hold the daemon image while an agent paints its
-- first prompt. This scheduler advances one candidate at a time and invokes
-- `done(name, kind, attempts)` when a candidate is ready or the chain ends.
local function choose(candidates, opts, done)
  local attempts, index, state, schedule = {}, 0, nil, nil
  local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
  lifecycle.active_choosers = lifecycle.active_choosers or {}
  lifecycle.next_chooser_id = (lifecycle.next_chooser_id or 0) + 1
  local chooser_id = "chooser-" .. tostring(lifecycle.next_chooser_id)
  local chooser_record = { id = chooser_id, name = opts.name }
  lifecycle.active_choosers[chooser_id] = chooser_record
  local cancelled = false
  local function callback(name, kind)
    if cancelled then return end
    if schedule then remuda.cancel(schedule); schedule = nil end
    chooser_record.ready = name ~= nil
    lifecycle.active_choosers[chooser_id] = nil
    done(name, kind, attempts)
  end
  local function alive(name)
    for _, row in ipairs(remuda.ls()) do if row.name == name and row.alive then return true end end
    return false
  end
  local by_id = {}
  for _, row in ipairs(contributions("butler.agent")) do by_id[row.id] = row.entry end
  for id, builder in pairs(remuda._butler_agent_builders or {}) do
    if not by_id[id] then
      local startup = remuda._butler_agent_startup[id] or {}
      by_id[id] = { argv = function(_, spec) return builder(spec) end,
        ready = startup.ready and function(_, screen) return startup.ready(screen) end or nil,
        login = {}, dialogs = startup.modals }
    end
  end
  local function fail_candidate(reason, detail)
    local current = state
    current.attempt.reason, current.attempt.detail = reason, detail
    local ok, err = pcall(remuda.close, current.name)
    current.closing, current.close_error, current.close_ticks = true, ok and nil or err, 0
  end
  local function start_next()
    index = index + 1
    local id = candidates[index]
    if not id then callback(nil, nil); return end
    local entry = by_id[id]
    local attempt = { kind = id, reason = "unknown" }
    attempts[#attempts + 1] = attempt
    if not entry then
      attempt.reason, attempt.detail = "not_found", "agent kind is not registered"
      start_next(); return
    end
    local spec = opts.spec(id)
    local build_error
    local argv = (type(opts.argv) == "function" and opts.argv(id, spec)) or opts.argv
      or (type(entry.argv) == "function" and (function()
        local built, value = call_callback(entry.argv, spec)
        if not built then build_error = value end
        return value
      end)()) or entry.argv
      or (entry.build and entry.build(spec))
    if build_error or type(argv) == "function" then
      attempt.reason = "spawn_error"
      -- A refused spec names its reason, without the builder's file:line prefix.
      attempt.detail = one_line((tostring(build_error or "agent argv builder failed"):gsub("^[^\n]-:%d+: ", "")))
      start_next(); return
    end
    local builder_override = remuda._butler_agent_builders[id]
      and remuda._butler_agent_builders[id] ~= BUILTIN_AGENT_BUILDERS[id]
    local executable = (builder_override and argv and argv[1])
      or entry.requires or entry.executable or (argv and argv[1]) or id
    if not opts.argv then
      local found, lookup_error = system.find_command(executable)
      if not found then
        attempt.reason, attempt.detail = "not_found", lookup_error or (executable .. " not found in PATH")
        start_next(); return
      end
      if type(argv) == "table" and argv[1] == executable then argv[1] = found end
    end
    local ok, name = pcall(remuda.new, opts.name, argv, opts.cwd, opts.env(id, spec))
    if not ok then
      attempt.reason, attempt.detail = "spawn_error", one_line(name)
      start_next(); return
    end
    state = { id = id, entry = entry, attempt = attempt, name = name,
      started = os.time(), timeout = opts.timeout or readiness_timeout(),
      handled = {}, last_screen = "<empty first row>", last_screen_blank = true, dialog_seen = nil }
    local test_builder = remuda._butler_agent_builders[id]
      and remuda._butler_agent_builders[id] ~= BUILTIN_AGENT_BUILDERS[id]
    local force_test_probe = type(remuda._butler_test_force_launch_probe) == "table"
      and remuda._butler_test_force_launch_probe[opts.name] == true
    if opts.skip_probe or (test_builder and not force_test_probe) then
      attempt.reason, attempt.session = "ready", name
      callback(name, id)
    end
  end
  local function tick()
    if not state then return end
    if state.closing then
      state.close_ticks = state.close_ticks + 1
      if not alive(state.name) then
        state = nil; start_next()
      elseif state.close_ticks >= 10 then
        state.attempt.reason = "spawn_error"
        state.attempt.detail = (state.attempt.detail or "") .. "; failed to kill failed session"
          .. (state.close_error and (": " .. tostring(state.close_error)) or "")
        callback(nil, nil)
      end
      return
    end
    if not alive(state.name) then fail_candidate("exited", "session exited before prompt became ready"); return end
    local captured, screen = pcall(remuda.capture, state.name)
    if not captured then
      state.last_capture_error = one_line(screen)
      screen = ""
    end
    screen = tostring(screen or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    state.last_screen = screen_detail(screen)
    state.last_screen_blank = screen:find("%S") == nil
    local entry, id = state.entry, state.id
    -- Authentication screens can still contain a prompt glyph; classify
    -- login before readiness so expired credentials never look usable.
    for _, pattern in ipairs(entry.login or {}) do
      if screen:find(pattern, 1, true) then fail_candidate("login", screen_detail(screen)); return end
    end
    local ready = false
    if entry.ready then local tested, matched = call_callback(entry.ready, screen); ready = tested and not not matched end
    local startup = remuda._butler_agent_startup[id] or {}
    if not ready and startup.ready then local tested, matched = pcall(startup.ready, screen); ready = tested and not not matched end
    if not ready and remuda._butler_prompt_is_empty then
      local tested, decision = pcall(remuda._butler_prompt_is_empty, id, screen); ready = tested and decision == "EMPTY"
    end
    if not ready and (screen:match("\n%s*❯%s*$") or screen:match("\n%s*>%s*$") or screen:match("\n%s*›%s*$")) then ready = true end
    if ready then state.attempt.reason, state.attempt.session = "ready", state.name; callback(state.name, id); return end
    local dialogs = type(entry.dialogs) == "function" and select(2, call_callback(entry.dialogs)) or entry.dialogs or {}
    local known = false
    for dialog_index, dialog in ipairs(dialogs) do
      local lower_screen = screen:lower()
      local trust_state = dialog.trust and trust_modal_state(dialog, screen) or nil
      -- Topic and eligible launches must show the launch cwd; an unreadable path fails closed.
      local workspace_matches_launch = dialog.trust and (not (opts.trust_path_gate or opts.trust_eligible)
        or trust_path_matches(dialog, screen, opts.cwd, opts.trust_real_cwd))
      local matched = dialog.trust and trust_state ~= "absent"
        or (dialog.match and lower_screen:find(dialog.match:lower(), 1, true))
      if matched then
        known, state.dialog_seen = true, dialog.match
        if dialog.trust then
          if state.trust_screen == screen then state.trust_ticks = (state.trust_ticks or 0) + 1
          else state.trust_screen, state.trust_ticks = screen, 1 end
          if state.trust_ticks < 2 then break end
          local may_answer = opts.auto_trust or opts.trust_eligible
          if trust_state == "pending" and may_answer then break end
          local trust_grant_available = opts.trust_eligible
            or (bus.trusted_launch_dirs and bus.trusted_launch_dirs[opts.cwd] == true)
            or state.handled[dialog_index] == "selection_pending"
          local may_auto_trust = may_answer and trust_grant_available and startup_action_safe
            and startup_action_safe(state.name) and workspace_matches_launch
          local function trace_press(what, result)
            local trace = remuda._butler_session_trace or _G._butler_session_trace
            if trace then pcall(trace, "trust_press", state.name .. " agent=" .. tostring(state.id)
              .. " cwd=" .. tostring(opts.cwd) .. " option=" .. what .. " result=" .. result) end
          end
          if may_auto_trust and trust_state == "safe" and not state.handled[dialog_index] then
            -- Move the marker onto the affirmative option by its text, then
            -- verify on a fresh capture before confirming on a later tick.
            local plan = trust_plan(dialog, screen)
            state.trust_moves = (state.trust_moves or 0) + 1
            if plan and state.trust_moves <= 3 then
              local moved = true
              for _, key in ipairs(plan.moves) do
                local ok, result = pcall(remuda.key, state.name, key)
                if not ok or result == false then moved = false end
              end
              local captured, selected_screen = pcall(remuda.capture, state.name)
              selected_screen = captured and tostring(selected_screen or ""):gsub("\r\n", "\n"):gsub("\r", "\n") or ""
              local verified = moved and trust_modal_state(dialog, selected_screen) == "safe_selected"
              trace_press(plan.label, verified and "selected" or "selection_unverified")
              if verified then
                state.handled[dialog_index] = "selection_pending"
                state.attempt.trust_selection_moved = true
                state.trust_screen, state.trust_ticks = selected_screen, 1
              end
              break
            end
          elseif may_auto_trust and trust_state == "safe_selected"
              and (not state.handled[dialog_index] or state.handled[dialog_index] == "selection_pending") then
            local ok, result = pcall(remuda.key, state.name, "RET")
            local pressed = ok and result ~= false
            trace_press(TRUST_AFFIRMATIVE[dialog.trust], pressed and "confirmed" or "key_failed")
            if pressed then
              state.handled[dialog_index] = "confirmed"
              state.attempt.trust_answered = true
              if bus.trusted_launch_dirs then bus.trusted_launch_dirs[opts.cwd] = nil end
            end
            break
          end
          state.attempt.reason, state.attempt.session =
            "waiting_for_human_trust (Next: review the folder and approve it in the member session)", state.name
          state.attempt.trust_path = opts.cwd
          callback(state.name, id)
          return
        end
        -- Codex's update is an actionable startup state. Hand it to the
        -- member launch flow, which owns the shared update lock and relaunch.
        if dialog.update then
          state.attempt.reason, state.attempt.session = "startup_dialog", state.name
          callback(state.name, id)
          return
        end
        if not state.handled[dialog_index] then
          state.handled[dialog_index] = true
          for _, key in ipairs(dialog.keys or {}) do pcall(remuda.key, state.name, key) end
        end
        break
      elseif dialog.pending_match and lower_screen:find(dialog.pending_match:lower(), 1, true) then
        -- Claude paints the trust explanation before the selectable options.
        -- Keep polling that known startup state until its affirmative option
        -- is visible; the broad unknown-dialog check below would otherwise
        -- reject the partial frame before the label handler can run.
        known, state.dialog_seen = true, dialog.pending_match
        break
      end
    end
    if known then
      state.unknown_dialog_screen, state.unknown_dialog_since = nil, nil
    else
      local lower = screen:lower()
      local suspicious = lower:find("trust", 1, true) or lower:find("continue", 1, true)
        or lower:find("press enter", 1, true) or lower:find("select an option", 1, true)
        or lower:find("terms of service", 1, true) or lower:find("confirm", 1, true)
      if suspicious then
        if state.unknown_dialog_screen ~= screen then
          state.unknown_dialog_screen, state.unknown_dialog_since = screen, os.time()
        elseif os.time() - state.unknown_dialog_since >= 2 then
          fail_candidate("dialog", screen_detail(screen)); return
        end
      else
        state.unknown_dialog_screen, state.unknown_dialog_since = nil, nil
      end
    end
    if os.time() - state.started >= state.timeout then
      if state.last_screen_blank and not state.dialog_seen and not state.unknown_dialog_screen then
        state.attempt.reason, state.attempt.session = "ready_unverified", state.name
        state.attempt.detail = "session remained alive but screen was blank at readiness timeout"
          .. (state.last_capture_error and ("; last capture error: " .. state.last_capture_error) or "")
        callback(state.name, state.id)
        return
      end
      local prefix = state.dialog_seen and ("dialog remained after its handler: " .. state.dialog_seen .. "; ") or ""
      local capture_error = state.last_capture_error and ("; last capture error: " .. state.last_capture_error) or ""
      fail_candidate(state.dialog_seen and "dialog" or "timeout", prefix
        .. "readiness prompt not observed within " .. tostring(state.timeout)
        .. " seconds; last screen: " .. state.last_screen
        .. capture_error)
    end
  end
  schedule = remuda.schedule({ every = 0.2, run = function()
    local ok, err = pcall(tick)
    if not ok then
      if state and state.name then fail_candidate("spawn_error", tostring(err))
      else callback(nil, nil) end
    end
  end })
  chooser_record.schedule = schedule
  chooser_record.cancel = function()
    if cancelled then return end
    cancelled = true
    if schedule then pcall(remuda.cancel, schedule); schedule = nil end
    if state and not chooser_record.ready then
      local name = state.name
      if name and alive(name) then pcall(remuda.close, name) end
      state = nil
    end
    if opts.name == "butler" then
      remuda._butler_launching, remuda._butler_start_pending = nil, nil
      remuda._butler_selected_agent = nil
    end
    lifecycle.active_choosers[chooser_id] = nil
  end
  start_next()
  return attempts
end
remuda._butler_choose = choose
remuda._butler_choose_async = choose
function remuda._butler_cancel_active_choosers(lifecycle)
  lifecycle = lifecycle or remuda._butler_state or remuda._butler_compaction_state
  local active = lifecycle and lifecycle.active_choosers or {}
  local pending = {}
  for id, record in pairs(active) do pending[#pending + 1] = { id = id, record = record } end
  for _, item in ipairs(pending) do
    if item.record.cancel then pcall(item.record.cancel) else active[item.id] = nil end
  end
end
local function configured_agent_order()
  if remuda._butler_candidate_order then return remuda._butler_candidate_order end
  local raw = os.getenv("REMUDA_BUTLER_AGENT_ORDER")
  if raw and raw ~= "" then
    local order = {}
    for kind in raw:gmatch("[^,%s]+") do order[#order + 1] = kind end
    if #order > 0 then return order end
  end
  local rows = contributions("butler.agent")
  table.sort(rows, function(a, b)
    local ao = tonumber(a.order or (a.entry and a.entry.order)) or 0
    local bo = tonumber(b.order or (b.entry and b.entry.order)) or 0
    if ao ~= bo then return ao < bo end
    return a.id < b.id
  end)
  local order = {}
  for _, row in ipairs(rows) do
    local entry = row.entry or row
    if entry.automatic ~= false then order[#order + 1] = row.id end
  end
  if #order == 0 then return { "claude", "codex" } end
  return order
end
remuda._butler_configured_agent_order = configured_agent_order
local function readiness_chain_budget()
  -- Include time for the ordered candidates plus room for the scheduler to
  -- notice each timeout and close a failed session before advancing.
  return math.ceil(#configured_agent_order() * readiness_timeout() + 15)
end
local function setup_telemetry(kind, spec)
  local adapter = TELEMETRY_ADAPTERS[kind]
  return adapter and adapter.setup and adapter.setup(spec) or {}
end
-- A member's AGENTS.md and prompt are `butler.guidance` sections joined in
-- order, so an extension adds its own section (hook-design §4.2).
if not remuda.contribute then
remuda._butler_contribute("butler.guidance", "header", { order = 10,
  agents_md = function(ctx)
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
  end })
remuda._butler_contribute("butler.guidance", "cli", { order = 20,
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
  end })
-- #201: one section for every kind, since a member's kind can fall back.
remuda._butler_contribute("butler.guidance", "codex", { order = 25,
  agents_md = function()
    return [[Codex members: use the MCP `butler_*` tools first (`butler_inbox`,
`butler_send`, `butler_reply`, `butler_send_to_leader`, `butler_forward`,
`butler_sessions`; `matrix_download` and `matrix_upload` for Matrix files). The
`remuda butler` CLI fails inside the Codex sandbox by
design (`Operation not permitted`). If you must use the CLI and get that error,
re-run the command requesting escalated permissions.

]]
  end })
remuda._butler_contribute("butler.guidance", "old-core", { order = 30,
  agents_md = function()
    return [[If `inbox` says "no Butler identity in your env", your Remuda core predates
caller-env forwarding: pass your id (`remuda butler inbox
$REMUDA_BUTLER_AGENT_ID`) or use the MCP `butler_*` tools. On such a core,
`send` is attributed to "operator" rather than to you.

]]
  end })
remuda._butler_contribute("butler.guidance", "delegation", { order = 40,
  agents_md = function()
    return [[You may create a Remuda-managed child team with `remuda butler topic delegate
NAME TASK...` when useful. Internal agent subagents are separate from Butler
team members. `remuda butler send FROM TO MESSAGE...` is an operator form, not
the normal way for a member to communicate.
]]
  end })
remuda._butler_contribute("butler.guidance", "leader", { order = 90,
  prompt = function(ctx) return "Your leader is " .. ctx.parent .. "." end })
remuda._butler_contribute("butler.permission", "cli", { order = 10,
  rules = function(ctx) return remuda._butler_permissions.builtin(ctx) end })
end
local function guidance(part, parent)
  local out = {}
  for _, item in ipairs(contributions("butler.guidance")) do
    local render = item.entry[part]
    if render then out[#out + 1] = render({ parent = parent }) or "" end
  end
  return table.concat(out)
end
local function team_member_guidance(parent) return guidance("agents_md", parent) end
local function team_member_prompt(parent) return guidance("prompt", parent) end
local function write_agent_guidance(root, text, replace)
  local path = root .. "/AGENTS.md"
  if not replace and file_exists(path) then return end
  -- Only when the text differs: launch_butler calls this on every reconcile tick.
  -- No symlink check (it would run a process on that tick): the directory is the
  -- mod's own. An AGENTS.md that is a link is read through, and when the text
  -- differs the atomic writer replaces the link with a plain file.
  assert(remuda._butler_permissions.write_if_changed(path, text, config.fs))
end
local _butler_session_trace -- defined below; the task poke fires later
local function option_number(screen, matches)
  -- Parse the visible chooser ourselves. Core versions that strip a UTF-8
  -- selection glyph as a byte-class can leave stray bytes before its label.
  local found
  for line in (tostring(screen or "") .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("^%s*", "")
    for _, marker in ipairs({ "│", "┃", "❯", "›", ">" }) do
      if line:sub(1, #marker) == marker then
        line = line:sub(#marker + 1):gsub("^%s*", "")
        break
      end
    end
    local number, label = line:match("^%s*(%d+)[%.)]%s*(.-)%s*$")
    if number and matches(label) then
      if found then return nil end
      found = number
    end
  end
  return found
end
local function codex_update_version(screen)
  local from, to = tostring(screen or ""):match("(%d+%.%d+%.%d+)%s*→%s*(%d+%.%d+%.%d+)")
  if from and to then return from .. "->" .. to end
end
local function skip_option_number(screen)
  local number = option_number(screen, function(label) return label:lower() == "skip" end)
  if number then return number end
  number = option_number(screen, function(label)
    local lower = label:lower()
    return lower:sub(1, 5) == "skip " and lower ~= "skip until next version"
  end)
  if number then return number end
  return option_number(screen, function(label) return label:lower() == "skip until next version" end)
end
local function startup_modal_timeout_seconds()
  return tonumber(remuda._butler_modal_timeout or remuda._butler_modal_attempts or remuda._butler_task_poke_attempts) or 60
end
-- The path under the LAST header (a stale earlier block never supplies it); a
-- header with no path after it yields nil.
claude_workspace_path = function(screen)
  local in_header, found = false, nil
  for line in (tostring(screen or "") .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if in_header and (trimmed:match("^/") or trimmed:match("^%a:[/\\]")) then
      found, in_header = trimmed, false
    end
    if trimmed == "Accessing workspace:" then in_header, found = true, nil end
  end
  return found
end
-- Codex: the same bottom window the options and title are read from.
local function codex_workspace_path(screen)
  local in_header, found = false, nil
  for _, line in ipairs(bottom_screen_lines(screen, 12)) do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if in_header and trimmed ~= "" then
      found, in_header = trimmed:match("^/") and trimmed or nil, false
    end
    if trimmed == "Folder access" then in_header, found = true, nil end
  end
  return found
end
-- The affirmative option of each agent's trust dialog, matched as exact text.
TRUST_AFFIRMATIVE = { claude = "Yes, I trust this folder", codex = "Trust and continue" }
-- The option block of a trust dialog: the contiguous non-blank lines around
-- its one selection marker, as labels (numbering and marker stripped).
local function trust_options(lines)
  local marked
  for index, line in ipairs(lines) do
    local trimmed = line:gsub("^%s+", "")
    if trimmed:sub(1, #"❯") == "❯" or trimmed:sub(1, #"›") == "›" then
      if marked then return nil end
      marked = index
    end
  end
  if not marked then return nil end
  local first, last = marked, marked
  while first > 1 and lines[first - 1]:find("%S") and not lines[first - 1]:find("─", 1, true) do first = first - 1 end
  while last < #lines and lines[last + 1]:find("%S") and not lines[last + 1]:find("─", 1, true) do last = last + 1 end
  local labels = {}
  for index = first, last do
    local trimmed = lines[index]:gsub("^%s+", ""):gsub("^❯%s*", ""):gsub("^›%s*", "")
    labels[#labels + 1] = trimmed:gsub("^%d+[%.)]%s*", ""):gsub("%s+$", "")
  end
  if #labels < 2 or #labels > 4 then return nil end
  return labels, marked - first + 1
end
-- Select the affirmative option by its TEXT: {moves, selected, label}, or nil
-- (with the reason) when no option matches exactly once or the structure is
-- unexpected. Never a digit: moves are arrow keys from the current marker.
trust_plan = function(modal, screen)
  local affirmative = TRUST_AFFIRMATIVE[modal.trust]
  if not affirmative then return nil, "unknown agent" end
  local lines = {}
  for line in (tostring(screen or "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if modal.trust == "codex" then lines = bottom_screen_lines(screen, 12) end
  local labels, current = trust_options(lines)
  if not labels then return nil, "unexpected structure" end
  local target
  for index, label in ipairs(labels) do
    if label == affirmative then
      if target then return nil, "ambiguous option" end
      target = index
    end
  end
  if not target then return nil, "no exact match" end
  local moves = {}
  for _ = 1, math.abs(target - current) do moves[#moves + 1] = target > current and "<down>" or "<up>" end
  return { moves = moves, selected = target == current, label = affirmative }
end
local function trust_displayed_path(modal, screen)
  if modal.trust == "claude" then return claude_workspace_path(screen) end
  if modal.trust == "codex" then return codex_workspace_path(screen) end
end
-- The shown workspace path must be the launch cwd (or its realpath); an
-- unreadable path fails closed.
trust_path_matches = function(modal, screen, cwd, real)
  local function norm(path) return (tostring(path or ""):gsub("/+$", "")) end
  local shown = norm(trust_displayed_path(modal, screen))
  return shown ~= "" and (shown == norm(cwd) or (real ~= nil and shown == norm(real)))
end
trust_modal_state = function(modal, screen)
  local lower = tostring(screen or ""):lower()
  if modal.trust == "claude" then
    if not lower:find("accessing workspace:", 1, true) then
      if lower:find("quick safety check:", 1, true) then return "pending" end
      return "absent"
    end
  elseif modal.trust == "codex" then
    if not table.concat(bottom_screen_lines(screen, 12), "\n"):lower():find("trust this folder?", 1, true) then
      return "absent"
    end
  else
    return "human"
  end
  local plan = trust_plan(modal, screen)
  if not plan then
    -- The explanation painted before any option is a partial frame, not a mismatch.
    if modal.trust == "claude" and lower:find("quick safety check:", 1, true)
        and not screen:find("❯", 1, true) and not screen:find("›", 1, true) then
      return "pending"
    end
    return "human"
  end
  return plan.selected and "safe_selected" or "safe"
end
local function startup_modal(startup, screen)
  local lower = tostring(screen or ""):lower()
  for _, modal in ipairs(startup.modals or {}) do
    if modal.trust then
      if trust_modal_state(modal, screen) ~= "absent" then return modal end
    elseif modal.match and lower:find(modal.match:lower(), 1, true) then
      return modal
    elseif modal.pending_match and lower:find(modal.pending_match:lower(), 1, true) then
      return modal
    end
  end
end
local function known_startup_modal(startup, screen)
  if startup_modal(startup, screen) then return true end
  local lower = tostring(screen or ""):lower()
  return lower:find("updating codex", 1, true) ~= nil
    or lower:find("installing codex update", 1, true) ~= nil
end
local function codex_update_complete(screen)
  local lower = tostring(screen or ""):lower()
  return lower:find("update complete", 1, true) ~= nil
    or lower:find("update successful", 1, true) ~= nil
    or lower:find("update ran successfully", 1, true) ~= nil
    or lower:find("codex was updated", 1, true) ~= nil
    or lower:find("codex has been updated", 1, true) ~= nil
    or lower:find("restarting codex", 1, true) ~= nil
end
local function capture_update_evidence(session, screen)
  local evidence = tostring(screen or "")
  -- Some hosts may expose scrollback separately; core 355e8b2 only exposes
  -- the current screen through remuda.capture.
  if type(remuda.capture_scrollback) == "function" then
    local ok, scrollback = pcall(remuda.capture_scrollback, session)
    if ok and scrollback then
      if type(scrollback) == "table" then
        local rows = {}
        for _, row in ipairs(scrollback) do rows[#rows + 1] = tostring(row) end
        evidence = table.concat(rows, "\n") .. "\n" .. evidence
      else
        evidence = tostring(scrollback) .. "\n" .. evidence
      end
    end
  end
  return evidence
end

-- Whether this Butler may answer the trust dialog of a session it launched in
-- `cwd`: a normalized absolute real directory that is not a broad or Butler
-- root, and is under project_home or is a linked git worktree of a repo under
-- project_home. `env` carries realpath, home, project_home, protected (roots
-- that may not be the cwd), read_file and is_dir so tests need no syscalls.
-- Returns true, or false plus the refusal reason.
local function trust_eligible(cwd, env)
  local function under(path, root) return path ~= root and path:sub(1, #root + 1) == root .. "/" end
  if type(cwd) ~= "string" or cwd:sub(1, 1) ~= "/" or cwd:find("%c") then return false, "not absolute" end
  if cwd ~= "/" and (cwd:sub(-1) == "/" or cwd:find("//", 1, true) or cwd:find("/%./") or cwd:find("/%.%./")
      or cwd:match("/%.$") or cwd:match("/%.%.$")) then
    return false, "not normalized"
  end
  local real = env.realpath(cwd)
  if not real or real:sub(1, 1) ~= "/" or not env.is_dir(real) then return false, "not an existing directory" end
  local function resolved(path) return path and (env.realpath(path) or path) end
  local home = resolved(env.home)
  local project_home = resolved(env.project_home)
  if real == "/" then return false, "root" end
  if not home or home == real or under(home, real) then return false, "home or its ancestor" end
  if not project_home or real == project_home then return false, "project home itself" end
  if project_home == "/" or project_home == home
      or under(home, project_home) then
    return false, "project home is home or its ancestor"
  end
  for _, root in ipairs(env.protected or {}) do
    local r = resolved(root)
    if r == real or under(r, real) or under(real, r) then
      return false, "butler root"
    end
  end
  if under(real, project_home) then return true end
  -- A linked worktree: `.git` is a file naming <repo>/.git/worktrees/<n>, whose
  -- own `gitdir` file points back here, and the repo lies under project_home.
  local pointer = env.read_file(real .. "/.git")
  local gitdir = pointer and pointer:match("^gitdir: ([^\r\n]+)%s*$")
  if gitdir and gitdir:sub(1, 1) == "/" then
    local admin = env.realpath(gitdir)
    local repo = admin and admin:match("^(.+)/%.git/worktrees/[^/]+$")
    local back = admin and env.read_file(admin .. "/gitdir")
    back = back and back:gsub("%s+$", "")
    if repo and back and (back == real .. "/.git" or env.realpath(back) == real .. "/.git")
        and under(repo, project_home) and repo ~= project_home then
      return true
    end
  end
  return false, "outside project home"
end
remuda._butler_chooser = {
  PROMPT_DELIVERY = PROMPT_DELIVERY,
  build_agent_argv = build_agent_argv,
  one_line = one_line,
  trust_modal_state = trust_modal_state, trust_plan = trust_plan, trust_eligible = trust_eligible,
  trust_path_matches = trust_path_matches,
  choose = choose,
  configured_agent_order = configured_agent_order,
  readiness_chain_budget = readiness_chain_budget,
  setup_telemetry = setup_telemetry,
  team_member_guidance = team_member_guidance,
  team_member_prompt = team_member_prompt,
  write_agent_guidance = write_agent_guidance,
  option_number = option_number,
  codex_update_version = codex_update_version,
  skip_option_number = skip_option_number,
  startup_modal_timeout_seconds = startup_modal_timeout_seconds,
  startup_modal = startup_modal,
  known_startup_modal = known_startup_modal,
  codex_update_complete = codex_update_complete,
  capture_update_evidence = capture_update_evidence,
}
