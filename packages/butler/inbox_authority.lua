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

-- Forward declarations: the registry lives below the file/read helpers, but
-- lookup_matrix/hydrate above it must still test ownership.
local owner_token, close_refusal, read_refusal
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


local function sql_query(store, sql, params)
  if not store.db then return nil, "unavailable" end
  local ok, rows, err = pcall(store.db.query, store.db, sql, params or {})
  if not ok then return nil, tostring(rows) end
  if rows == nil then return nil, tostring(err or "unavailable") end
  return rows
end

local function sql_exec(store, sql, params)
  if not store.db then return nil, "unavailable" end
  local ok, result, err = pcall(store.db.exec, store.db, sql, params or {})
  if not ok then return nil, tostring(result) end
  if not result then return nil, tostring(err or "unavailable") end
  return true
end

local function canonical_json(store, value)
  if type(store.json) ~= "table" then return nil end
  if type(store.json.canonical) == "function" then
    local ok, text = pcall(store.json.canonical, value)
    if ok and type(text) == "string" then return text end
  end
  if type(store.json.encode) == "function" then
    local ok, text = pcall(store.json.encode, value)
    if ok and type(text) == "string" then return text end
  end
  return nil
end

local function frame(values)
  local out = {}
  for index = 1, #values do out[index] = #values[index] .. ":" .. values[index] end
  return table.concat(out)
end

local function store_sha(store, text)
  if type(store.sha256) ~= "function" then return nil end
  local ok, digest = pcall(store.sha256, text)
  if not ok or type(digest) ~= "string" or #digest ~= 64 then return nil end
  return digest
end

local function new_mail_id(store)
  if type(store.new_id) == "function" then
    local ok, id = pcall(store.new_id)
    if ok and nonempty(id) then return id end
  end
  if type(remuda) == "table" and type(remuda._butler_new_ulid) == "function" then
    local ok, id = pcall(remuda._butler_new_ulid)
    if ok and nonempty(id) then return id end
  end
  return nil
end

local function valid_external_key(key)
  if type(key) ~= "table" then return false, "key" end
  for _, field in ipairs({ "account", "room", "event", "destination" }) do
    if not nonempty(key[field]) then return false, field end
  end
  local destination = key.destination
  if not is_hex(destination) or destination ~= destination:lower() then
    return false, "destination"
  end
  return true
end

local function verified_payload(store, payload)
  if type(payload) ~= "table" or type(payload.content) ~= "string"
    or type(payload.metadata) ~= "string"
    or type(payload.payload_hash) ~= "string" then
    return false, "payload"
  end
  local digest = store_sha(store, frame({ "butler-external-payload-v1",
    payload.content, payload.metadata }))
  if not digest or digest ~= payload.payload_hash then
    return false, "payload_hash"
  end
  local decoded = decode(store, payload.metadata)
  if not decoded then return false, "metadata" end
  if canonical_json(store, decoded) ~= payload.metadata then
    return false, "metadata"
  end
  return true
end

local function committed_receipt(store, operation_id, result)
  return { state = "committed", operation_id = operation_id, result = result }
end

local function operation_row(store, operation_id)
  local rows, err = sql_query(store,
    "SELECT state, payload_hash, result_json FROM auth_operations WHERE operation_id = ?",
    { operation_id })
  if not rows then return nil, err end
  return rows[1]
end

local function receipt_result(store, row)
  if not row or row.state ~= "committed" then return nil end
  local decoded = decode(store, row.result_json)
  if not decoded or type(decoded.result) ~= "table" then return nil end
  return decoded.result
end

