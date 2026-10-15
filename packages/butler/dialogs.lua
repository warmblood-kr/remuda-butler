-- Reporting-only blocking-state dispatcher. The agent descriptor lists contain
-- pure screen matchers: { id, risk = "report", match(screen, probes) -> signature }.
-- No descriptor is allowed to write input. Existing startup/compaction handlers
-- retain their policy; all managed writes pass through a fresh screen/audit gate.
-- Unknown screens allow input; only identified exceptions block the screen gate.
local butler = assert(remuda.butler)
local bus = assert(remuda._butler_bus)
local M = {}
butler.dialogs = M
bus.dialog_states = bus.dialog_states or {} -- survives a package reload
local states = bus.dialog_states
local unpack_args = table.unpack or unpack
local function pack(...) return { n = select('#', ...), ... } end

local function agent_for(name)
  for alias, agent in pairs(bus.agents) do
    if alias == name or agent.session_name == name then
      if agent.kind == 'claude' or agent.kind == 'codex' then return agent, alias end
    end
  end
end

local function digest(signature)
  local guard = butler.guard_approval
  if guard and type(guard.sha256) == 'function' then
    local ok, hash = pcall(guard.sha256, signature)
    if ok then return hash end
  end
end

local function audit(name, agent, state, event, action, outcome)
  local policy = butler.guard_policy
  if not policy or type(policy.append) ~= 'function' then return false end
  local ok, wrote = pcall(policy.append, {
    session = name, kind = agent.kind, event = event, class = 'other',
    tool = 'dialog', summary = outcome or 'reporting-only',
    instance_id = type(state.instance) == 'string' and state.instance or 'legacy-agent-record',
    dialog_id = state.id or 'none', handler_version = '1',
    action = action or 'stop', hash = state.signature and digest(state.signature),
  })
  return ok and wrote == true
end

local function report(name, agent, alias, state)
  if state.reported or state.reporting then return end
  local leader = agent.parent or 'butler'
  -- The root cannot send itself a report without producing another notice to
  -- its blocked pane; its durable audit and operator log remain the fallback.
  local text = 'Butler stopped writes: agent=' .. agent.kind .. ' session=' .. name
    .. ' kind=unknown state=' .. state.id
    .. '. Waiting for owner review; no input was sent.'
    .. (state.audited and '' or ' Audit unavailable; writes remain stopped.')
  local ok, sent
  state.reporting = true
  if leader ~= alias and type(remuda._butler_send) == 'function' then
    ok, sent = pcall(remuda._butler_send, alias, leader, text)
  elseif type(remuda.log) == 'function' then
    ok, sent = pcall(remuda.log, 'warn', text)
    sent = ok
  end
  state.reporting = nil
  if ok and sent ~= false and sent ~= nil then
    state.reported = true
    audit(name, agent, state, 'dialog_reported', 'report', 'queued')
  end
end

