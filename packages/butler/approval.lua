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

local function hex(bytes)
  local out = {}
  for i = 1, #bytes do out[i] = string.format("%02x", bytes:byte(i)) end
  return table.concat(out)
end

local function open_records(state)
  local rows = {}
  for _, record in pairs(state and state.approvals or {}) do
    if type(record) == "table" and record.status == "open" then rows[#rows + 1] = record end
  end
  table.sort(rows, function(a, b)
    if tonumber(a.created_ms) and tonumber(b.created_ms) then return a.created_ms < b.created_ms end
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

function approval.attach(state, persist_fn, post_fn)
  assert(type(state) == "table", "approval state is required")
  if type(state.approvals) ~= "table" or state.approvals == remuda.json.null then
    state.approvals = remuda.json and remuda.json.object({}) or {}
  end
  attached = { state = state, persist = persist_fn, post = post_fn }
  return true
end

function approval.list()
  if not attached then return {} end
  approval.sweep()
  return open_records(attached.state)
end

function approval.for_event(event_id)
  if not attached or type(event_id) ~= "string" then return nil end
  for _, rec in pairs(attached.state.approvals or {}) do
    if type(rec) == "table" and rec.event_id == event_id then return rec end
  end
end

function approval.reply(rec, text)
  if not attached or type(attached.post) ~= "function" then
    return nil, "Matrix relay is not running. Next: remuda butler matrix status"
  end
  if type(rec) ~= "table" or type(rec.event_id) ~= "string" or rec.event_id == "" then
    return nil, "Approval request event is unavailable"
  end
  return attached.post(text, { rel_type = "m.thread", event_id = rec.event_id }, function() end)
end

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
    rec.status = ok == "retry" and "approved" or ok and "applied" or "failed"
    if err then rec.error = tostring(err) end
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
  local open_total, open_for_asker = 0, 0
  local registered_in_window = 0
  local now = math.floor(os.time() * 1000)
  local rate_limit = tonumber(request.rate_limit_per_window)
  local rate_window_ms = math.max(1, tonumber(request.rate_window_s) or 600) * 1000
  for _, rec in pairs(attached.state.approvals or {}) do
    if type(rec) == "table" and rec.status == "open" then
      open_total = open_total + 1
      if rec.asker == asker then open_for_asker = open_for_asker + 1 end
    end
    if rate_limit and type(rec) == "table" and rec.kind == request.kind and rec.asker == asker
        and tonumber(rec.created_ms) and tonumber(rec.created_ms) >= now - rate_window_ms then
      registered_in_window = registered_in_window + 1
    end
  end
  for _, item in pairs(pending_requests) do
    open_total = open_total + 1
    if item.asker == asker then open_for_asker = open_for_asker + 1 end
    if rate_limit and item.kind == request.kind and item.asker == asker
        and tonumber(item.created_ms) and item.created_ms >= now - rate_window_ms then
      registered_in_window = registered_in_window + 1
    end
  end
  if rate_limit and registered_in_window >= rate_limit then
    finish(nil, "Too many prepared text registrations. Next: wait 10 minutes, then retry.")
    return nil
  end
  if open_for_asker >= (tonumber(request.max_open_for_asker) or 3) or open_total >= 5 then
    finish(nil, "Too many open approval requests (3 per agent, 5 total). Next: wait for an answer or expiry (10 min), then retry.")
    return nil
  end
  local id = random_id(attached.state)
  local nonce = random_bytes(16)
  if not id or not nonce then
    finish(nil, "Secure randomness is unavailable. Next: contact the owner")
    return nil
  end
  local created_ms = math.floor(os.time() * 1000)
  local rec = { id = id, kind = request.kind, key = request.key, asker = asker,
    summary = summary, data = request.data, nonce = hex(nonce), created_ms = created_ms,
    expires_at = created_ms + math.max(1, tonumber(request.ttl_s) or 600) * 1000,
    event_id = nil, status = "open" }
  local ttl_minutes = math.max(1, math.ceil((tonumber(request.ttl_s) or 600) / 60))
  local text = table.concat({ "Butler wants to " .. summary,
    "Asked by: " .. asker,
    "React ✅ or reply yes to THIS message within " .. tostring(ttl_minutes)
      .. " minutes. ❌ or no denies.",
    "Request " .. id,
    "or: remuda butler approve " .. id }, "\n")
  if type(request.on_id) == "function" then pcall(request.on_id, id) end
  if type(request.render) == "function" then
    local rendered, value = pcall(request.render, rec)
    if not rendered or type(value) ~= "string" then
      finish(nil, "Could not prepare approval message: " .. tostring(value))
      return nil
    end
    text = value
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
      return complete(nil, "Could not post to HOME: "
        .. tostring(type(result) == "table" and result.error or "Matrix post returned no result"))
    end
    local event_id = result.event_id
    if type(event_id) ~= "string" or event_id == "" then
      return complete(nil, "Could not post to HOME: response omitted event_id")
    end
    rec.event_id = event_id
    attached.state.approvals[id] = rec
    local saved, save_error = pcall(persist)
    if not saved then
      attached.state.approvals[id] = nil
      return complete(nil, "Could not save approval request: " .. tostring(save_error))
    end
    complete(id)
  end)
  if not ok then complete(nil, "Could not post to HOME: " .. tostring(handle)) end
  return handle
end

function approval.answer(id_or_event, verdict, who, event_id)
  if not attached then return nil, "Matrix relay is not running. Next: remuda butler matrix status" end
  if verdict ~= "approve" and verdict ~= "deny" then return nil, "Invalid approval answer." end
  approval.sweep()
  local rec
  for id, candidate in pairs(attached.state.approvals or {}) do
    if type(candidate) == "table" and (tostring(id):upper() == tostring(id_or_event):upper()
      or candidate.event_id == id_or_event) then rec = candidate; break end
  end
  if not rec then return nil, "No such request." end
  if rec.kind == "approve_text" and who == "operator (terminal)" then
    return nil, "Prepared text can only be approved by the owner in its live Matrix thread."
  end
  if rec.kind == "approve_text" and rec.status == "approved" and verdict == "approve" then
    rec.answered_by, rec.answer_event_id = who, event_id
    apply_approved(rec)
    return true, nil, rec
  end
  if rec.status ~= "open" then
    return nil, rec.status == "expired" and "Expired." or "Already answered.", rec
  end
  local now = math.floor(os.time() * 1000)
  rec.status, rec.answered_by, rec.answered_at, rec.answer_event_id =
    verdict == "approve" and "approved" or "denied", who, now, event_id
  persist()
  if verdict == "approve" then
    apply_approved(rec)
  else
    local callback = handlers[rec.kind] and handlers[rec.kind].deny
    if callback then callback(rec) end
  end
  return true, nil, rec
end

function approval.sweep(now)
  if not attached then return 0 end
  now = tonumber(now) or math.floor(os.time() * 1000)
  local count = 0
  for _, rec in pairs(attached.state.approvals or {}) do
    local expirable = type(rec) == "table" and (rec.status == "open"
      or (rec.status == "approved" and rec.kind == "approve_text"))
    if expirable and tonumber(rec.expires_at) and now >= rec.expires_at then
      rec.status, rec.answered_at = "expired", now
      local callback = handlers[rec.kind] and handlers[rec.kind].expire
      if callback then callback(rec) end
      count = count + 1
    end
  end
  if count > 0 then persist() end
  return count
end

local function fail(message)
  if type(remuda.fail) == "function" then
    local result = remuda.fail(message, 1)
    if result ~= nil then return result end
  end
  return message
end

local function usage(verb)
  if verb == "approvals" then return "Usage: remuda butler approvals\nExample: remuda butler approvals" end
  return "Usage: remuda butler " .. verb .. " ID\nExample: remuda butler " .. verb .. " A7K2"
end

function approval.cli(args, agent)
  local verb = args and args[1]
  if verb == "approvals" then
    if #args == 2 and (args[2] == "--help" or args[2] == "-h") then return usage(verb) end
    if #args ~= 1 then return fail(usage(verb) .. "\nNext: remuda butler approvals") end
    local rows = approval.list()
    if #rows == 0 then return "No open approval requests.\nNext: nothing to do; agent requests appear here." end
    local now = math.floor(os.time() * 1000)
    local lines = { "ID  KIND  SUMMARY  ASKER  EXPIRES-IN" }
    for _, rec in ipairs(rows) do
      local minutes = math.max(0, math.ceil(((tonumber(rec.expires_at) or now) - now) / 60000))
      lines[#lines + 1] = string.format("%s  %s  %s  %s  %s", tostring(rec.id), tostring(rec.kind),
        tostring(rec.summary), tostring(rec.asker), tostring(minutes) .. "m")
    end
    lines[#lines + 1] = agent and "Next: wait for mail; remuda butler inbox"
      or "Next: remuda butler approve ID, or remuda butler deny ID"
    return table.concat(lines, "\n")
  end
  if verb == "approve" or verb == "deny" then
    if #args == 2 and (args[2] == "--help" or args[2] == "-h") then return usage(verb) end
    if #args ~= 2 or type(args[2]) ~= "string" or args[2] == "" then
      return fail(usage(verb) .. "\nNext: remuda butler approvals")
    end
    if agent then
      return fail(verb .. " is operator-only. Next: wait for the owner's answer by mail; remuda butler inbox")
    end
    local ok, err, rec = approval.answer(args[2], verb, "operator (terminal)")
    if not ok then
      if rec then
        return fail("Request " .. tostring(rec.id) .. " was already " .. tostring(rec.status) .. ".\nNext: remuda butler approvals")
      end
      return fail(tostring(err) .. "\nNext: remuda butler approvals")
    end
    if verb == "approve" then
      return "Approved request " .. tostring(rec.id) .. " (" .. tostring(rec.summary) .. "); joining now. The result goes to the HOME thread and the asker's mail."
        .. "\nNext: remuda butler approvals"
    end
    return "Denied request " .. tostring(rec.id) .. " (" .. tostring(rec.summary) .. ")."
      .. "\nNext: remuda butler approvals"
  end
  return fail("Unknown approval command. Next: remuda butler approvals")
end

return approval