-- The file source adapter owns the delivered set and envelope metadata. A
-- Store without it cannot prove anything and must not guess.
function Store:lookup_matrix(recipient, room, event)
  if read_refusal(self) then
    return { state = "unknown", reason = "writer_conflict" }
  end
  if self.authority == "sql" then
    local rows, err = sql_query(self,
      "SELECT message_id FROM auth_matrix WHERE recipient = ? AND room = ? AND event = ?",
      { recipient, room, event })
    if not rows then return { state = "unknown", reason = "unavailable" } end
    if #rows == 0 then return { state = "absent", complete = true } end
    if #rows > 1 then return { state = "unknown", reason = "ambiguous_matrix_key" } end
    return { state = "found", message_id = rows[1].message_id }
  end
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
  local refusal = read_refusal(self)
  if refusal then return nil, refusal end
  if not safe_id(message_id) then
    return nil, { code = "invalid_id" }
  end
  if self.authority == "sql" then
    local rows, err = sql_query(self,
      "SELECT metadata, envelope_ref, object_ref FROM auth_membership "
        .. "WHERE message_id = ? LIMIT 1", { message_id })
    if not rows then return nil, { code = "unavailable" } end
    local row = rows[1]
    if not row then return nil, { code = "not_found" } end
    local envelope = decode(self, row.metadata)
    if not envelope then return nil, { code = "corrupt", field = "metadata" } end
    local content
    if self.content and type(self.content.hydrate) == "function" then
      local ok, hydrated, why = pcall(self.content.hydrate, message_id)
      if not ok or type(hydrated) ~= "table" or type(hydrated.content) ~= "string" then
        return nil, { code = (type(why) == "table" and why.code) or "unavailable" }
      end
      content = hydrated.content
    else
      local text, why = read_file(self.root .. "/" .. row.object_ref)
      if not text then return nil, { code = why or "unavailable" } end
      content = text
    end
    return { message_id = message_id, envelope = envelope, content = content,
      envelope_ref = row.envelope_ref, object_ref = row.object_ref }
  end
  if self.authority == "sql_required" then return nil, { code = "sql_required" } end
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

owner_token = function(store)
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

-- Reads (status/lookup/hydrate/page) do not require a writer capability: a
-- FILE store may be inspected read-only, and a read-only SQL store still has
-- to prove its authority row. Mutations of any tracked/SQL state require the
-- actual cross-process guard and the process registry, not the registry alone.
read_refusal = function(store)
  if store.closed then
    return { code = "writer_conflict", field = "closed" }
  end
  if not store.read_only and not owner_token(store) then
    return { code = "writer_conflict", field = "owner" }
  end
  return nil
end

close_refusal = function(store)
  if store.closed then return nil, { code = "writer_conflict", field = "closed" } end
  if store.read_only or not owner_token(store) then
    return nil, { code = "writer_conflict", field = "owner" }
  end
  local writer = store.writer_state
  if type(writer) ~= "table" or writer.owner ~= true or writer.guarded ~= true then
    return nil, { code = "writer_conflict", field = "writer" }
  end
  return nil
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

