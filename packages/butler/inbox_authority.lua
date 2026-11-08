-- Product implementation of the inbox authority contract v1 (phase 1 slice).
--
-- This slice is deliberately narrow: the pure parity certifier and a
-- file-backed Matrix metadata lookup. It opens no SQLite database and makes no
-- authority decision beyond the file phase. SQL, marker, migration, delivery
-- and read state are later slices; their Store methods answer
-- contract_unimplemented instead of pretending to be safe.
local M = { contract_version = 1 }

local function fail(code, field, id)
  return nil, { code = code, field = field, id = id }
end

local function unimplemented(operation)
  return nil, { code = "contract_unimplemented", operation = operation }
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

local function is_integer(value)
  return type(value) == "number" and value % 1 == 0
end

-- The store addresses a mailbox by its hex file component, never a name.
local function is_hex(value)
  return type(value) == "string" and #value > 0 and #value % 2 == 0
    and value:match("^%x+$") ~= nil
end

-- The id becomes a file name; never one that leaves the messages directory.
local function safe_id(value)
  return nonempty(value) and not value:find("[/\\]") and not value:find("..", 1, true)
end

local function valid_row(row)
  if type(row) ~= "table" then return false, "delivery" end
  if not nonempty(row.message_id) then return false, "delivery" end
  if not is_integer(row.seq) then return false, "delivery" end
  if row.resent ~= nil and type(row.resent) ~= "string" then return false, "resent" end
  if type(row.envelope_ref) ~= "string" then return false, "refs" end
  if type(row.object_ref) ~= "string" then return false, "refs" end
  if type(row.metadata) ~= "string" then return false, "metadata" end
  return true
end

-- A delivery list is a true dense array: keys 1..N only, no holes, no extra
-- (or fractional/zero) keys hiding rows that ipairs would skip.
local function dense_length(rows)
  local count, maximum = 0, 0
  for key in pairs(rows) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return nil end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if count ~= maximum then return nil end
  return count
end

-- Shape validation only; canonical encoding is the adapters' obligation.
local function valid_snapshot(snapshot)
  if type(snapshot) ~= "table" then return false, "snapshot" end
  if type(snapshot.deliveries) ~= "table" then return false, "delivery" end
  if type(snapshot.reads) ~= "table" then return false, "read" end
  local length = dense_length(snapshot.deliveries)
  if not length then return false, "delivery" end
  local seen = {}
  for index = 1, length do
    local row = snapshot.deliveries[index]
    local ok, field = valid_row(row)
    if not ok then return false, field end
    -- Canonical order is dense 1..N; a gap or duplicate rank cannot certify.
    if row.seq ~= index then return false, "delivery" end
    if seen[row.message_id] then return false, "delivery" end
    seen[row.message_id] = true
  end
  for key, value in pairs(snapshot.reads) do
    if not nonempty(key) or value ~= true then return false, "read" end
  end
  return true
end

local function valid_context(context)
  if type(context) ~= "table" then return false end
  if not nonempty(context.root) or not is_hex(context.recipient) then return false end
  if not is_integer(context.epoch) or context.epoch < 0 then return false end
  if not nonempty(context.source_before) or not nonempty(context.source_after) then return false end
  if not nonempty(context.db_snapshot) then return false end
  if type(context.complete) ~= "boolean" then return false end
  if type(context.writer) ~= "table" then return false end
  if type(context.writer.owner) ~= "boolean" or type(context.writer.guarded) ~= "boolean" then
    return false
  end
  if not nonempty(context.writer.root) then return false end
  return true
end

local function parity_failure(field, id)
  return nil, { code = "parity_mismatch", field = field, id = id }
end

