-- Trusted, fixture-backed descriptors only. No concrete agent recognizers are
-- enabled here; unknown panes and classifier denials remain report-only.
local butler = assert(remuda.butler)
local approval = assert(butler.approval)
local M = {}
butler.dialog_approval = M

local function hash(value)
  local guard = butler.guard_approval
  if not guard or type(guard.sha256) ~= 'function' then return nil end
  local ok, digest = pcall(guard.sha256, value)
  if ok and type(digest) == 'string' and digest ~= '' then return digest end
end

local function bounded(value, limit)
  return type(value) == 'string' and value ~= '' and #value <= limit and not value:find('%c')
end

local function snapshot(name, descriptor_id, observed)
  local bus = remuda._butler_bus or {}
  local agent = (bus.agents or {})[name]
  if not agent then
    for _, candidate in pairs(bus.agents or {}) do
      if candidate.session_name == name then agent = candidate; break end
    end
  end
  if not agent or not bounded(agent.instance_id, 256) or not bounded(agent.id, 256)
      or not bounded(agent.session_start_marker, 256) then return nil end
  local startup = (remuda._butler_agent_startup or {})[agent.kind] or {}
  if #(startup.dialog_approvals or {}) == 0 then return nil end
  if type(approval.dialog_actions_enabled) ~= 'function'
      or approval.dialog_actions_enabled() ~= true then return nil end
  local state = observed
  if not state then
    local checked, ready
    checked, ready, state = pcall(butler.dialogs.check, name)
    if not checked then return nil end
  end
  if not state or state.agent ~= agent or state.instance ~= agent.instance_id
      or not state.blocked or state.captures < 2 or type(state.entry) ~= 'table'
      or state.entry.response ~= 'approval' or state.entry.action_scope ~= 'once' then return nil end
  local listed, rows = pcall(remuda.ls)
  if not listed or type(rows) ~= 'table' then return nil end
  local live
  for _, row in ipairs(rows) do
    if row.name == name then
      live = row.alive == true and row.instance_id == agent.instance_id and row.attached ~= true
      break
    end
  end
  if not live then return nil end
  local captured, screen = pcall(remuda.capture, name)
  if not captured or type(screen) ~= 'string' then return nil end
  for _, descriptor in ipairs(startup.dialog_approvals or {}) do
    if (not descriptor_id or descriptor.id == descriptor_id) and descriptor.state_id == state.id
        and bounded(descriptor.id, 128)
        and bounded(descriptor.version, 64) and bounded(descriptor.fixture, 512)
        and descriptor.action_scope == 'once'
        and (descriptor.category == 'permission' or descriptor.category == 'acknowledgement')
        and type(descriptor.match) == 'function' and type(descriptor.verify) == 'function' then
      local ok, plan = pcall(descriptor.match, screen)
      if ok and type(plan) == 'table' and type(plan.signature) == 'string' and plan.signature ~= ''
          and #plan.signature <= 16384 and bounded(plan.label, 128) and bounded(plan.summary, 256)
          and type(plan.key) == 'string' and (plan.key == 'RET' or plan.key:match('^%d$')) then
        -- A descriptor may name the prompt's own cancel key so a live owner can
        -- reject without a standing grant. Only ESC is accepted and the request
        -- still carries one key per verdict.
        local deny_key, deny_label
        if descriptor.deny_key ~= nil then
          if descriptor.deny_key ~= 'ESC' or not bounded(descriptor.deny_label, 128) then return nil end
          deny_key, deny_label = descriptor.deny_key, descriptor.deny_label
        end
        local signature_hash, state_hash = hash(plan.signature), hash(state.signature or '')
        if signature_hash and state_hash then
          return { session = name, agent_id = agent.id, kind = agent.kind, instance_id = agent.instance_id,
            session_marker = agent.session_start_marker, dialog_id = descriptor.id,
            handler_version = descriptor.version, signature_hash = signature_hash, state_hash = state_hash,
            key = plan.key, label = plan.label, summary = plan.summary,
            deny_key = deny_key, deny_label = deny_label }, state, descriptor
        end
      end
    end
  end
end

-- The renderer is bounded and shown in a configured room only; a missing room
-- or an over-long request fails closed (the report-only notice then remains).
local MAX_RENDER = 2048
local function target_room()
  if type(approval.target_room) ~= 'function' then return nil end
  local ok, room = pcall(approval.target_room)
  if not ok or not bounded(room, 512) then return nil end
  return room
end
local function render_request(rec, name, data)
  return 'Butler dialog approval ' .. rec.id .. '\nAgent: ' .. data.kind .. ' / ' .. name
    .. '\nAction (untrusted screen text): ' .. data.summary
    .. '\nApprove ✅ → choose "' .. data.label .. '" once (' .. data.key .. ').'
    .. (data.deny_label and ('\n❌ / no → ' .. data.deny_label .. '.') or '')
    .. '\nOne input only; changed screens or sessions refuse it. No standing permission is granted.'
    .. '\nReact ✅ / ❌ or reply yes / no to this message within 10 minutes.'
    .. '\n[Butler approval ' .. rec.id .. ']'
end

-- True when a trusted descriptor currently matches this exact dialog and its
-- request could be posted, so the report-only owner notice would duplicate it.
function M.actionable(name, observed)
  return target_room() ~= nil and snapshot(name, nil, observed) ~= nil
end

local function same(current, saved)
  if not current or type(saved) ~= 'table' then return false end
  for _, field in ipairs({ 'session', 'agent_id', 'kind', 'instance_id', 'session_marker', 'dialog_id',
      'handler_version', 'signature_hash', 'state_hash', 'key', 'label', 'summary',
      'deny_key', 'deny_label' }) do
    if current[field] ~= saved[field] then return false end
  end
  return true