function Store:page(recipient, query, cursor)
  local refusal = read_refusal(self)
  if refusal then return nil, refusal end
  if self.authority ~= "sql" then return nil, { code = "sql_required" } end
  if not is_hex(recipient) then return nil, { code = "invalid_id" } end
  if type(query) ~= "table" then return nil, { code = "invalid_query" } end
  local limit = query.limit
  if not is_integer(limit) or limit < 1 or limit > 256 then
    return nil, { code = "invalid_query", field = "limit" }
  end
  if query.unread_only ~= nil and type(query.unread_only) ~= "boolean" then
    return nil, { code = "invalid_query", field = "unread_only" }
  end
  local after, upper = 0, nil
  if cursor ~= nil then
    if type(cursor) ~= "string" then return nil, { code = "stale_generation" } end
    local seq, bound = cursor:match("^(%d+)|(%d+)$")
    if not seq then return nil, { code = "stale_generation" } end
    after, upper = tonumber(seq), tonumber(bound)
  end
  if upper == nil then
    local bound_rows, bound_err = sql_query(self,
      "SELECT COALESCE(MAX(seq), 0) AS upper FROM auth_membership WHERE recipient = ?",
      { recipient })
    if not bound_rows then return nil, { code = "unavailable" } end
    upper = tonumber(bound_rows[1].upper) or 0
  end
  local sql = "SELECT m.message_id, m.seq, m.resent_json, m.metadata, "
    .. "m.envelope_ref, m.object_ref, (r.message_id IS NOT NULL) AS is_read "
    .. "FROM auth_membership m LEFT JOIN reads r ON r.recipient = m.recipient "
    .. "AND r.message_id = m.message_id WHERE m.recipient = ? AND m.seq > ? "
    .. "AND m.seq <= ? "
  if query.unread_only then sql = sql .. "AND r.message_id IS NULL " end
  sql = sql .. "ORDER BY m.seq LIMIT ?"
  local rows, err = sql_query(self, sql, { recipient, after, upper, limit + 1 })
  if not rows then return nil, { code = "unavailable" } end
  local out, more = {}, false
  for index = 1, math.min(#rows, limit) do
    local row = rows[index]
    out[index] = { message_id = row.message_id, seq = tonumber(row.seq),
      resent = row.resent_json, metadata = row.metadata,
      envelope_ref = row.envelope_ref, object_ref = row.object_ref,
      unread = tonumber(row.is_read) == 0 }
  end
  if #rows > limit then more = true end
  local unread_rows = sql_query(self,
    "SELECT COUNT(*) AS n FROM auth_membership m LEFT JOIN reads r "
      .. "ON r.recipient = m.recipient AND r.message_id = m.message_id "
      .. "WHERE m.recipient = ? AND r.message_id IS NULL", { recipient })
  local unread = unread_rows and tonumber(unread_rows[1].n) or nil
  local next_cursor
  if more and #out > 0 then next_cursor = tostring(out[#out].seq) .. "|" .. tostring(upper) end
  return { rows = out, snapshot = { root = self.actual_root, recipient = recipient,
      epoch = self.epoch, generation = self.marker and self.marker.generation,
      upper_seq = upper }, next_cursor = next_cursor, unread = unread }
end

function Store:deliver()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("deliver")
end

function Store:accept_external(key, payload)
  if self.closed or not owner_token(self) then return close_refusal(self) end
  if self.authority ~= "sql" then return nil, { code = "sql_required" } end
  local ok, field = valid_external_key(key)
  if not ok then return nil, { code = "invalid_key", field = field } end
  ok, field = verified_payload(self, payload)
  if not ok then return nil, { code = "operation_conflict", field = field } end
  local key_hash = store_sha(self, frame({ "butler-external-key-v1", key.account,
    key.room, key.event, key.destination }))
  if not key_hash then return nil, { code = "unavailable", field = "sha256" } end
  local operation_id = "external-v1-" .. key_hash
  local existing, existing_err = sql_query(self,
    "SELECT payload_hash, operation_id, message_id FROM auth_external "
      .. "WHERE account = ? AND room = ? AND event = ? AND destination = ?",
    { key.account, key.room, key.event, key.destination })
  if not existing then return nil, { code = "unavailable" } end
  if #existing > 0 then
    local row = existing[1]
    if row.payload_hash ~= payload.payload_hash then
      return nil, { code = "operation_conflict", field = "payload_hash" }
    end
    local receipt = operation_row(self, row.operation_id)
    local result = receipt_result(self, receipt)
    if result then return committed_receipt(self, row.operation_id, result) end
    return nil, { code = "recovery_required", field = "receipt" }
  end
  local prior = operation_row(self, operation_id)
  if prior then
    if prior.payload_hash ~= payload.payload_hash then
      return nil, { code = "operation_conflict", field = "payload_hash" }
    end
    local result = receipt_result(self, prior)
    if result then return committed_receipt(self, operation_id, result) end
    return { state = "unknown", operation_id = operation_id, reason = "unknown_commit" }
  end
  local message_id = new_mail_id(self)
  if not message_id then return nil, { code = "unavailable", field = "new_id" } end
  if not (self.content and type(self.content.publish) == "function") then
    return nil, { code = "unavailable", field = "content" }
  end
  local published, publish_err = self.content.publish({ message_id = message_id,
    content = payload.content, metadata = payload.metadata,
    operation_id = operation_id, key = key })
  if not published then
    return nil, (type(publish_err) == "table" and publish_err) or { code = "unavailable" }
  end
  local envelope_ref = published.envelope_ref or ("messages/" .. message_id .. ".json")
  local object_ref = published.object_ref
  if not nonempty(object_ref) then return nil, { code = "unavailable", field = "object_ref" } end
  local content_hash = published.content_hash
    or store_sha(self, payload.content) or payload.payload_hash
  local result = { message_id = message_id, recipients = { key.destination },
    receipt_id = operation_id }
  local result_json = canonical_json(self, { state = "committed",
    operation_id = operation_id, result = result })
  if not result_json then return nil, { code = "unavailable", field = "canonical" } end
  local began, begin_why = sql_exec(self, "BEGIN IMMEDIATE")
  if not began then return nil, { code = "unavailable" } end
  local function rollback()
    return sql_exec(self, "ROLLBACK")
  end
  local raced, raced_err = sql_query(self,
    "SELECT payload_hash, operation_id, message_id FROM auth_external "
      .. "WHERE account = ? AND room = ? AND event = ? AND destination = ?",
    { key.account, key.room, key.event, key.destination })
  if not raced then rollback(); return nil, { code = "unavailable" } end
  if #raced > 0 then
    local row = raced[1]
    local receipt = operation_row(self, row.operation_id)
    local raced_result = receipt_result(self, receipt)
    rollback()
    if row.payload_hash ~= payload.payload_hash then
      return nil, { code = "operation_conflict", field = "payload_hash" }
    end
    if raced_result then return committed_receipt(self, row.operation_id, raced_result) end
    return nil, { code = "recovery_required", field = "receipt" }
  end
  -- Allocate the delivered-order slot while the write lock is held so two
  -- concurrent acceptances for one recipient cannot collide.
  local seq_rows = sql_query(self,
    "SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM auth_membership WHERE recipient = ?",
    { key.destination })
  if not seq_rows then rollback(); return nil, { code = "unavailable" } end
  local seq = tonumber(seq_rows[1].next)
  local statements = {
    { "INSERT INTO auth_external (account, room, event, destination, key_hash, "
        .. "payload_hash, operation_id, message_id, epoch) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      { key.account, key.room, key.event, key.destination, key_hash,
        payload.payload_hash, operation_id, message_id, self.epoch } },
    { "INSERT INTO auth_operations (operation_id, kind, payload_hash, state, "
        .. "message_id, result_json, epoch) VALUES (?, 'accept_external', ?, "
        .. "'committed', ?, ?, ?)",
      { operation_id, payload.payload_hash, message_id, result_json, self.epoch } },
    { "INSERT INTO auth_membership (recipient, message_id, seq, resent_json, "
        .. "metadata, envelope_ref, object_ref, content_hash, epoch) "
        .. "VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?)",
      { key.destination, message_id, seq, payload.metadata, envelope_ref,
        object_ref, content_hash, self.epoch } },
    { "INSERT INTO auth_matrix (recipient, room, event, message_id) "
        .. "VALUES (?, ?, ?, ?)",
      { key.destination, key.room, key.event, message_id } },
  }
  for _, statement in ipairs(statements) do
    local written, why = sql_exec(self, statement[1], statement[2])
    if not written then
      rollback()
      return nil, { code = "unavailable", field = tostring(why) }
    end
  end
  local committed, commit_why = sql_exec(self, "COMMIT")
  if not committed then
    return { state = "unknown", operation_id = operation_id, reason = "unknown_commit" }
  end
  return committed_receipt(self, operation_id, result)
