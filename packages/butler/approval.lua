-- Durable, relay-backed approval requests. Policy callbacks are registered
-- by the feature that owns each request kind; only request data is persisted.
local butler = assert(remuda.butler, "load butler/matrix before butler/approval")
local approval = butler.approval or {}
butler.approval = approval

local handlers = approval._handlers or {}
approval._handlers = handlers
local attached
local applying = {}
local pending_requests = {}
local function safe_line(value, limit)
  value = tostring(value or "")
  local matrix = butler.matrix
  if matrix and type(matrix.sanitize_directory_text) == "function" then
    value = matrix.sanitize_directory_text(value, limit or 128)
  else
    value = value:gsub("[%c]", " "):gsub("\194[\128-\159]", " ")
  end
  return (value:gsub("[\r\n]+", " "))
end

local CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local function random_bytes(n)
  if type(remuda.random_bytes) == "function" then
    local ok, bytes = pcall(remuda.random_bytes, n)
    if ok and type(bytes) == "string" and #bytes >= n then return bytes:sub(1, n) end
  end
  local ok, file = pcall(io.open, "/dev/urandom", "rb")
  if ok and file then
    local bytes = file:read(n)
    file:close()
    if type(bytes) == "string" and #bytes == n then return bytes end
  end
  return nil
end

local function random_id(state)
  for _ = 1, 32 do
    local bytes = random_bytes(3)
    if not bytes then return nil end
    local value = bytes:byte(1) * 65536 + bytes:byte(2) * 256 + bytes:byte(3)
    local chars = {}
    for i = 1, 4 do
      chars[i] = CROCKFORD:sub((value % 32) + 1, (value % 32) + 1)
      value = math.floor(value / 32)
    end
    local id = table.concat(chars):reverse()
    local used = false
    for existing in pairs(state.approvals or {}) do
      if type(existing) == "string" and existing:upper() == id then used = true; break end
    end
    if not used then
      for _, pending in pairs(pending_requests) do
        if pending.id:upper() == id then used = true; break end
      end
    end
    if not used then return id end
  end
  return nil
end

function approval.source_refresh_busy()
  if next(pending_requests) or next(applying) then return true end
  for _, record in pairs(attached and attached.state and attached.state.approvals or {}) do
    if record.status == "open" or record.status == "approved" then return true end
  end
  return false
end

local function hex(bytes)
  local out = {}
  for i = 1, #bytes do out[i] = string.format("%02x", bytes:byte(i)) end
  return table.concat(out)
end