-- Pure parity: open no files, infer nothing from counts. Classification
-- precedence is invalid shape, incomplete, writer, generation, then drift.
function M.certify(source, actual, context)
  if not valid_context(context) then return fail("invalid_snapshot", "context") end
  local ok, field = valid_snapshot(source)
  if not ok then return fail("invalid_snapshot", field) end
  ok, field = valid_snapshot(actual)
  if not ok then return fail("invalid_snapshot", field) end
  if context.complete ~= true then return fail("partial") end
  if context.writer.owner ~= true or context.writer.guarded ~= true
    or context.writer.root ~= context.root then
    return fail("writer_conflict")
  end
  if context.source_before ~= context.source_after then return fail("stale_generation") end
  if #source.deliveries ~= #actual.deliveries then return parity_failure("delivery") end
  for index = 1, #source.deliveries do
    local left, right = source.deliveries[index], actual.deliveries[index]
    if left.message_id ~= right.message_id or left.seq ~= right.seq then
      return parity_failure("delivery", left.message_id)
    end
    if left.resent ~= right.resent then return parity_failure("resent", left.message_id) end
    if left.envelope_ref ~= right.envelope_ref or left.object_ref ~= right.object_ref then
      return parity_failure("refs", left.message_id)
    end
    if left.metadata ~= right.metadata then return parity_failure("metadata", left.message_id) end
  end
  local reads = 0
  for key in pairs(source.reads) do
    reads = reads + 1
    if actual.reads[key] ~= true then return parity_failure("read", key) end
  end
  for key in pairs(actual.reads) do
    if source.reads[key] ~= true then return parity_failure("read", key) end
  end
  return { state = "match", root = context.root, recipient = context.recipient,
    epoch = context.epoch, source = context.source_before,
    db_snapshot = context.db_snapshot, deliveries = #source.deliveries, reads = reads }
end

local Store = {}
Store.__index = Store

local function decoder(config)
  local json = config.json or (type(remuda) == "table" and remuda.json or nil)
  if type(json) ~= "table" or type(json.decode) ~= "function" then return nil end
  return json.decode
end

local function decode(store, text)
  if type(text) ~= "string" or not store.decode then return nil end
  local ok, value = pcall(store.decode, text)
  if not ok or type(value) ~= "table" then return nil end
  return value
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    if err and tostring(err):find("No such file", 1, true) then return nil, "missing" end
    return nil, "unreadable"
  end
  local text = file:read("*a")
  local closed, close_err = file:close()
  if not text or not closed then return nil, "unreadable", close_err end
  return text
end

-- The file source adapter owns the delivered set and envelope metadata. A
-- Store without it cannot prove anything and must not guess.
function Store:lookup_matrix(recipient, room, event)
  if not (self.source and type(self.source.lookup_matrix) == "function") then
    return { state = "unknown", reason = "metadata_source_unavailable" }
  end
  local ok, result = pcall(self.source.lookup_matrix, recipient, room, event)
  if not ok or type(result) ~= "table" or not nonempty(result.state) then
    return { state = "unknown", reason = "source_error" }
  end
  return result
end

-- Content only; membership and read state are never inferred here.
function Store:hydrate(message_id)
  if not safe_id(message_id) then
    return nil, { code = "invalid_id" }
  end
  if not self.root then return nil, { code = "unavailable" } end
  local text, why = read_file(self.root .. "/messages/" .. message_id .. ".json")
  if not text then return nil, { code = why or "unavailable" } end
  local envelope = decode(self, text)
  if not envelope then return nil, { code = "corrupt" } end
  local body = envelope.body
  if type(body) ~= "table" or not nonempty(body.object_id) then
    return nil, { code = "corrupt" }
  end
  local content, content_why = read_file(self.root .. "/objects/" .. body.object_id)
  if not content then return nil, { code = content_why or "unavailable" } end
  return { message_id = message_id, envelope = envelope, content = content,
    envelope_ref = "messages/" .. message_id .. ".json",
    object_ref = "objects/" .. body.object_id }
end

function Store:status()
  return { authority = "file", epoch = 0, schema = nil, root = self.root,
    writer = self.writer_state or { owner = false, guarded = false },
    migration = { state = "file", cursor = nil, complete = false }, error = nil }
end

function Store:page() return unimplemented("page") end
function Store:deliver() return unimplemented("deliver") end
function Store:mark_read() return unimplemented("mark_read") end
function Store:advance() return unimplemented("advance") end
function Store:transition() return unimplemented("transition") end
function Store:reconcile() return unimplemented("reconcile") end

function M.open(config)
  if type(config) ~= "table" then return fail("invalid_snapshot", "config") end
  if config.root ~= nil and not nonempty(config.root) then
    return fail("invalid_snapshot", "root")
  end
  -- Marker inspection precedes SQL. Phase 1 has no SQL; a caller that asserts a
  -- non-FILE marker cannot be served by this slice and must not pretend to.
  if config.marker and type(config.marker.read) == "function" then
    local ok, marker = pcall(config.marker.read, config.root)
    if not ok or type(marker) ~= "table" or not marker.state then
      return fail("recovery_required", "marker")
    end
    if marker.state ~= "FILE" then return fail("recovery_required", "marker") end
  end
  local store = setmetatable({ root = config.root, source = config.source,
    content = config.content, decode = decoder(config) }, Store)
  if config.writer and type(config.writer.claim) == "function" then
    local ok, capability, why = pcall(config.writer.claim, config.root)
    if not ok or type(capability) ~= "table" then
      local code = (type(capability) == "table" and capability.code)
        or (type(why) == "table" and why.code) or "writer_conflict"
      return fail(code, "writer")
    end
    if capability.root ~= nil and capability.root ~= store.root then
      return fail("writer_conflict", "root")
    end
    store.writer_state = { owner = capability.owner == true, guarded = capability.guarded == true }
  end
  return store
end

M.Store = Store

if type(remuda) == "table" then remuda._butler_inbox_authority = M end
return M