local function startup_owned(name, agent, screen, signature)
  local startup = (remuda._butler_agent_startup or {})[agent.kind] or {}
  local chooser = remuda._butler_chooser
  local delivery = (bus.first_task_delivery or {})[name]
  local update = (bus.codex_update_relaunches or {})[name]
  local owned = (bus.pending_tasks or {})[name] and delivery and delivery.state == 'waiting'
    and delivery.marker ~= nil and delivery.marker == agent.session_start_marker
  owned = owned or (type(update) == 'table' and update.identity == agent.id)
  if not owned or not chooser or not chooser.startup_modal then return false end
  -- Broad historical markers are suitable for startup deferral, not input
  -- authorization. Match the current geometry and validate its option labels.
  local current = signature or screen
  local modal = chooser.startup_modal(startup, current)
  local full = chooser.startup_modal(startup, screen)
  local trust_modal = modal and modal.trust and modal or full and full.trust and full
  if trust_modal then
    local trust = chooser.trust_modal_state(trust_modal, screen)
    local plan = chooser.trust_plan(trust_modal, current)
    return plan ~= nil and (trust == 'safe' or trust == 'safe_selected')
  end
  local labels = {}
  for line in (current .. '\n'):gmatch('(.-)\n') do
    line = line:gsub('^%s*❯%s*', ''):gsub('^%s*›%s*', ''):gsub('^%s*>%s*', ''):gsub('^%s+', '')
    local label = line:match('^%d+%.%s+(.+)$')
    if label then labels[#labels + 1] = label:lower():gsub('%s+$', '') end
  end
  if #labels == 0 then return false end
  if agent.kind == 'codex' and modal and modal.update then
    for _, label in ipairs(labels) do
      if label ~= 'skip' and not label:match('^skip ') and not label:match('^update now') then return false end
    end
    return true
  end
  -- Teach's exact informational options still belong to its defer-only launch
  -- handler; a historical title cannot bless any other choice block.
  if agent.kind == 'claude' and full and full.title == 'Teach auto mode' then
    for _, label in ipairs(labels) do
      if label ~= 'not now' and label ~= "don't show again" then return false end
    end
    return true
  end
  return false
end

local function legacy_owned(name, agent, screen, signature)
  if startup_owned(name, agent, screen, signature) then return true end
  local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
  if lifecycle.compaction_fleet_active ~= (agent.id or agent.session_name) then return false end
  if agent.kind == 'claude' then
    return remuda._butler_model_confirm_signature and remuda._butler_model_confirm_signature(screen) ~= nil
  end
  local member = (lifecycle.compaction_members or {})[agent.id or name]
  local operation = member and member.dialog_operation
  local startup = (remuda._butler_agent_startup or {})[agent.kind] or {}
  return operation and operation.agent == agent and startup.owned_picker
    and startup.owned_picker(screen, signature, operation) == true
end

-- Match current modal context, not a box/menu alone or a title in scrollback.
-- Provenance for the supported UI strings is in docs/concepts/input-screen-policy.md.
local function current_geometry(screen, geometry)
  if type(screen) ~= 'string' or not geometry then return nil end
  local lines = {}
  for line in (screen .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
  -- A composer below the old choices makes them transcript, not the current
  -- interaction. Check this before picker/modal detection as well.
  local saw_choices, in_quote, selected = false, false, nil
  for index, line in ipairs(lines) do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed:match('^```') then in_quote = not in_quote end
    if not in_quote then
      local number, _, marked = remuda._butler_compaction.numbered_option(line)
      if number then saw_choices = true end
      if marked then selected = index end
    end
    if saw_choices and not remuda._butler_compaction.numbered_option(line) then
      if trimmed:sub(1, 3) == '❯' or trimmed:sub(1, 3) == '›'
          or trimmed == '>' or trimmed:match('^> ') or trimmed:find('Ask Codex to do anything', 1, true) == 1 then
        saw_choices, selected = false, nil
      end
    end
  end
  if not saw_choices then
    -- Box-only modal recognition still requires a supported title below.
    local signature = geometry(screen)
    if signature and (signature:sub(1, 3) == '╭' or signature:sub(1, 3) == '┌' or signature:sub(1, 3) == '╔') then
      local start = screen:find(signature, 1, true)
      local prefix = start and screen:sub(1, start - 1) or ''
      local quoted = false
      for line in (prefix .. '\n'):gmatch('(.-)\n') do
        if line:match('^%s*```') then quoted = not quoted end
      end
      if quoted then return nil end
      local suffix = start and screen:sub(start + #signature) or ''
      if suffix:find('❯', 1, true) or suffix:find('›', 1, true) then return nil end
      return signature
    end
    return nil
  end
  if not selected then return nil end
  local first, last = selected, selected
  while first > 1 and remuda._butler_compaction.numbered_option(lines[first - 1]) do first = first - 1 end
  while last < #lines and remuda._butler_compaction.numbered_option(lines[last + 1]) do last = last + 1 end
  local current = {}
  for index = first, last do current[#current + 1] = lines[index] end
  return table.concat(current, '\n')
end

local function exception_signature(kind, screen, signature)
  if not signature then return nil end
  local start, from = nil, 1
  while true do
    local found = screen:find(signature, from, true)
    if not found then break end
    start, from = found, found + 1
  end
  if not start then return nil end
  local prefix = screen:sub(1, start - 1)
  local heading = prefix:match('([^\n]+)%s*$') or ''
  -- A known modal may put its title inside its border rather than above it.
  if signature:sub(1, 3) == '╭' or signature:sub(1, 3) == '┌' or signature:sub(1, 3) == '╔' then
    local first = true
    for line in (signature .. '\n'):gmatch('(.-)\n') do
      if first then first = false
      else
        local title = line:gsub('│', ''):gsub('║', ''):match('^%s*(.-)%s*$')
        if title ~= '' then heading = title; break end
      end
    end
  end
  heading = heading:match('^%s*(.-)%s*$'):lower()
  if kind == 'codex' then
    local tail = remuda._butler_compaction.bottom_screen_lines(prefix, 32)
    for i = #tail, 1, -1 do
      local line = tail[i]:match('^%s*(.-)%s*$')
      local lower = line:lower()
      local approval = lower == 'would you like to run the following command?'
        or lower == 'would you like to make the following edits?'
        or lower == 'would you like to grant these permissions?'
        or lower == 'would you like to send input to the existing terminal?'
      if approval then heading = lower; break end
      -- Recognized approval header fields and command/diff rows may separate
      -- the title from choices. A new unrelated heading ends the search.
      if line ~= '' and not line:match('^Reason:') and not line:match('^Thread:')
          and not line:match('^Environment:') and not line:match('^Permission rule:')
          and not line:match('^Description:') and not line:match('^Destination:')
          and not line:match('^%$ ') and not line:match('^[+%-@]')
          and not line:match('^%d+%s') and not line:match('^%d+%s*[+%-]') then break end
    end
  end
  local known = heading == 'switch model?' or heading == 'change effort level?'
    or heading == 'do you want to proceed?'
  if kind == 'codex' then
    known = known or heading == 'select model and effort'
      or heading:match('^select reasoning level for gpt%-[%w%.%-]+$') ~= nil
      or heading == 'would you like to run the following command?'
      or heading == 'would you like to make the following edits?'
      or heading == 'would you like to grant these permissions?'
      or heading == 'would you like to send input to the existing terminal?'
    -- The interruption text alone is historical output. Only a current choice
    -- immediately following it is an exceptional confirmation surface.
    known = known or (heading:match('^automatic approval review rejected too many approval requests for this turn %(') ~= nil
      and heading:match('reviews%); interrupting the turn%.$') ~= nil)
  elseif kind == 'claude' then
    known = known or heading == 'do you want to allow claude to fetch this content?'
    -- Session-limit UI uses this title together with these exact options.
    known = known or (heading == 'what do you want to do?'
      and signature:find('Stop and wait for limit to reset', 1, true) ~= nil)
  end
  if known then return heading .. '\n' .. signature end
  -- Trust/update/Teach screens have established, agent-specific parsers. Check
  -- the current choice segment plus nearby context, never the full scrollback.
  local startup = (remuda._butler_agent_startup or {})[kind] or {}
  local chooser = remuda._butler_chooser
  local compaction = remuda._butler_compaction
  local lines = compaction and compaction.bottom_screen_lines
  local context = lines and table.concat(lines(prefix, 4), '\n') .. '\n' .. signature or signature
  local modal = chooser and chooser.startup_modal and chooser.startup_modal(startup, context)
  if modal and modal.trust and chooser.trust_plan(modal, context) then return context end
  if modal and (modal.update or modal.title == 'Teach auto mode') then
    local count = 0
    for line in (signature .. '\n'):gmatch('(.-)\n') do
      local _, label = compaction.numbered_option(line)
      if label then
        label, count = label:lower():gsub('%s+$', ''), count + 1
        if modal.update then
          if label ~= 'skip' and not label:match('^skip ') and not label:match('^update now') then return nil end
        elseif label ~= 'not now' and label ~= "don't show again" then return nil end
      end
    end
    if count > 0 then return context end
  end
end

local function classify(name, agent, screen)
  if type(screen) ~= 'string' then return nil, nil, true end
  local startup = (remuda._butler_agent_startup or {})[agent.kind] or {}
  local compaction = remuda._butler_compaction
  local geometry = compaction and compaction.unknown_dialog_signature
  local signature = current_geometry(screen, geometry)
  local probes = { unknown = function(current)
    return exception_signature(agent.kind, current, current_geometry(current, geometry))
  end }
  if legacy_owned(name, agent, screen, signature) then return nil, nil, true end
  local picker = signature and startup.picker and startup.picker(screen)
  if picker then return "codex_" .. picker.kind .. "_picker", picker.signature end
  for _, descriptor in ipairs(startup.blocking or {}) do
    assert(descriptor.risk == 'report' and type(descriptor.id) == 'string'
      and type(descriptor.match) == 'function', 'invalid reporting-only dialog descriptor')
    local signature = descriptor.match(screen, probes)
    if type(signature) == 'string' and signature ~= '' then return descriptor.id, signature end
  end
  -- Screen recognition is not an authorization requirement. Only a positively
  -- detected exceptional state stops input, including a nonempty composer after
  -- type_text whose first Return was dropped.
  return nil, nil, true
end

local function observe(name, agent, alias, instance, screen, failure)
  local state = states[name]
  if not state or state.instance ~= instance or state.agent ~= agent then
    state = { instance = instance, agent = agent, captures = 0 }
    states[name] = state
  end
  local ok, id, signature, resolved
  if failure then
    ok, id, signature = true, failure, failure
  else
    ok, id, signature, resolved = pcall(classify, name, agent, screen)
  end
  if not ok then id, signature, resolved = nil, nil, true end
  if id then
    if state.id ~= id or state.signature ~= signature then
      state.id, state.signature, state.captures = id, signature, 0
      state.audited, state.reported = nil, nil
    end
    state.captures = state.captures + 1
    state.blocked = true -- stop on the first capture, not after debounce
    if state.captures >= 2 then
      if not state.audited then state.audited = audit(name, agent, state, 'dialog_blocked') end
      report(name, agent, alias, state)
    end
  elseif state.blocked and resolved then
    if audit(name, agent, state, 'dialog_resolved', 'wait', 'no_exception_detected') then
      state.id, state.signature, state.blocked = nil, nil, nil
      state.captures, state.reported, state.audited = 0, nil, nil
    end
  end
  return not state.blocked, state
end

function M.check(name)
  local agent, alias = agent_for(name)
  if not agent then return true end
  -- ls exposes instance_id on the core versions used by launch's identity gate;
  -- session() is a busy-state API and need not expose this field.
  local listed, sessions = pcall(remuda.ls)
  local session
  for _, row in ipairs(listed and type(sessions) == 'table' and sessions or {}) do
    if row.name == name and row.alive then session = row; break end
  end
  local instance = agent.instance_id or (session and session.instance_id) or agent
  local failure
  if not session then failure = 'session_unavailable'
  elseif agent.instance_id and session.instance_id ~= agent.instance_id then failure = 'session_replaced' end
  local captured, screen = pcall(remuda.capture, name)
  -- Missing/malformed captures are unknown screens, not identified modals.
  -- Session availability and instance fencing above remain mandatory.
  if not captured or type(screen) ~= 'string' then screen = nil end
  return observe(name, agent, alias, instance, screen, failure)
end

function M.tick()
  local listed, sessions = pcall(remuda.ls)
  if not listed or type(sessions) ~= 'table' then return end
  local live = {}
  for _, session in ipairs(sessions) do
    if session.alive then
      live[session.name] = true
      if agent_for(session.name) then M.check(session.name) end
    end
  end
  for name in pairs(states) do if not live[name] then states[name] = nil end end
end

-- Notice deferral is specifically a picker wait, not the general write gate:
-- verification of already submitted mail must still observe subsequent dialogs.
function M.picker_pending(name)
  local agent = agent_for(name)
  if not agent or agent.kind ~= "codex" then return false end
  local startup = (remuda._butler_agent_startup or {}).codex or {}
  if type(startup.picker) ~= "function" then return false end
  local captured, screen = pcall(remuda.capture, name)
  if not captured or type(screen) ~= "string" then return true end
  return startup.picker(screen) ~= nil
end

-- Explicit owner recovery cancels only a complete known Codex picker. It
-- never lends general write authority to the reporting gate or changes models.
local recovering = {}
function M.recover_input(name, done)
  local agent, alias = agent_for(name)
  if not agent or agent.kind ~= "codex" then return done("Recovery refused: target is not a managed Codex session.") end
  if recovering[name] then return done("Recovery already pending for " .. name .. ".") end
  local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
  local member = (lifecycle.compaction_members or {})[agent.id or name]
  if member and (member.compaction_in_progress or member.dialog_operation) then
    return done("Recovery refused: a compaction workflow still owns this session. Wait for its bounded cleanup.")
  end
  local startup = (remuda._butler_agent_startup or {}).codex or {}
  local function snapshot()
    if butler.dialogs ~= M or agent_for(name) ~= agent then return nil end
    local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
    local member = (lifecycle.compaction_members or {})[agent.id or name]
    if member and (member.compaction_in_progress or member.dialog_operation) then return nil end
    local ok, sessions = pcall(remuda.ls)
    local instance
    for _, row in ipairs(ok and sessions or {}) do
      if row.name == name and row.alive and type(row.instance_id) == "string" and row.instance_id ~= "" then
        instance = row.instance_id
      end
    end
    if not instance or (agent.instance_id and agent.instance_id ~= instance) then return nil end
    local captured, screen = pcall(remuda.capture, name)
    if not captured or type(screen) ~= "string" then return nil end
    return {instance=instance, screen=screen, picker=startup.picker and startup.picker(screen)}
  end
  local initial = snapshot()
  if not initial or not initial.picker then return done("Recovery refused: no complete known Codex model/effort picker. No input was sent.") end
  local telemetry = remuda._butler_telemetry_for and remuda._butler_telemetry_for(agent) or {}
  local initial_model = type(telemetry.model) == "string" and telemetry.model:match("^gpt%-[%w%.%-]+$") and telemetry.model or "unknown"
  local token = {instance=initial.instance, escapes=0}
  recovering[name] = token
  local handle, finished
  local function finish(reason, final)
    if finished then return end
    finished = true
    if handle and handle.cancel then handle:cancel() end
    if recovering[name] == token then recovering[name] = nil end
    local text = "Input recovery " .. name .. ": " .. reason .. ". Initial actual model=" .. initial_model
      .. "; initial effort=unknown; picker=" .. initial.picker.kind
      .. (initial.picker.model and ("/" .. initial.picker.model) or "")
      .. "; ESC sent=" .. token.escapes .. "."
    if final then text = text .. " Current model/effort=" .. final .. "." end
    done(text .. " No model was selected; intended settings were not inferred. Queued inbox mail is retained.")
  end
  local function current()
    local now = snapshot()
    if not now or now.instance ~= token.instance or recovering[name] ~= token then return nil end
    return now
  end
  local step
  step = function(observed)
    local now = current()
    if not now then return finish("stopped: session changed or capture unavailable") end
    if not now.picker then
      local unknown = remuda._butler_compaction and remuda._butler_compaction.unknown_dialog_signature
      local empty = remuda._butler_prompt_is_empty and remuda._butler_prompt_is_empty("codex", now.screen) == "EMPTY"
      local model, effort = now.screen:match("(GPT%-[%w%.%-]+)%s+(%a+)%s+·")
      if empty and model and effort and not (unknown and unknown(now.screen)) then
        if not M.check(name) then return finish("stopped: resolution audit unavailable") end
        return finish("completed; composer is safe", model:lower() .. " " .. effort:lower())
      end
      return finish("stopped: picker disappeared without a verified safe composer")
    end
    if now.picker.signature ~= observed.picker.signature or now.picker.kind ~= observed.picker.kind then
      return finish("stopped: dialog changed before cancellation")
    end
    if token.escapes >= 2 then return finish("stopped: cancellation limit reached") end
    local decision = {instance=token.instance, id="codex_picker_cancel", signature=now.picker.signature}
    if not audit(name, agent, decision, "dialog_action", "key/ESC", "owner_recovery") then
      return finish("stopped: audit unavailable")
    end
    local checked = current()
    if not checked or not checked.picker or checked.picker.signature ~= now.picker.signature then
      return finish("stopped: session or dialog changed during audit")
    end
    local originals = remuda._butler_dialog_originals
    if not originals or not originals.key then return finish("stopped: original key API unavailable") end
    local sent, result = pcall(originals.key, name, "ESC")
    audit(name, agent, decision, "dialog_action_result", "key/ESC", sent and result ~= false and "returned" or "not_written")
    if not sent or result == false then return finish("stopped: cancellation refused") end
    token.escapes = token.escapes + 1
    local previous = now.picker
    local ok, next_handle = pcall(remuda.expect, name, {{id="owner-picker-cancel", match=function()
      local next = current()
      return not next or not next.picker or next.picker.signature ~= previous.signature
    end, action=function()
      if handle and handle.cancel then handle:cancel() end
      local next = current()
      if not next then return finish("stopped: session changed") end
      -- ESC must make the observed effort picker go back to model, or close
      -- the model picker. Any other transition ends this one-shot authority.
      if next.picker and (previous.kind ~= "effort" or next.picker.kind ~= "model") then
        return finish("stopped: unexpected picker transition")
      end
      step(next)
    end}}, {timeout=5, interval=0.1,
      on_timeout=function() finish("stopped: cancellation timed out; reissue a fresh owner command after review") end,
      on_error=function() finish("stopped: cancellation watcher failed") end}, false)
    if not ok then return finish("stopped: cancellation watcher unavailable") end
    handle = next_handle
  end
  step(initial)
end

local function gated_write(original, operation, name, ...)
  local agent = agent_for(name)
  if not agent then return original(name, ...) end
  local allowed, state = M.check(name)
  if not allowed then error('Butler dialog blocked; waiting for owner review', 0) end
  -- No prepared text or arbitrary key strings enter the log.
  local key = select(1, ...)
  local safe_key = type(key) == 'string' and (key == 'RET' or key == 'ESC' or key == 'UP'
    or key == 'DOWN' or key == 'C-u' or key:match('^%d$'))
  local action = operation == 'key' and (safe_key and ('key/' .. key) or 'terminal_key') or operation
  if not audit(name, agent, state, 'dialog_action', action, 'before_write') then
    error('Butler dialog audit unavailable; input refused', 0)
  end
  -- An audit append can yield on its lock: recheck the instance and screen.
  allowed = M.check(name)
  if not allowed or states[name] ~= state or agent_for(name) ~= agent then
    audit(name, agent, state, 'dialog_action_result', action, 'not_written')
    error('Butler dialog blocked or session changed during audit', 0)
  end
  local result = pack(pcall(original, name, ...))
  local outcome = not result[1] and 'error' or result[2] == false and 'refused' or 'returned'
  audit(name, agent, state, 'dialog_action_result', action, outcome)
  if not result[1] then error(result[2], 0) end
  return unpack_args(result, 2, result.n)
end

function M.install()
  -- Reload replaces this module but retains the original core functions once.
  local originals = remuda._butler_dialog_originals
  if not originals then
    originals = { key = remuda.key, type_text = remuda.type_text, send = remuda.send }
    remuda._butler_dialog_originals = originals
  end
  remuda.key = function(name, ...)
    return butler.dialogs.write(originals.key, 'key', name, ...)
  end
  remuda.type_text = function(name, ...)
    return butler.dialogs.write(originals.type_text, 'type_text', name, ...)
  end
  if originals.send then
    remuda.send = function(name, ...)
      return butler.dialogs.write(originals.send, 'send', name, ...)
    end
  end
end
M.write = gated_write
function M.stop()
  if butler.dialogs ~= M then return end -- retiring activation cannot unwrap its replacement
  local originals = remuda._butler_dialog_originals
  if originals then
    remuda.key, remuda.type_text = originals.key, originals.type_text
    if originals.send then remuda.send = originals.send end
    remuda._butler_dialog_originals = nil
  end
end
return M