end

function Store:mark_read(intent, ids, snapshot)
  if self.closed or not owner_token(self) then return close_refusal(self) end
  if self.authority ~= "sql" then return nil, { code = "sql_required" } end
  if type(intent) ~= "table" or not nonempty(intent.operation_id)
    or type(intent.payload_hash) ~= "string" or #intent.payload_hash ~= 64 then
    return nil, { code = "invalid_intent" }
  end
  if type(ids) ~= "table" or type(snapshot) ~= "table" then
    return nil, { code = "invalid_snapshot" }
  end
  if snapshot.root ~= self.actual_root or snapshot.recipient == nil
    or tonumber(snapshot.epoch) ~= self.epoch
    or (self.marker and snapshot.generation ~= self.marker.generation)
    or not is_integer(tonumber(snapshot.upper_seq)) then
    return nil, { code = "stale_generation", field = "snapshot" }
  end
  local upper = tonumber(snapshot.upper_seq)
  local prior = operation_row(self, intent.operation_id)
  if prior then
    if prior.payload_hash ~= intent.payload_hash then
      return nil, { code = "operation_conflict", field = "payload_hash" }
    end
    local result = receipt_result(self, prior)
    if result then return committed_receipt(self, intent.operation_id, result) end
    return { state = "unknown", operation_id = intent.operation_id, reason = "unknown_commit" }
  end
  for index = 1, #ids do
    local id = ids[index]
    if not safe_id(id) then return nil, { code = "invalid_id" } end
    local rows = sql_query(self,
      "SELECT seq FROM auth_membership WHERE recipient = ? AND message_id = ?",
      { snapshot.recipient, id })
    if not rows or #rows == 0 or tonumber(rows[1].seq) > upper then
      return nil, { code = "parity_mismatch", field = "ack", id = id }
    end
  end
  local result = { ids = ids, snapshot = snapshot }
  local result_json = canonical_json(self, { state = "committed",
    operation_id = intent.operation_id, result = result })
  if not result_json then return nil, { code = "unavailable", field = "canonical" } end
  local began = sql_exec(self, "BEGIN IMMEDIATE")
  if not began then return nil, { code = "unavailable" } end
  for index = 1, #ids do
    local written = sql_exec(self,
      "INSERT OR IGNORE INTO reads (recipient, message_id) VALUES (?, ?)",
      { snapshot.recipient, ids[index] })
    if not written then
      sql_exec(self, "ROLLBACK")
      return nil, { code = "unavailable" }
    end
  end
  local written = sql_exec(self,
    "INSERT INTO auth_operations (operation_id, kind, payload_hash, state, "
      .. "message_id, result_json, epoch) VALUES (?, 'mark_read', ?, 'committed', "
      .. "NULL, ?, ?)",
    { intent.operation_id, intent.payload_hash, result_json, self.epoch })
  if not written then sql_exec(self, "ROLLBACK"); return nil, { code = "unavailable" } end
  local committed = sql_exec(self, "COMMIT")
  if not committed then
    return { state = "unknown", operation_id = intent.operation_id, reason = "unknown_commit" }
  end
  return committed_receipt(self, intent.operation_id, result)