end

local function audit(data, event, outcome, rec, key)
  local policy = butler.guard_policy
  if not policy or type(policy.append) ~= 'function' then return false end
  local ok, wrote = pcall(policy.append, { session = data.session, kind = data.kind,
    event = event, tool = 'dialog', class = 'other', summary = outcome,
    instance_id = data.instance_id, dialog_id = data.dialog_id, handler_version = data.handler_version,
    hash = data.signature_hash, action = 'key/' .. (key or data.key), id = rec and rec.id,
    owner = rec and rec.answered_by, owner_event_id = rec and rec.answer_event_id })
  return ok and wrote == true
end

function M.consider(name, observed)
  local data, state = snapshot(name, nil, observed)
  if not data or state.approval_attempted == data.signature_hash then return end
  -- Fail closed before posting: no configured room or an over-long request
  -- leaves the dialog to the report-only path instead of guessing.
  if not target_room() or #render_request({ id = 'XXXXXXXX' }, name, data) > MAX_RENDER then return end
  -- A denial/expiry/posting failure does not silently create another request.
  state.approval_attempted = data.signature_hash
  if not audit(data, 'dialog_approval_requested', 'before_request') then return end
  approval.request({ kind = 'dialog_action', asker = name,
    key = data.instance_id .. ':' .. data.dialog_id .. ':' .. data.signature_hash,
    summary = data.summary .. ' in ' .. name .. '; choose ' .. data.label .. ' once', data = data,
    ttl_s = math.min(approval.default_ttl_s(), 600), max_open_for_asker = 1,
    render = function(rec) return render_request(rec, name, data) end,
  }, function(id)
    audit(data, 'dialog_approval_requested', id and 'posted' or 'unavailable', id and {id = id})
  end)
end

-- One permitted key per verdict. The caller has already fixed the key from the
-- trusted descriptor; nothing here accepts owner text or a key sequence.
local function execute(rec, done, key, verdict)
  local data = rec.data
  if rec.delivery_started or not tonumber(rec.expires_at) or os.time() * 1000 >= rec.expires_at then
    done(false, 'expired or already consumed'); return
  end
  local current, _, descriptor = snapshot(data.session, data.dialog_id)
  if not same(current, data) then done(false, 'dialog or session changed'); return end
  if not audit(data, 'dialog_action', 'before_write', rec, key) then done(false, 'audit unavailable'); return end
  -- Persist consumption BEFORE the one permitted key; failures/restarts never replay it.
  if not approval.begin_delivery(rec, verdict) then done(false, 'consumption could not be persisted'); return end
  current = snapshot(data.session, data.dialog_id)
  if not same(current, data) then
    audit(data, 'dialog_action_result', 'not_written', rec, key)
    done(false, 'dialog changed during audit'); return
  end
  local originals = remuda._butler_dialog_originals
  if not originals or type(originals.key) ~= 'function' then done(false, 'input unavailable'); return end
  -- This bounded executor is the only path around the ordinary unknown-dialog
  -- gate. It accepts no arbitrary text, key sequence or standing grant.
  local ok, result = pcall(originals.key, data.session, key)
  local captured, screen = pcall(remuda.capture, data.session)
  local verified, matches = false, false
  if captured and type(screen) == 'string' then verified, matches = pcall(descriptor.verify, screen) end
  local listed, rows = pcall(remuda.ls)
  local same_instance = false
  for _, row in ipairs(listed and type(rows) == 'table' and rows or {}) do
    if row.name == data.session and row.alive and row.instance_id == data.instance_id then same_instance = true end
  end
  local success = ok and result ~= false and verified and matches == true and same_instance
  local logged = audit(data, 'dialog_action_result', success and 'verified' or 'uncertain', rec, key)
  done(success and logged, success and (not logged and 'outcome audit unavailable' or nil)
    or 'input outcome uncertain; inspect pane, never retry automatically')
end

approval.handler('dialog_action', {
  before_answer = function(rec, verdict, who, event_id)
    local terminal_deny = verdict == 'deny' and who == 'operator (terminal)'
    if not terminal_deny and (verdict == 'grant' or who == 'operator (terminal)' or not bounded(who, 256)
        or not bounded(event_id, 256)) then return false, 'live owner event required' end
    local data = rec.data
    if type(data) ~= 'table' or not bounded(data.key, 16) then return false, 'invalid dialog request' end
    -- Provenance is supplied by the strict Matrix relay gate, never terminal approval.
    return audit(data, 'dialog_approval_answer', verdict, {
      id = rec.id, answered_by = who, answer_event_id = event_id }), 'audit unavailable'
  end,
  approve = function(rec, done) execute(rec, done, rec.data.key, 'approve') end,
  deny = function(rec)
    local data = rec.data
    -- A live owner rejection may cancel the prompt with the descriptor's own
    -- ESC key. The terminal and an absent live event never write; neither does
    -- a descriptor without a deny plan.
    local live = type(data) == 'table' and type(data.deny_key) == 'string'
      and rec.answered_by ~= 'operator (terminal)' and bounded(rec.answered_by, 256)
      and bounded(rec.answer_event_id, 256)
    if live then execute(rec, function() end, data.deny_key, 'deny') end
    audit(data, 'dialog_approval_closed', 'denied', rec)
  end,
  expire = function(rec) audit(rec.data, 'dialog_approval_closed', 'expired', rec) end,
})

return M
