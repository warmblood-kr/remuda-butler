-- Durable, relay-backed approval requests. Policy callbacks are registered
-- by the feature that owns each request kind; only request data is persisted.
local butler = assert(remuda.butler, "load butler/matrix before butler/approval")
local approval = butler.approval or {}
butler.approval = approval

local handlers = approval._handlers or {}
approval._handlers = handlers
local attached

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
  return open_records(attached.state)
end

function approval.request(request)
  if not attached then return nil, "Matrix relay is not running. Next: remuda butler matrix status" end
  if type(request) ~= "table" or type(request.kind) ~= "string"
    or type(request.asker) ~= "string" or type(request.summary) ~= "string" then
    return nil, "Invalid approval request. Next: check the approval request details"
  end
  if type(attached.post) ~= "function" then
    return nil, "Matrix relay is not running. Next: remuda butler matrix status"
  end
  local id = random_id(attached.state)
  local nonce = random_bytes(16)
  if not id or not nonce then return nil, "Secure randomness is unavailable. Next: contact the owner" end
  local created_ms = math.floor(os.time() * 1000)
  local rec = { id = id, kind = request.kind, key = request.key, asker = request.asker,
    summary = request.summary, data = request.data, nonce = hex(nonce), created_ms = created_ms,
    expires_at = created_ms + math.max(1, tonumber(request.ttl_s) or 600) * 1000,
    event_id = nil, status = "open" }
  local posted, post_error
  attached.post(request.summary .. "\nRequest " .. id, nil, function(result)
    if type(result) == "table" and result.error then post_error = tostring(result.error)
    else posted = type(result) == "table" and result.event_id or nil end
    if posted and posted ~= "" then
      rec.event_id = posted
      attached.state.approvals[id] = rec
      persist()
    end
  end)
  if post_error then return nil, "Could not post to HOME: " .. post_error end
  -- Matrix requests complete asynchronously; the id is useful immediately.
  -- The relay callback records the request only once the event id is known.
  return id
end

function approval.answer(id_or_event, verdict, who)
  if not attached then return nil, "Matrix relay is not running. Next: remuda butler matrix status" end
  if verdict ~= "approve" and verdict ~= "deny" then return nil, "Invalid approval answer." end
  local rec
  for id, candidate in pairs(attached.state.approvals or {}) do
    if type(candidate) == "table" and (tostring(id):upper() == tostring(id_or_event):upper()
      or candidate.event_id == id_or_event) then rec = candidate; break end
  end
  if not rec then return nil, "No such request." end
  if rec.status ~= "open" then return nil, "Already answered." end
  local now = math.floor(os.time() * 1000)
  if tonumber(rec.expires_at) and now >= rec.expires_at then
    rec.status, rec.answered_at = "expired", now
    persist()
    local callback = handlers[rec.kind] and handlers[rec.kind].expire
    if callback then callback(rec) end
    return nil, "Expired."
  end
  rec.status, rec.answered_by, rec.answered_at = verdict == "approve" and "approved" or "denied", who,
    now
  persist()
  local callback = handlers[rec.kind] and handlers[rec.kind][verdict]
  if callback then
    if verdict == "approve" then
      callback(rec, function(ok, err)
        rec.status = ok and "applied" or "failed"
        if err then rec.error = tostring(err) end
        persist()
      end)
    else
      callback(rec)
    end
  end
  return true
end

function approval.sweep(now)
  if not attached then return 0 end
  now = tonumber(now) or math.floor(os.time() * 1000)
  local count = 0
  for _, rec in ipairs(open_records(attached.state)) do
    if tonumber(rec.expires_at) and now >= rec.expires_at then
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
  if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
  return message
end

local function usage(verb)
  if verb == "approvals" then return "Usage: remuda butler approvals\nExample: remuda butler approvals" end
  return "Usage: remuda butler " .. verb .. " ID\nExample: remuda butler " .. verb .. " A7K2"
end

function approval.cli(args, agent)
  local verb = args and args[1]
  if verb == "approvals" then
    if #args ~= 1 then return fail(usage(verb) .. "\nNext: remuda butler approvals") end
    local rows = approval.list()
    if #rows == 0 then return "No open approval requests.\nNext: ask an agent to request approval" end
    local now = math.floor(os.time() * 1000)
    local lines = { "ID  KIND  SUMMARY  ASKER  EXPIRES-IN" }
    for _, rec in ipairs(rows) do
      local seconds = math.max(0, math.ceil(((tonumber(rec.expires_at) or now) - now) / 1000))
      lines[#lines + 1] = string.format("%s  %s  %s  %s  %ss", tostring(rec.id), tostring(rec.kind),
        tostring(rec.summary), tostring(rec.asker), tostring(seconds))
    end
    lines[#lines + 1] = "Next: remuda butler approve ID | deny ID"
    return table.concat(lines, "\n")
  end
  if verb == "approve" or verb == "deny" then
    if #args ~= 2 or type(args[2]) ~= "string" or args[2] == "" then
      return fail(usage(verb) .. "\nNext: remuda butler approvals")
    end
    if agent then
      return fail(verb .. " is operator-only. Next: ask the owner in the HOME room")
    end
    local ok, err = approval.answer(args[2], verb, "operator (terminal)")
    if not ok then return fail(tostring(err) .. " Next: remuda butler approvals") end
    return (verb == "approve" and "Approval recorded." or "Request denied.")
      .. "\nNext: remuda butler approvals"
  end
  return fail("Unknown approval command. Next: remuda butler approvals")
end

return approval
