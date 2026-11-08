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
  -- The object id becomes a file name too; never read outside objects/.
  if body.object_id:find("[/\\]") or body.object_id:find("..", 1, true) then
    return nil, { code = "corrupt", field = "object_id" }
  end
  local content, content_why = read_file(self.root .. "/objects/" .. body.object_id)
  if not content then return nil, { code = content_why or "unavailable" } end
  return { message_id = message_id, envelope = envelope, content = content,
    envelope_ref = "messages/" .. message_id .. ".json",
    object_ref = "objects/" .. body.object_id }
end

-- Process-local owner registry. It lives on the daemon global so a module
-- reload cannot admit a second owner; tokens are keyed by Store in a weak map
-- so callers cannot forge ownership by setting a field.
local OWNER_STATE
if type(remuda) == "table" then
  if type(remuda._butler_inbox_owner_state) ~= "table" then
    remuda._butler_inbox_owner_state = {
      owners = {}, tokens = setmetatable({}, { __mode = "k" }), serial = 0 }
  end
  OWNER_STATE = remuda._butler_inbox_owner_state
else
  OWNER_STATE = { owners = {}, tokens = setmetatable({}, { __mode = "k" }), serial = 0 }
end

local function resolve_root(config, root)
  local resolver = config.realpath
  if type(resolver) ~= "function" and type(remuda) == "table"
    and remuda.fs and type(remuda.fs.realpath) == "function" then
    resolver = function(path) return remuda.fs.realpath(path) end
  end
  if type(resolver) == "function" then
    local ok, actual = pcall(resolver, root)
    if ok and nonempty(actual) then return actual end
  end
  return root
end

local function owner_token(store)
  local token = OWNER_STATE.tokens[store]
  if not token or token.released then return nil end
  if OWNER_STATE.owners[token.root] ~= token then return nil end
  return token
end

local function owner_error(store)
  if store.closed then return fail("writer_conflict", "closed") end
  if not owner_token(store) then return fail("writer_conflict", "owner") end
  return nil
end

local function release_owner(store)
  if store.closed then return true end
  local token = OWNER_STATE.tokens[store]
  if token then
    if OWNER_STATE.owners[token.root] == token then
      OWNER_STATE.owners[token.root] = nil
    end
    token.released = true
    OWNER_STATE.tokens[store] = nil
  end
  if type(store.release_capability) == "function" then
    pcall(store.release_capability)
  end
  store.closed = true
  return true
end

local function read_marker(config, root, actual)
  local marker = { format_version = 1, state = "FILE", root = actual, epoch = 0 }
  if config.marker and type(config.marker.read) == "function" then
    local ok, value, why = pcall(config.marker.read, root)
    if not ok then return fail("recovery_required", "marker") end
    if value == nil then
      local code = type(why) == "table" and why.code or nil
      local text = type(why) == "string" and why or ""
      if code == "not_found" or text:find("No such file", 1, true) then
        value = marker
      else
        return fail("recovery_required", "marker")
      end
    end
    if type(value) ~= "table" then return fail("recovery_required", "marker") end
    marker = value
  end
  if not is_integer(marker.format_version) or marker.format_version < 1 then
    return fail("recovery_required", "format_version")
  end
  if marker.format_version > 1 then return fail("schema_too_new", "format_version") end
  if marker.root ~= actual then return fail("recovery_required", "root") end
  if not is_integer(marker.epoch) or marker.epoch < 0 then
    return fail("recovery_required", "epoch")
  end
  local state = marker.state
  if state == "FILE" then
    if marker.epoch ~= 0 then return fail("recovery_required", "epoch") end
  elseif state == "FILE_TRACKED" then
    if marker.protocol ~= "tracked-file-v1" or not nonempty(marker.generation)
      or marker.tracking_epoch ~= marker.epoch then
      return fail("recovery_required", "tracked")
    end
  elseif state == "CUTOVER_PREPARED" or state == "SQL_ACTIVE" then
    if marker.protocol ~= "sql-inbox-v1" or not nonempty(marker.generation)
      or not nonempty(marker.operation_id)
      or type(marker.proof_hash) ~= "string" or #marker.proof_hash ~= 64
      or not is_integer(marker.tail_watermark) or marker.tail_watermark < 0 then
      return fail("recovery_required", "sql")
    end
  elseif state == "RECOVERY_REQUIRED" then
    return fail("recovery_required", "marker")
  else
    return fail("recovery_required", "state")
  end
  return marker
end

local function db_handle(config)
  if config.db ~= nil then return config.db, nil end
  if config.sql and type(config.sql.open) == "function" then
    local ok, handle, why = pcall(config.sql.open, config.root)
    if ok and handle ~= nil then return handle, nil end
    return nil, why or "unavailable"
  end
  return nil, "unavailable"