end

-- Phase B: the FILE_TRACKED gate is persisted before any migration work.
-- Initializing the journal generation and atomically publishing the tracked
-- marker is admission; a later step may only stage inside those sealed ends.
local function migration_state_row(store)
  local rows = sql_query(store,
    "SELECT generation, epoch, revision FROM migration_state WHERE root = ?",
    { store.actual_root })
  if not rows then return nil, { code = "unavailable", field = "migration_state_read" } end
  return rows[1]
end

local function ensure_tracking(store)
  local row, err = migration_state_row(store)
  if row == nil and err then return nil, err end
  local marker = store.marker
  if marker.state == "FILE" then
    if row then return nil, { code = "recovery_required", field = "migration_state" } end
    local digest = store_sha(store, frame({ "tracked-file-v1", store.actual_root,
      tostring(store.epoch) }))
    if not digest or #digest ~= 64 then
      return nil, { code = "unavailable", field = "sha256" }
    end
    local generation = "tracked-" .. digest
    local written = sql_exec(store,
      "INSERT INTO migration_state (root, generation, epoch, protocol, revision) "
        .. "VALUES (?, ?, ?, 'tracked-file-v1', 0)",
      { store.actual_root, generation, store.epoch })
    if not written then return nil, { code = "unavailable", field = "migration_state_write" } end
    local adapter = store.marker_adapter
    if type(adapter) ~= "table" or type(adapter.publish) ~= "function" then
      return nil, { code = "unavailable", field = "marker" }
    end
    local next_marker = { format_version = 1, state = "FILE_TRACKED",
      protocol = "tracked-file-v1", root = store.actual_root,
      epoch = store.epoch, tracking_epoch = store.epoch, generation = generation }
    local ok, published = pcall(adapter.publish, next_marker)
    if not ok or published == nil then
      return nil, { code = "unknown_publish", field = "marker" }
    end
    local read_ok, current = pcall(adapter.read, store.root)
    if not read_ok or type(current) ~= "table"
      or current.format_version ~= 1 or current.state ~= "FILE_TRACKED"
      or current.protocol ~= "tracked-file-v1" or current.root ~= store.actual_root
      or tonumber(current.epoch) ~= store.epoch
      or tonumber(current.tracking_epoch) ~= store.epoch
      or current.generation ~= generation then
      return nil, { code = "unknown_publish", field = "marker" }
    end
    store.marker = current
    return generation, nil
  end
  if marker.state == "FILE_TRACKED" then
    if not row then return nil, { code = "recovery_required", field = "migration_state" } end
    if row.generation ~= marker.generation then
      return nil, { code = "recovery_required", field = "generation" }
    end
    return row.generation, nil
  end
  return nil, { code = "invalid_snapshot", field = "state" }