local function open_records(state)
  local rows = {}
  for _, record in pairs(state and state.approvals or {}) do
    if type(record) == "table" and (record.status == "open"
      or (record.kind == "approve_text" and (record.status == "approved" or record.status == "queued"
        or record.status == "delivery_uncertain" or record.status == "delivery_quarantined"))) then rows[#rows + 1] = record end
  end
  table.sort(rows, function(a, b)
    local at, bt = tonumber(a.created_ms), tonumber(b.created_ms)
    if at and bt and at ~= bt then return at < bt end
    if at and not bt then return true end
    if bt and not at then return false end
    return tostring(a.id) < tostring(b.id)
  end)
  return rows
end

local function request_key(asker, kind, key)
  asker, kind, key = tostring(asker), tostring(kind), tostring(key)
  return #asker .. ":" .. asker .. #kind .. ":" .. kind .. #key .. ":" .. key
end

local function persist()
  if attached and attached.persist then return attached.persist() end
  return true
end

function approval.handler(kind, callbacks)
  assert(type(kind) == "string" and kind ~= "", "approval handler kind is required")
  assert(type(callbacks) == "table", "approval callbacks are required")
  handlers[kind] = callbacks
  return true
end

-- Seconds a finished approval record is kept. It must outlive the longest standing grant (guard_grants.MAX_TTL,
-- 24 h): the grant store trusts a grant only while Butler's record of the owner's reaction exists.
approval.RETENTION_S = 24 * 60 * 60

-- Minutes an owner approval request stays open (configured by `approval_ttl_minutes`).
approval.ttl_minutes = 30
function approval.default_ttl_s() return approval.ttl_minutes * 60 end

function approval.attach(state, persist_fn, post_fn, room_fn, home_room, dialog_actions)
  assert(type(state) == "table", "approval state is required")
  if type(state.approvals) ~= "table" or state.approvals == remuda.json.null then
    state.approvals = remuda.json and remuda.json.object({}) or {}
  end
  attached = { state = state, persist = persist_fn, post = post_fn, approval_room = room_fn,
    home_room = home_room, dialog_actions = dialog_actions == true }
  local recovered = false
  local restarted_ms = math.floor(os.time() * 1000)
  for _, rec in pairs(state.approvals) do
    -- A guard request is answered only while its hook waits; a restart ends the wait.
    if type(rec) == "table" and (rec.kind == "guard_action" or rec.kind == "dialog_action")
        and (rec.status == "open" or rec.status == "approved") then
      rec.status, rec.answered_at, rec.error = "expired", restarted_ms, "daemon restarted"
      local callback = handlers[rec.kind] and handlers[rec.kind].expire
      if callback then pcall(callback, rec) end
      recovered = true
    end
  end
  for _, rec in pairs(state.approvals) do
    if type(rec) == "table" and rec.kind == "approve_text" then
      local data = type(rec.data) == "table" and rec.data or {}
      if data.session_binding_version ~= 2 then
        data.session_start, data.session_marker = nil, nil
        rec.data = data
        if rec.status == "open" or rec.status == "approved" then
          rec.status, rec.error = "failed", "session binding changed; re-register prepared text"
        end
        recovered = true
      end
      if rec.status == "approved" and rec.delivery_started == true then
        rec.status, rec.error = "failed", "delivery outcome unknown after restart"
        rec.recovery_notice = { owner_sent = false, agent_sent = false }
        recovered = true
      end
    end
  end
  if recovered then persist() end
  for _, rec in pairs(state.approvals) do
    local notice = type(rec) == "table" and rec.recovery_notice
    if type(notice) == "table" and rec.kind == "approve_text" and rec.status == "failed" then
      if notice.owner_sent ~= true and type(rec.event_id) == "string" and rec.event_id ~= ""
          and type(attached.post) == "function" then
        local called = pcall(attached.post,
          "Delivery outcome unknown after restart. The prepared text may not have been typed; register it again before asking for approval.",
          { rel_type = "m.thread", event_id = rec.event_id }, function(result)
            if type(result) == "table" and not result.error then
              notice.owner_sent = true
              pcall(persist)
            end
          end, { room = rec.room_id })
        if not called then notice.owner_sent = false end
      end
      if notice.agent_sent ~= true and type(remuda._butler_send) == "function"
          and type(rec.asker) == "string" then
        local called, sent = pcall(remuda._butler_send, "butler", rec.asker,
          "Prepared text request " .. tostring(rec.id)
            .. " had an unknown delivery outcome after restart; it may not have been typed. Register the text again before requesting approval.")
        if called and sent ~= nil and sent ~= false then
          notice.agent_sent = true
          pcall(persist)
        end
      end
      if notice.owner_sent == true and notice.agent_sent == true then
        rec.recovery_notice = nil
        pcall(persist)
      end
    end
  end
  return true
end

-- One-time dialog answers are an explicit owner opt-in; absent config stays off.
function approval.dialog_actions_enabled()
  return attached ~= nil and attached.dialog_actions == true
end

-- `verdict` selects the one-shot status a dialog action must be in: an
-- approval sends the affirmative key, a denial sends the descriptor's refusal
-- key. Both consume the record before writing.
function approval.begin_delivery(rec, verdict)
  if not attached or type(rec) ~= "table" then return false end
  if rec.kind == "dialog_action" then
    local expected = verdict == "deny" and "denied" or "approved"
    if rec.status ~= expected or rec.delivery_started == true then return false end
  elseif rec.kind ~= "approve_text"
      or (rec.status ~= "approved" and rec.status ~= "queued") or rec.delivery_started == true then
    return false
  end
  rec.delivery_started = true
  local ok, result = pcall(persist)
  if not ok or result == false then
    rec.status, rec.error = "failed", "could not persist one-shot delivery marker"
    return false
  end
  return true
end

-- Decision and delivery are separate dimensions. `status` is the stored
-- decision lifecycle; `delivery` is the one-shot delivery observation.
-- "uncertain" is never success, and it is never retried automatically.
local function delivery_state(rec)
  if rec.kind ~= "approve_text" then return "not_applicable" end
  if rec.status == "open" then return "none" end
  if rec.status == "queued" then return "queued" end
  if rec.status == "delivery_uncertain" then return "uncertain" end
  if rec.status == "delivery_quarantined" then return "quarantined" end
  if rec.status == "approved" then
    return rec.delivery_started == true and "in_flight" or "not_started"
  end
  return "unknown"
end
approval.delivery_state = delivery_state

function approval.status_label(rec)
  local delivery = delivery_state(rec)
  if delivery == "uncertain" then return "delivery uncertain" end
  if delivery == "quarantined" then return "delivery quarantined" end
  if delivery == "in_flight" then return "delivering" end
  if delivery == "queued" then return "queued" end
  return tostring(rec.status or "unknown")
end

-- Metadata only: never prepared text, nonces, Matrix/audit proof, or the rest
-- of `data`. The message is untrusted input, so keep it on one line.
local function metadata(rec, now)
  local expires_at = tonumber(rec.expires_at)
  local data = type(rec.data) == "table" and rec.data or nil
  local target = data and data.session
  local instance = data and (data.instance_id or data.core_instance)
  local instance_bound = type(instance) == "string" and instance ~= ""
    or (data ~= nil and tonumber(data.session_binding_version) == 2
      and type(data.session_marker) == "string" and data.session_marker ~= "")
  local decision_path
  -- Provenance is only labelled when there is evidence for it. The terminal
  -- check comes first so a contradictory record (terminal answer plus an event
  -- id) cannot leak out as an owner decision.
  if rec.answered_by == "operator (terminal)" then
    decision_path = "operator"
  elseif type(rec.answer_event_id) == "string" and rec.answer_event_id ~= "" then
    decision_path = "owner_matrix"
  end
  return {
    id = safe_line(rec.id, 26),
    kind = safe_line(rec.kind, 32),
    status = safe_line(rec.status, 32),
    delivery = delivery_state(rec),
    asker = safe_line(rec.asker, 128),
    target_session = type(target) == "string" and safe_line(target, 128) or nil,
    instance_bound = instance_bound or nil,
    decision_path = decision_path,
    summary = safe_line(rec.summary, 128),
    created_at = tonumber(rec.created_ms) or 0,
    expires_at = expires_at or 0,
    expires_in_s = expires_at and math.max(0, math.ceil((expires_at - now) / 1000)) or 0,
  }
end

-- nil means the store is unavailable; an empty table means no requests.
-- Renderers must not present unavailable as an empty list.
function approval.list()
  if not attached then return nil, "unavailable" end
  approval.sweep()
  return open_records(attached.state)
end

-- A read-only, local snapshot for TUI/GUI/CLI consumers. It carries no
-- decision authority and does not claim cluster truth; it only reports what
-- this Butler process currently records.
function approval.snapshot(now)
  local rows, why = approval.list()
  if not rows then return nil, why end
  now = tonumber(now) or math.floor(os.time() * 1000)
  local records = {}
  for i, rec in ipairs(rows) do records[i] = metadata(rec, now) end
  return { schema = 1, authority = "butler-local", generated_at = now, records = records }
end

function approval.for_event(event_id)
  if not attached or type(event_id) ~= "string" then return nil end
  for _, rec in pairs(attached.state.approvals or {}) do
    if type(rec) == "table" and rec.event_id == event_id then return rec end
  end
end

function approval.for_id(id)
  if not attached or type(id) ~= "string" then return nil end
  for key, rec in pairs(attached.state.approvals or {}) do
    if type(rec) == "table" and (tostring(key):upper() == id:upper()
      or (type(rec.id) == "string" and rec.id:upper() == id:upper())) then return rec end
  end
end

function approval.reply(rec, text)
  if not attached or type(attached.post) ~= "function" then
    return nil, "Matrix relay is not running. Next: remuda butler matrix status"
  end
  if type(rec) ~= "table" or type(rec.event_id) ~= "string" or rec.event_id == "" then
    return nil, "Approval request event is unavailable"
  end
  return attached.post(text, { rel_type = "m.thread", event_id = rec.event_id }, function() end,
    { room = rec.room_id })
end

-- Butler's own record that the owner's reaction (the Matrix event id) turned this request into this standing grant,
-- held by this session id.
-- The relay writes answer_event_id only for the verified owner; the grant store trusts nothing on its own.
function approval.granted_by(event_id, grant_id, class, scope, holder)
  if not attached or type(event_id) ~= "string" or event_id == "" then return false end
  for _, rec in pairs(attached.state.approvals or {}) do
    local g = type(rec) == "table" and rec.kind == "guard_action" and rec.answer_verdict == "grant" and rec.grant
    if type(g) == "table" and rec.answer_event_id == event_id and g.id == grant_id and g.class == class
        and g.scope == scope and g.holder == holder and type(rec.answered_by) == "string" and rec.answered_by ~= "" then return true end
  end
  return false
end

-- The room an approval request or notice would use: the configured approval
-- room, else the owner home room. nil when the relay is not attached or neither
-- is known, so callers can fail closed instead of guessing.
function approval.target_room()
  if not attached then return nil end
  if type(attached.approval_room) == 'function' then
    local ok, value = pcall(attached.approval_room)
    if ok and type(value) == 'string' and value ~= '' then return value end
  end
  return attached.home_room
end

-- A plain notice in the owner's room (no request, no mention); nil and why when the relay is not running.
function approval.notify(text, done, opts)
  if not attached or type(attached.post) ~= "function" then return nil, "Matrix relay is not running" end
  return attached.post(text, nil, type(done) == "function" and done or function() end, type(opts) == "table" and opts or {})
end

-- Named per-second hooks run by sweep(); a name is replaced, never added, so a live reload leaves one.
local ticks = approval._ticks or {}
approval._ticks = ticks
function approval.tick(name, fn) ticks[name] = fn end

local function apply_approved(rec)
  if type(rec) ~= "table" or rec.status ~= "approved" or applying[rec.id] then return false end
  local callback = handlers[rec.kind] and handlers[rec.kind].approve
  if not callback then
    rec.status, rec.error = "failed", "No approval handler is registered"
    persist()
    return nil, rec.error
  end
  applying[rec.id] = true
  local completed = false
  local function done(ok, err)
    if completed then return end
    completed = true
    applying[rec.id] = nil
    -- A pending async handler may have been cancelled in the meantime.
    if rec.status ~= "approved" then return end
    rec.status = ok == "retry" and "approved" or ok == "queued" and "queued" or ok and "applied" or "failed"
    if err then rec.error = tostring(err)
    elseif ok then rec.error = nil end
    persist()
  end
  local ok, err = pcall(callback, rec, done)
  if not ok then done(false, err) end
  return true
end

function approval.reapply_approved()
  if not attached then return 0 end
  local count = 0
  for _, rec in pairs(attached.state.approvals or {}) do
    if type(rec) == "table" and rec.status == "approved" and rec.kind ~= "approve_text" then
      apply_approved(rec)
      count = count + 1
    end
  end
  return count
end

-- End every open request of a kind now (their expire handler runs): a newer decision replaces the old asks.
function approval.expire_open(kind)
  if not attached then return end
  for _, rec in pairs(attached.state.approvals or {}) do
    if type(rec) == "table" and rec.kind == kind and rec.status == "open" then rec.expires_at = 0 end
  end
  approval.sweep()
end

function approval.request(request, done)
  done = type(done) == "function" and done or function() end
  local completed = false
  local function finish(id, why)
    if completed then return end
    completed = true
    done(id, why)
  end
  if not attached then
    finish(nil, "Matrix relay is not running. Next: remuda butler matrix status")
    return nil
  end
  if type(request) ~= "table" or type(request.kind) ~= "string"
    or type(request.key) ~= "string" or type(request.asker) ~= "string"
    or type(request.summary) ~= "string" then
    finish(nil, "Invalid approval request. Next: check the approval request details")
    return nil
  end
  if type(attached.post) ~= "function" then
    finish(nil, "Matrix relay is not running. Next: remuda butler matrix status")
    return nil
  end
  local summary, asker = safe_line(request.summary, 128), safe_line(request.asker, 128)
  approval.sweep()
  for _, rec in pairs(attached.state.approvals or {}) do
    if type(rec) == "table" and rec.status == "open" and rec.asker == asker
      and rec.kind == request.kind and rec.key == request.key then
      finish(rec.id)
      return nil
    end
  end
  local token = request_key(asker, request.kind, request.key)
  local pending = pending_requests[token]
  if pending then
    pending.callbacks[#pending.callbacks + 1] = finish
    return nil
  end
  -- Caps count requests of the same kind, so one kind cannot starve another.
  local open_total, open_for_asker = 0, 0
  local registered_in_window = 0
  local now = math.floor(os.time() * 1000)
  local rate_limit = tonumber(request.rate_limit_per_window)
  local rate_window_ms = math.max(1, tonumber(request.rate_window_s) or 600) * 1000
  for _, rec in pairs(attached.state.approvals or {}) do
    if type(rec) == "table" and rec.status == "open" and rec.kind == request.kind then
      open_total = open_total + 1
      if rec.asker == asker then open_for_asker = open_for_asker + 1 end
    end
    if rate_limit and type(rec) == "table" and rec.kind == request.kind and rec.asker == asker
        and tonumber(rec.created_ms) and tonumber(rec.created_ms) >= now - rate_window_ms then
      registered_in_window = registered_in_window + 1
    end
  end
  for _, item in pairs(pending_requests) do
    if item.kind == request.kind then
      open_total = open_total + 1
      if item.asker == asker then open_for_asker = open_for_asker + 1 end
    end
    if rate_limit and item.kind == request.kind and item.asker == asker
        and tonumber(item.created_ms) and item.created_ms >= now - rate_window_ms then
      registered_in_window = registered_in_window + 1
    end
  end
  if rate_limit and registered_in_window >= rate_limit then
    finish(nil, "Too many prepared text registrations. Next: wait 10 minutes, then retry.")
    return nil
  end
  local max_for_asker = tonumber(request.max_open_for_asker) or 3
  local max_total = tonumber(request.max_open_total) or 5
  if open_for_asker >= max_for_asker or open_total >= max_total then
    finish(nil, "Too many open approval requests (" .. tostring(max_for_asker)
      .. " per agent, " .. tostring(max_total) .. " total). Next: wait for an answer or expiry, then retry.")
    return nil
  end
  local id = random_id(attached.state)
  local nonce = random_bytes(16)
  if not id or not nonce then
    finish(nil, "Secure randomness is unavailable. Next: contact the owner")
    return nil
  end
  local created_ms = math.floor(os.time() * 1000)
  local room_id
  if type(attached.approval_room) == "function" then
    local ok, value = pcall(attached.approval_room)
    if ok and type(value) == "string" and value ~= "" then room_id = value end
  end
  local rec = { id = id, kind = request.kind, key = request.key, asker = asker,
    summary = summary, data = request.data, nonce = hex(nonce), created_ms = created_ms,
    expires_at = created_ms + math.max(1, tonumber(request.ttl_s) or 600) * 1000,
    event_id = nil, room_id = room_id, status = "open" }
  local ttl_minutes = math.max(1, math.ceil((tonumber(request.ttl_s) or 600) / 60))
  local lounge = type(room_id) == "string" and type(attached.home_room) == "string"
    and room_id ~= attached.home_room
  local html, render_metadata
  local text = table.concat({ "Butler wants to " .. summary,
    "Asked by: " .. asker,
    "React ✅ or reply yes to THIS message within " .. tostring(ttl_minutes)
      .. " minutes. ❌ or no denies.",
    "Request " .. id,
    "or: remuda butler approve " .. id }, "\n")
  if type(request.on_id) == "function" then pcall(request.on_id, id) end
  if type(request.render) == "function" then
    local rendered, value, value_html, metadata = pcall(request.render, rec,
      { lounge = lounge, summary = summary })
    if not rendered or type(value) ~= "string" then
      finish(nil, "Could not prepare approval message: " .. tostring(value))
      return nil
    end
    text, html = value, type(value_html) == "string" and value_html or nil
    render_metadata = type(metadata) == "table" and metadata or nil
  end
  if lounge and render_metadata and render_metadata.display_cut == true then
    room_id, rec.room_id, lounge = attached.home_room, attached.home_room, false
    if type(request.render) == "function" then
      local rendered, full_text, full_html = pcall(request.render, rec,
        { lounge = false, summary = summary })
      if not rendered or type(full_text) ~= "string" then
        finish(nil, "Could not prepare full approval request: " .. tostring(full_text))
        return nil
      end
      text, html = full_text, type(full_html) == "string" and full_html or nil
    end
  end
  pending = { id = id, asker = asker, kind = request.kind, created_ms = created_ms,
    callbacks = { finish } }
  pending_requests[token] = pending
  local function complete(request_id, why)
    if pending_requests[token] ~= pending then return end
    pending_requests[token] = nil
    for _, callback in ipairs(pending.callbacks) do pcall(callback, request_id, why) end
  end
  local ok, handle = pcall(attached.post, text, nil, function(result)
    if type(result) ~= "table" or result.error then
      return complete(nil, "Could not post approval request: "
        .. tostring(type(result) == "table" and result.error or "Matrix post returned no result"))
    end
    local event_id = result.event_id
    if type(event_id) ~= "string" or event_id == "" then
      return complete(nil, "Could not post approval request: response omitted event_id")
    end
    rec.event_id = event_id
    if type(result.room_id) == "string" and result.room_id ~= "" then rec.room_id = result.room_id end
    attached.state.approvals[id] = rec
    local saved, save_error = pcall(persist)
    if not saved then
      attached.state.approvals[id] = nil
      return complete(nil, "Could not save approval request: " .. tostring(save_error))
    end
    complete(id)
  end, { mention = true, html = html, room = room_id })
  if not ok then complete(nil, "Could not post approval request: " .. tostring(handle)) end
  return handle
end

function approval.answer(id_or_event, verdict, who, event_id)
  if not attached then return nil, "Matrix relay is not running. Next: remuda butler matrix status" end
  if verdict ~= "approve" and verdict ~= "deny" and verdict ~= "grant" then return nil, "Invalid approval answer." end
  approval.sweep()
  local rec
  for id, candidate in pairs(attached.state.approvals or {}) do
    if type(candidate) == "table" and (tostring(id):upper() == tostring(id_or_event):upper()
      or candidate.event_id == id_or_event) then rec = candidate; break end
  end
  if not rec then return nil, "No such request." end
  if verdict == "grant" then
    -- Only a guard request can end in a standing grant, and only the owner in Matrix: the terminal never grants.
    local check = rec.kind == "guard_action" and handlers.guard_action and handlers.guard_action.grant_check
    local why = not check and "No standing grant is offered for this request."
      or who == "operator (terminal)" and "A guarded tool call can only be approved by the owner in its live Matrix thread."
      or rec.status == "open" and check(rec)
    if why then
      if rec.status == "open" then approval.reply(rec, why) end
      return nil, why
    end
  end
  if rec.kind == "approve_text" and who == "operator (terminal)" and verdict == "approve" then
    return nil, "Prepared text can only be approved by the owner in its live Matrix thread."
  end
  if rec.kind == "guard_action" and who == "operator (terminal)" and verdict == "approve" then
    return nil, "A guarded tool call can only be approved by the owner in its live Matrix thread."
  end
  if rec.kind == "guard_unfreeze" and who == "operator (terminal)" and verdict == "approve" then
    return nil, "Lifting the freeze can only be approved by the owner in its live Matrix thread."
  end
  if rec.kind == "dialog_action" and who == "operator (terminal)" and verdict == "approve" then
    return nil, "Dialog input can only be approved by the owner in its live Matrix thread."
  end
  if rec.kind == "approve_text" and rec.status == "approved" and verdict == "approve" then
    if rec.delivery_started == true then return nil, "Already answered.", rec end
    rec.answered_by, rec.answer_event_id = who, event_id
    apply_approved(rec)
    return true, nil, rec
  end
  if rec.kind == "approve_text" and rec.status == "approved" and verdict == "deny"
      and rec.delivery_started ~= true then
    rec.status, rec.answered_by, rec.answered_at, rec.answer_event_id = "denied", who,
      math.floor(os.time() * 1000), event_id
    persist()
    local callback = handlers[rec.kind] and handlers[rec.kind].deny
    if callback then callback(rec) end
    return true, nil, rec
  end
  if rec.status ~= "open" then
    return nil, rec.status == "expired" and "Expired." or "Already answered.", rec
  end
  local before_answer = handlers[rec.kind] and handlers[rec.kind].before_answer
  if before_answer then
    local ok, ready, why = pcall(before_answer, rec, verdict, who, event_id)
    if not ok or ready ~= true then
      local failure = tostring(ok and why or ready)
      return nil, "Approval answer refused: " .. failure
        .. ". Next: check audit storage, then retry the answer.", rec
    end
  end
  local now = math.floor(os.time() * 1000)
  rec.status, rec.answered_by, rec.answered_at, rec.answer_event_id =
    verdict == "deny" and "denied" or "approved", who, now, event_id
  rec.answer_verdict = verdict
  persist()
  if verdict ~= "deny" then
    apply_approved(rec)
  else
    local callback = handlers[rec.kind] and handlers[rec.kind].deny
    if callback then callback(rec) end
  end
  return true, nil, rec
end

-- Queue acceptance is authoritative before an approved waiting record's TTL.
local before_sweep = approval._before_sweep or {}
approval._before_sweep = before_sweep
function approval.before_sweep(name, fn) before_sweep[name] = fn end
function approval.persist_queue_state(rec, status, queue_id)
  local allowed = {queued=true,applied=true,delivery_uncertain=true,delivery_quarantined=true,failed=true,denied=true}
  if not attached or type(rec) ~= 'table' or rec.kind ~= 'approve_text' or not allowed[status]
      or type(queue_id) ~= 'string' then return false end
  rec.status, rec.queue_id = status, queue_id
  local ok, result = pcall(persist)
  return ok and result ~= false
end
function approval.sweep(now)
  if not attached then return 0 end
  now = tonumber(now) or math.floor(os.time() * 1000)
  local prepared_safe = true
  for _, fn in pairs(before_sweep) do
    local ok, ready = pcall(fn, attached.state.approvals)
    if not ok or ready ~= true then prepared_safe = false end
  end
  local count = 0
  for _, rec in pairs(attached.state.approvals or {}) do
    local expirable = type(rec) == "table" and (rec.status == "open"
      or (rec.status == "approved" and rec.kind == "approve_text" and prepared_safe))
    if expirable and tonumber(rec.expires_at) and now >= rec.expires_at then
      rec.status, rec.answered_at = "expired", now
      local callback = handlers[rec.kind] and handlers[rec.kind].expire
      if callback then callback(rec) end
      count = count + 1
    end
  end
  if count > 0 then persist() end
  for _, fn in pairs(ticks) do pcall(fn, now) end
  return count
end

local function fail(message)
  if type(remuda.fail) == "function" then
    local result = remuda.fail(message, 1)
    if result ~= nil then return result end
  end
  return message
end

local APPROVAL_CLI_SPEC = {
  name = "remuda butler",
  verbs = {
    approvals = { about = "List open and in-flight approval requests. Example: remuda butler approvals --json",
      options = { { long = "json", help = "Metadata-only machine-readable status" } },
      next = "remuda butler approve --help" },
    approve = { about = "Approve a request. Example: remuda butler approve A7K2", args = { { name = "ID", help = "Approval request ID" } },
      next = "remuda butler approvals" },
    deny = { about = "Deny a request. Example: remuda butler deny A7K2", args = { { name = "ID", help = "Approval request ID" } },
      next = "remuda butler approvals" },
  },
}
local cli_parse = assert(remuda.cli and remuda.cli.parse,
  "Butler CLI requires remuda.cli.parse (Remuda core #465 or later); upgrade Remuda")

function approval.cli(args, agent)
  local parse_ok, report = pcall(cli_parse, APPROVAL_CLI_SPEC, args or {})
  if not parse_ok then
    return fail("Usage: remuda butler approvals | approve ID | deny ID\nNext: remuda butler approvals")
  end
  if report.kind == "help" then return report.text end
  if not report.ok then
    local text = report.text ~= "" and report.text or "Usage: remuda butler approvals | approve ID | deny ID"
    if not text:find("\nNext:", 1, true) then text = text .. "\nNext: remuda butler approvals" end
    return fail(text)
  end
  local verb = report.verb
  if verb == "approvals" then
    if report.values.json == true then
      local json = remuda.json
      if type(json) ~= "table" or type(json.encode) ~= "function"
          or type(json.array) ~= "function" then
        return fail("JSON is unavailable on this Remuda core; use remuda butler approvals.")
      end
      local snapshot, unavailable = approval.snapshot()
      if not snapshot then
        return fail("Approval store unavailable (" .. tostring(unavailable)
          .. "); this is not an empty list.\nNext: remuda butler matrix status")
      end
      -- Empty arrays need the core's explicit JSON array marker.
      snapshot.records = json.array(snapshot.records)
      local ok, encoded = pcall(json.encode, snapshot)
      if not ok or type(encoded) ~= "string" then
        return fail("Could not encode the approval list as JSON.")
      end
      return encoded
    end
    local rows, unavailable = approval.list()
    if not rows then
      return fail("Approval store unavailable (" .. tostring(unavailable)
        .. "); this is not an empty list.\nNext: remuda butler matrix status")
    end
    if #rows == 0 then return "No open approval requests.\nNext: nothing to do; agent requests appear here." end
    local now = math.floor(os.time() * 1000)
    local lines = { "ID  KIND  SUMMARY  ASKER  STATUS  EXPIRES-IN" }
    local has_prepared_text = false
    for _, rec in ipairs(rows) do
      local minutes = math.max(0, math.ceil(((tonumber(rec.expires_at) or now) - now) / 60000))
      lines[#lines + 1] = string.format("%s  %s  %s  %s  %s  %s",
        safe_line(rec.id, 26), safe_line(rec.kind, 32), safe_line(rec.summary, 128),
        safe_line(rec.asker, 128), approval.status_label(rec), tostring(minutes) .. "m")
      if rec.kind == "approve_text" or rec.kind == "guard_action" then has_prepared_text = true end
    end
    lines[#lines + 1] = agent and "Next: wait for mail; remuda butler inbox"
      or has_prepared_text and "Next: remuda butler deny ID cancels prepared text or a guarded call; owner Matrix approval is required"
      or "Next: remuda butler approve ID, or remuda butler deny ID"
    return table.concat(lines, "\n")
  end
  if verb == "approve" or verb == "deny" then
    local id = report.values.ID
    if type(id) ~= "string" or id == "" then
      return fail("Usage: remuda butler " .. verb .. " ID\nNext: remuda butler approvals")
    end
    if agent then
      return fail(verb .. " is operator-only. Next: wait for the owner's answer by mail; remuda butler inbox")
    end
    if id == nil or id == "" then return fail(usage(verb) .. "\nNext: remuda butler approvals") end
    local ok, err, rec = approval.answer(id, verb, "operator (terminal)")
    if not ok then
      if rec then
        return fail("Request " .. tostring(rec.id) .. " was already " .. tostring(rec.status) .. ".\nNext: remuda butler approvals")
      end
      return fail(tostring(err) .. "\nNext: remuda butler approvals")
    end
    if verb == "approve" then
      return "Approved request " .. tostring(rec.id) .. " (" .. tostring(rec.summary) .. "); joining now. The result goes to the request thread and the asker's mail."
        .. "\nNext: remuda butler approvals"
    end
    return "Denied request " .. tostring(rec.id) .. " (" .. tostring(rec.summary) .. ")."
      .. "\nNext: remuda butler approvals"
  end
  return fail("Unknown approval command. Next: remuda butler approvals")
end

return approval