end

local function db_alive(db)
  if db == nil then return false end
  local ok, rows = pcall(db.query, db, "SELECT 1 AS ok", {})
  return ok and rows ~= nil
end

local function db_query(db, sql, params)
  if db == nil then return nil end
  local ok, rows = pcall(db.query, db, sql, params or {})
  if not ok then return nil end
  return rows
end

local function close_refusal(store)
  return nil, { code = "writer_conflict", field = "closed" }
end

function Store:close()
  if self.closed then return true end
  return release_owner(self)
end

function Store:status()
  local marker = self.marker or { state = "FILE", epoch = 0 }
  local migration = { state = "file", cursor = nil, complete = false }
  if marker.state == "FILE_TRACKED" then
    migration = { state = "tracked", cursor = nil, complete = false }
  elseif marker.state == "CUTOVER_PREPARED" then
    migration = { state = "sql_required", cursor = nil, complete = false }
  elseif marker.state == "SQL_ACTIVE" then
    migration = { state = "sql", cursor = nil, complete = true }
  end
  return { authority = self.authority or "file", epoch = self.epoch or 0,
    schema = self.schema, root = self.actual_root or self.root,
    writer = self.writer_state or { owner = false, guarded = false },
    migration = migration, closed = self.closed == true, error = self.open_error }
end

function Store:page()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("page")
end
function Store:deliver()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("deliver")
end
function Store:mark_read()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("mark_read")
end
function Store:accept_external()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("accept_external")
end
function Store:advance()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("advance")
end
function Store:transition()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("transition")
end
function Store:reconcile()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("reconcile")
end

function M.open(config)
  if type(config) ~= "table" then return fail("invalid_snapshot", "config") end
  if config.root ~= nil and not nonempty(config.root) then
    return fail("invalid_snapshot", "root")
  end
  if type(config.root) ~= "string" then return fail("invalid_snapshot", "root") end
  local actual = resolve_root(config, config.root)
  -- Marker inspection precedes every backend and the owner registry.
  local marker, marker_err = read_marker(config, config.root, actual)
  if not marker then return nil, marker_err end
  if OWNER_STATE.owners[actual] then return fail("writer_conflict", "owner") end
  OWNER_STATE.serial = (OWNER_STATE.serial or 0) + 1
  local token = { root = actual, serial = OWNER_STATE.serial }
  OWNER_STATE.owners[actual] = token
  local store = setmetatable({ root = config.root, actual_root = actual,
    marker = marker, source = config.source, content = config.content,
    decode = decoder(config) }, Store)
  OWNER_STATE.tokens[store] = token
  if config.writer and type(config.writer.claim) == "function" then
    local ok, capability, why = pcall(config.writer.claim, config.root)
    if not ok or type(capability) ~= "table" then
      release_owner(store)
      local code = (type(capability) == "table" and capability.code)
        or (type(why) == "table" and why.code) or "writer_conflict"
      return fail(code, "writer")
    end
    if capability.root ~= nil and resolve_root(config, capability.root) ~= actual then
      release_owner(store)
      return fail("writer_conflict", "root")
    end
    if capability.owner ~= true then release_owner(store); return fail("writer_conflict", "owner") end
    if capability.guarded ~= true then release_owner(store); return fail("writer_conflict", "guarded") end
    store.writer_state = { owner = true, guarded = true }
    store.release_capability = capability.release
  end
  if marker.state ~= "FILE" then
    local db, db_why = db_handle(config)
    if db == nil then
      release_owner(store)
      return fail(marker.state == "FILE_TRACKED" and "unavailable" or "sql_required", "db", db_why)
    end
    store.db = db
    local alive = db_alive(db)
    if not alive then
      release_owner(store)
      return fail(marker.state == "FILE_TRACKED" and "unavailable" or "sql_required", "db")
    end
    if marker.state == "SQL_ACTIVE" then
      local rows = db_query(db,
        "SELECT root, epoch, generation, operation_id, proof_hash FROM auth_authority WHERE id = 1")
      local row = rows and rows[1]
      if not row or row.root ~= actual or tonumber(row.epoch) ~= marker.epoch
        or row.generation ~= marker.generation
        or row.operation_id ~= marker.operation_id
        or row.proof_hash ~= marker.proof_hash then
        release_owner(store)
        return fail("recovery_required", "authority")
      end
    end
  end
  store.authority = (marker.state == "SQL_ACTIVE" and "sql")
    or (marker.state == "CUTOVER_PREPARED" and "sql_required") or "file"
  store.epoch = marker.epoch
  return store
end

M.Store = Store

if type(remuda) == "table" then remuda._butler_inbox_authority = M end
return M