end

local function migration_watermark(store, generation)
  local rows = sql_query(store,
    "SELECT watermark FROM migration_tail_state WHERE root = ? AND generation = ?",
    { store.actual_root, generation })
  if not rows or #rows == 0 then return 0 end
  return tonumber(rows[1].watermark) or 0
end

local function migration_backlog(store, generation, reason, step)
  return { state = "backlog", complete = false, reason = reason,
    cursor = { generation = generation, pass = "seal", task = step or "seal", offset = 0 },
    tail_watermark = migration_watermark(store, generation) }
end

local function seal_step(store, generation, budget)
  local source = store.source
  if type(source) ~= "table" then
    return migration_backlog(store, generation, "sealed_source_unavailable")
  end
  if type(source.recipients) ~= "function" then
    return migration_backlog(store, generation, "sealed_source_unavailable")
  end
  local ok, value, why = pcall(source.recipients, source, store.root)
  if not ok or type(value) ~= "table" or type(value.recipients) ~= "table" then
    local code = (type(why) == "table" and why.code) or
      (type(value) == "table" and value.code) or "source_unreadable"
    return migration_backlog(store, generation, code)
  end
  local sealed = 0
  for _, hex in ipairs(value.recipients) do
    if sealed >= budget.max_statements then break end
    local rows = sql_query(store,
      "SELECT inbox_end, read_end FROM migration_prefix WHERE root = ? "
        .. "AND generation = ? AND recipient = ?",
      { store.actual_root, generation, hex })
    if not rows then return nil, { code = "unavailable", field = "migration_prefix" } end
    if #rows == 0 then
      if type(source.seal) ~= "function" then
        return migration_backlog(store, generation, "sealed_source_unavailable")
      end
      local sealed_ok, sealed_value, sealed_why = pcall(source.seal, source,
        store.root, hex)
      if not sealed_ok or type(sealed_value) ~= "table" then
        local code = (type(sealed_value) == "table" and sealed_value.code)
          or (type(sealed_why) == "table" and sealed_why.code)
          or (type(sealed_why) == "string" and sealed_why) or "source_unreadable"
        return migration_backlog(store, generation, code)
      end
      local written = sql_exec(store,
        "INSERT INTO migration_prefix (root, generation, recipient, inbox_end, "
          .. "read_end, inbox_torn, read_torn, revision, cursor_json, complete) "
          .. "VALUES (?, ?, ?, ?, ?, ?, ?, 0, '{}', 0)",
        { store.actual_root, generation, hex, sealed_value.inbox_end,
          sealed_value.read_end, sealed_value.inbox_torn, sealed_value.read_torn })
      if not written then return nil, { code = "unavailable", field = "migration_prefix" } end
      sealed = sealed + 1
    end
  end
  local cursor = { generation = generation, pass = "seal",
    task = sealed > 0 and "sealed" or "prefix_pending", offset = 0 }
  return { state = "backlog", complete = false, reason = "prefix_pending",
    cursor = cursor, sealed = sealed,
    tail_watermark = migration_watermark(store, generation) }
