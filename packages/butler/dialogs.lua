-- Reporting-only blocking-state dispatcher. The agent descriptor lists contain
-- pure screen matchers: { id, risk = "report", match(screen, probes) -> signature }.
-- No descriptor is allowed to write input. Existing startup/compaction handlers
-- retain their policy; all managed writes pass through a fresh screen/audit gate.
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

local function legacy_owned(agent, screen)
  local startup = (remuda._butler_agent_startup or {})[agent.kind] or {}
  local chooser = remuda._butler_chooser
  if chooser and chooser.known_startup_modal and chooser.known_startup_modal(startup, screen) then
    return true -- existing conditional trust/update/Teach policy, unchanged
  end
  local lifecycle = remuda._butler_state or remuda._butler_compaction_state or {}
  if lifecycle.compaction_fleet_active ~= (agent.id or agent.session_name) then return false end
  if agent.kind == 'claude' then
    return remuda._butler_model_confirm_signature and remuda._butler_model_confirm_signature(screen) ~= nil
  end
  -- These are already owned by compaction_run.lua's bounded picker workflow.
  local lower = screen:lower()
  return lower:find('select model and effort', 1, true) ~= nil
    or lower:find('select reasoning level for ', 1, true) ~= nil
end

local function classify(agent, screen)
  local startup = (remuda._butler_agent_startup or {})[agent.kind] or {}
  if legacy_owned(agent, screen) then return nil, nil, true end
  local compaction = remuda._butler_compaction
  local probes = { unknown = compaction and compaction.unknown_dialog_signature }
  for _, descriptor in ipairs(startup.blocking or {}) do
    assert(descriptor.risk == 'report' and type(descriptor.id) == 'string'
      and type(descriptor.match) == 'function', 'invalid reporting-only dialog descriptor')
    local signature = descriptor.match(screen, probes)
    if type(signature) == 'string' and signature ~= '' then return descriptor.id, signature end
  end
  local working = startup.working and startup.working(screen)
    or screen:find('esc to interrupt', 1, true) ~= nil
  local ready = startup.ready and startup.ready(screen)
  return nil, nil, working == true or ready == true
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
    ok, id, signature, resolved = pcall(classify, agent, screen)
  end
  if not ok then id, signature = 'detection_unavailable', 'detection_unavailable' end
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
    if audit(name, agent, state, 'dialog_resolved', 'wait', 'ready_or_workflow_owned') then
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
  if not failure and (not captured or type(screen) ~= 'string') then failure = 'capture_unavailable' end
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

local function gated_write(original, operation, name, ...)
  local agent = agent_for(name)
  if not agent then return original(name, ...) end
  local allowed, state = M.check(name)
  if not allowed then return false, 'Butler dialog blocked; waiting for owner review' end
  -- No prepared text or arbitrary key strings enter the log.
  local key = select(1, ...)
  local safe_key = type(key) == 'string' and (key == 'RET' or key == 'ESC' or key == 'UP'
    or key == 'DOWN' or key == 'C-u' or key:match('^%d$'))
  local action = operation == 'key' and (safe_key and ('key/' .. key) or 'terminal_key') or operation
  if not audit(name, agent, state, 'dialog_action', action, 'before_write') then
    return false, 'Butler dialog audit unavailable; input refused'
  end
  -- An audit append can yield on its lock: recheck the instance and screen.
  allowed = M.check(name)
  if not allowed or states[name] ~= state or agent_for(name) ~= agent then
    audit(name, agent, state, 'dialog_action_result', action, 'not_written')
    return false, 'Butler dialog blocked or session changed during audit'
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