end

-- One bounded advance unit: seal newly seen recipients first, then run sealed
-- prefix staging for the first incomplete mailbox. Staged rows live in the
-- shared progress backend under the tracked generation; the sealed ends never
-- move, so arrivals after a seal stay for the tail/journal phase.
local function advance_step(store, generation, budget)
  local sealed_result, seal_err = seal_step(store, generation, budget)
  if not sealed_result then return nil, seal_err end
  if (sealed_result.sealed or 0) > 0 then return sealed_result end
  local source = store.source
  if type(source) ~= "table" or type(source.sealed_advance) ~= "function" then
    return migration_backlog(store, generation, "sealed_advance_unavailable")
  end
  local units = 0
  while units < budget.max_statements do
    local rows = sql_query(store,
      "SELECT recipient, inbox_end, read_end FROM migration_prefix WHERE root = ? "
        .. "AND generation = ? AND complete = 0 ORDER BY recipient LIMIT 1",
      { store.actual_root, generation })
    if not rows then return nil, { code = "unavailable", field = "migration_prefix" } end
    if #rows == 0 then
      return migration_backlog(store, generation, "barrier_pending")
    end
    local row = rows[1]
    local ok, result, why = pcall(source.sealed_advance, source, store.root,
      row.recipient, { generation = generation,
        inbox_end = tonumber(row.inbox_end), read_end = tonumber(row.read_end) },
      { max_bytes = budget.max_bytes, max_tasks = 1, max_ms = budget.max_ms })
    if not ok then return nil, { code = "source_unreadable", field = "sealed" } end
    if type(result) ~= "table" then
      return nil, (type(why) == "table" and why) or { code = "source_unreadable" }
    end
    local evidence = { state = result.state, cursor = result.cursor,
      witness = result.snapshot and result.snapshot.witness or nil }
    local cursor_json = canonical_json(store, evidence)
    if not cursor_json then return nil, { code = "unavailable", field = "canonical" } end
    local written = sql_exec(store,
      "UPDATE migration_prefix SET revision = ?, cursor_json = ?, complete = ? "
        .. "WHERE root = ? AND generation = ? AND recipient = ?",
      { (result.cursor and result.cursor.revision) or 0, cursor_json,
        result.complete == true and 1 or 0, store.actual_root, generation,
        row.recipient })
    if not written then return nil, { code = "unavailable", field = "migration_prefix" } end
    units = units + 1
  end
  local pending = sql_query(store,
    "SELECT COUNT(*) AS n FROM migration_prefix WHERE root = ? AND generation = ? "
      .. "AND complete = 0", { store.actual_root, generation })
  if not pending then return nil, { code = "unavailable", field = "migration_prefix" } end
  return migration_backlog(store, generation,
    tonumber(pending[1].n) == 0 and "barrier_pending" or "prefix_pending")
end

function Store:advance(budget)
  local refusal = close_refusal(self)
  if refusal then return nil, refusal end
  if type(budget) ~= "table" then return nil, { code = "invalid_snapshot", field = "budget" } end
  for _, key in ipairs({ "max_bytes", "max_ms" }) do
    local value = budget[key]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
      return nil, { code = "invalid_snapshot", field = "budget" }
    end
  end
  local statements = budget.max_statements
  if statements == nil then statements = budget.max_tasks end
  if type(statements) ~= "number" or statements % 1 ~= 0 or statements < 1 then
    return nil, { code = "invalid_snapshot", field = "budget" }
  end
  if self.marker.state ~= "FILE" and self.marker.state ~= "FILE_TRACKED" then
    return nil, { code = "invalid_snapshot", field = "state" }
  end
  local generation, gate_err = ensure_tracking(self)
  if not generation then return nil, gate_err end
  return advance_step(self, generation, { max_bytes = budget.max_bytes,
    max_statements = statements, max_ms = budget.max_ms })
end

function Store:transition()
  if self.closed or not owner_token(self) then return close_refusal(self) end
  return unimplemented("transition")
end

function Store:reconcile(operation_id)
  if self.closed or not owner_token(self) then return close_refusal(self) end
  if not nonempty(operation_id) then return nil, { code = "invalid_id" } end
  if self.authority ~= "sql" and self.authority ~= "sql_required" then
    return { state = "unknown", operation_id = operation_id,
      reason = "recovery_required" }
  end
  local row, err = operation_row(self, operation_id)
  if row == nil and err then
    return { state = "unknown", operation_id = operation_id, reason = "unavailable" }
  end
  if row == nil then return { state = "not_committed", operation_id = operation_id } end
  if row.state ~= "committed" then
    return { state = "unknown", operation_id = operation_id, reason = "unknown_commit" }
  end
  local result = receipt_result(self, row)
  if not result then
    return { state = "unknown", operation_id = operation_id, reason = "corrupt" }
  end
  return committed_receipt(self, operation_id, result)
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
  local writable = config.writer ~= nil and type(config.writer.claim) == "function"
  local store = setmetatable({ root = config.root, actual_root = actual,
    marker = marker, source = config.source, content = config.content,
    json = config.json, sha256 = config.sha256, new_id = config.new_id,
    progress = config.progress, migration = config.migration,
    marker_adapter = config.marker,
    decode = decoder(config), read_only = not writable }, Store)
  if writable then
    if OWNER_STATE.owners[actual] then return fail("writer_conflict", "owner") end
    OWNER_STATE.serial = (OWNER_STATE.serial or 0) + 1
    local token = { root = actual, serial = OWNER_STATE.serial }
    OWNER_STATE.owners[actual] = token
    OWNER_STATE.tokens[store] = token
    local ok, capability, why = pcall(config.writer.claim, config.root)
    if not ok or type(capability) ~= "table" then
      release_owner(store)
      local code = (type(capability) == "table" and capability.code)
        or (type(why) == "table" and why.code) or "writer_conflict"
      return fail(code, "writer")
    end
    -- Attach the acquired lease before any validation so every refusal releases
    -- exactly this capability once, even when the usable fields are malformed.
    store.release_capability = capability.release
    local capability_root = capability.root
    if capability_root ~= nil and resolve_root(config, capability_root) ~= actual then
      release_owner(store)
      return fail("writer_conflict", "root")
    end
    if capability.owner ~= true then release_owner(store); return fail("writer_conflict", "owner") end
    if capability.guarded ~= true then release_owner(store); return fail("writer_conflict", "guarded") end
    store.writer_state = { owner = true, guarded = true }
    store.read_only = false
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
        "SELECT format_version, root, epoch, generation, operation_id, proof_hash, "
          .. "tail_watermark FROM auth_authority WHERE id = 1")
      local row = rows and rows[1]
      if not row or tonumber(row.format_version) ~= marker.format_version
        or row.root ~= actual or tonumber(row.epoch) ~= marker.epoch
        or row.generation ~= marker.generation
        or row.operation_id ~= marker.operation_id
        or row.proof_hash ~= marker.proof_hash
        or tonumber(row.tail_watermark) ~= marker.tail_watermark then
        release_owner(store)
        return fail("recovery_required", "authority")
      end
    end
  end
  -- A FILE store may still need the borrowed inbox DB to initialize the
  -- durable tracked generation before its first admitted mutation. Attaching an
  -- explicit handle is not an authority or liveness claim in FILE state.
  if marker.state == "FILE" and config.db ~= nil then store.db = config.db end
  store.authority = (marker.state == "SQL_ACTIVE" and "sql")
    or (marker.state == "CUTOVER_PREPARED" and "sql_required") or "file"
  store.epoch = marker.epoch
  return store
end

M.Store = Store

if type(remuda) == "table" then remuda._butler_inbox_authority = M end
return M
