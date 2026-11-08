-- Relay SQLite authority store (first slice: schema, import, activation).
--
-- This module is the product implementation behind the abstract contract in
-- butler/relay_store_contract. It receives every capability through opts; it
-- never opens a legacy file, reads JSON state, or registers a global. Source
-- JSON is staged as bytes and imported with bounded SQL pages; the root is
-- never decoded into Lua.
local M = {}
M.version = 1
M.limits = {
  source_bytes = 32 * 1024 * 1024,
  record_bytes = 256 * 1024,
  record_nodes = 8192,
  page_rows = 64,
  marker_bytes = 4096,
  digest_chunk_bytes = 65536,
  db_bytes = 256 * 1024 * 1024,
  sql_timeout_ms = 10000,
  max_rows = 10000,
}

local json = assert(remuda.json, "relay store requires core remuda.json")

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS relay_authority (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  schema_version INTEGER NOT NULL,
  store_id TEXT NOT NULL UNIQUE,
  phase TEXT NOT NULL CHECK(phase IN ('importing','active','blocked')),
  owner_id TEXT NOT NULL,
  epoch INTEGER NOT NULL CHECK(epoch>0),
  source_stamp TEXT NOT NULL,
  import_verified INTEGER NOT NULL DEFAULT 0 CHECK(import_verified IN(0,1)),
  data_revision INTEGER NOT NULL DEFAULT 0,
  blocked_reason TEXT
);
CREATE TABLE IF NOT EXISTS relay_verify_progress (
  verification_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0,
  data_revision INTEGER NOT NULL,
  unit_id INTEGER,
  cursor TEXT,
  state TEXT NOT NULL CHECK(state IN ('backlog','ready')),
  processed_rows INTEGER NOT NULL DEFAULT 0,
  bytes INTEGER NOT NULL DEFAULT 0,
  nodes INTEGER NOT NULL DEFAULT 0,
  certificate_id TEXT,
  witness_id TEXT,
  phase TEXT NOT NULL DEFAULT 'witness',
  phase_cursor TEXT,
  owner_id TEXT,
  epoch INTEGER
);
CREATE TABLE IF NOT EXISTS relay_verify_certificates (
  certificate_id TEXT PRIMARY KEY,
  verification_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  witness_id TEXT NOT NULL,
  data_revision INTEGER NOT NULL,
  processed_rows INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  nodes INTEGER NOT NULL,
  owner_id TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS relay_proof_state (
  verification_id TEXT PRIMARY KEY,
  store_id TEXT NOT NULL,
  proof_version INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS relay_schema_state (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  trigger_fingerprint TEXT NOT NULL,
  schema_version INTEGER NOT NULL DEFAULT 0,
  pending INTEGER NOT NULL DEFAULT 0 CHECK(pending IN(0,1))
);
CREATE TABLE IF NOT EXISTS relay_verify_witness (
  witness_id TEXT PRIMARY KEY,
  store_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('source','sidecar')),
  role TEXT NOT NULL,
  stamp TEXT,
  bytes INTEGER NOT NULL,
  raw_sha256 TEXT NOT NULL,
  root_digest TEXT NOT NULL,
  chunk_size INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(store_id, source_id, kind)
);
DROP TRIGGER IF EXISTS relay_witness_no_insert;
CREATE TRIGGER IF NOT EXISTS relay_witness_no_insert BEFORE INSERT ON relay_verify_witness
WHEN EXISTS(SELECT 1 FROM relay_verify_witness w WHERE w.store_id=NEW.store_id
  AND w.source_id=NEW.source_id AND w.kind=NEW.kind)
BEGIN SELECT RAISE(ABORT,'witness_immutable'); END;
DROP TRIGGER IF EXISTS relay_witness_no_update;
CREATE TRIGGER IF NOT EXISTS relay_witness_no_update BEFORE UPDATE ON relay_verify_witness
BEGIN SELECT RAISE(ABORT,'witness_immutable'); END;
DROP TRIGGER IF EXISTS relay_witness_no_delete;
CREATE TRIGGER IF NOT EXISTS relay_witness_no_delete BEFORE DELETE ON relay_verify_witness
BEGIN SELECT RAISE(ABORT,'witness_immutable'); END;
CREATE TABLE IF NOT EXISTS relay_manifest (
  source_id TEXT PRIMARY KEY,
  role TEXT NOT NULL CHECK(role IN ('primary','backup_evidence','acks','drain')),
  stamp TEXT,
  marker_durability TEXT,
  db_durability TEXT
);
CREATE TABLE IF NOT EXISTS relay_import_source (
  source_id TEXT PRIMARY KEY,
  role TEXT NOT NULL,
  stamp TEXT,
  raw TEXT,
  raw_sha256 TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('importing','staged','verified','evidence','blocked')),
  staged_count INTEGER NOT NULL DEFAULT 0,
  verified_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS relay_import_source_status ON relay_import_source(status);
CREATE TABLE IF NOT EXISTS relay_source_fields (
  source_id TEXT NOT NULL,
  path TEXT NOT NULL,
  parent_key TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY(source_id,path)
);
CREATE TABLE IF NOT EXISTS relay_import_units (
  unit_id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_id TEXT NOT NULL,
  root_field TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('object','array','raw')),
  parent_key TEXT NOT NULL DEFAULT '',
  nested INTEGER NOT NULL DEFAULT 0,
  expected INTEGER NOT NULL DEFAULT 0,
  done INTEGER NOT NULL DEFAULT 0,
  last_key TEXT,
  last_seq INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS relay_import_units_pending ON relay_import_units(source_id,done,unit_id);
CREATE TABLE IF NOT EXISTS relay_import_queue (
  source_id TEXT NOT NULL,
  unit_id INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  key TEXT NOT NULL,
  kind TEXT NOT NULL,
  parent_key TEXT NOT NULL DEFAULT '',
  ordinal INTEGER,
  payload_json TEXT NOT NULL,
  PRIMARY KEY(source_id,unit_id,seq)
);
CREATE TABLE IF NOT EXISTS relay_cursors (
  scope TEXT PRIMARY KEY CHECK(scope IN ('sync','messages')),
  present INTEGER NOT NULL CHECK(present IN(0,1)),
  cursor_json TEXT,
  value TEXT
);
CREATE TABLE IF NOT EXISTS relay_records (
  namespace TEXT NOT NULL,
  parent_key TEXT NOT NULL DEFAULT '',
  record_key TEXT NOT NULL,
  ordinal INTEGER,
  json_kind TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  PRIMARY KEY(namespace,parent_key,record_key)
);
CREATE INDEX IF NOT EXISTS relay_records_order ON relay_records(namespace,parent_key,ordinal,record_key);
CREATE TABLE IF NOT EXISTS relay_processed (
  source_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  event_id TEXT NOT NULL,
  PRIMARY KEY(source_id,ordinal)
);
CREATE INDEX IF NOT EXISTS relay_processed_event ON relay_processed(event_id);
CREATE TABLE IF NOT EXISTS relay_events (
  event_id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL DEFAULT '',
  source_key TEXT NOT NULL UNIQUE,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  state TEXT NOT NULL CHECK(state IN ('pending','delivered','filtered','quarantined')),
  inbox_mail_id TEXT
);
CREATE INDEX IF NOT EXISTS relay_events_pending ON relay_events(state,event_id);
CREATE TABLE IF NOT EXISTS relay_reply_intents (
  reply_id TEXT PRIMARY KEY,
  txn_id TEXT UNIQUE,
  state TEXT NOT NULL CHECK(state IN ('prepared','in_flight','sent','failed','uncertain')),
  attempts INTEGER,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  owner_id TEXT,
  epoch INTEGER,
  imported INTEGER NOT NULL DEFAULT 0 CHECK(imported IN(0,1))
);
CREATE INDEX IF NOT EXISTS relay_reply_intents_state ON relay_reply_intents(state,imported);
CREATE TABLE IF NOT EXISTS relay_operations (
  operation_id TEXT PRIMARY KEY,
  operation_kind TEXT NOT NULL,
  input_witness TEXT NOT NULL,
  result_json TEXT NOT NULL CHECK(json_valid(result_json)),
  owner_id TEXT NOT NULL,
  epoch INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS relay_sidecar (
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  raw TEXT NOT NULL,
  raw_sha256 TEXT NOT NULL,
  stamp TEXT,
  PRIMARY KEY(source_id,kind)
);

-- Every verification-input mutation while importing advances data_revision.
-- Verify progress/certificate/status bookkeeping is excluded; after ACTIVE the
-- triggers are inert, so normal runtime mutations do not invalidate the cert.
DROP TRIGGER IF EXISTS relay_rev_records_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_records_ins AFTER INSERT ON relay_records
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_records_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_records_upd AFTER UPDATE ON relay_records
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_records_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_records_del AFTER DELETE ON relay_records
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_processed_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_processed_ins AFTER INSERT ON relay_processed
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_events_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_events_ins AFTER INSERT ON relay_events
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_events_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_events_upd AFTER UPDATE ON relay_events
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_intents_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_intents_ins AFTER INSERT ON relay_reply_intents
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_intents_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_intents_upd AFTER UPDATE ON relay_reply_intents
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_fields_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_fields_ins AFTER INSERT ON relay_source_fields
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_cursors_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_cursors_ins AFTER INSERT ON relay_cursors
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_cursors_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_cursors_upd AFTER UPDATE ON relay_cursors
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_source_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_source_ins AFTER INSERT ON relay_import_source
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_source_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_source_upd AFTER UPDATE ON relay_import_source
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
 AND (OLD.raw IS NOT NEW.raw OR OLD.raw_sha256 IS NOT NEW.raw_sha256
   OR OLD.stamp IS NOT NEW.stamp OR OLD.bytes IS NOT NEW.bytes
   OR OLD.staged_count IS NOT NEW.staged_count
   OR OLD.role IS NOT NEW.role OR OLD.source_id IS NOT NEW.source_id)
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_source_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_source_del AFTER DELETE ON relay_import_source
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_source_status;
CREATE TRIGGER IF NOT EXISTS relay_rev_source_status AFTER UPDATE OF status ON relay_import_source
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
 AND OLD.status IS NOT NEW.status
 AND NOT (OLD.status IN ('importing','staged') AND NEW.status='verified')
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_units_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_units_ins AFTER INSERT ON relay_import_units
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_units_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_units_upd AFTER UPDATE ON relay_import_units
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_units_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_units_del AFTER DELETE ON relay_import_units
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_manifest_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_manifest_ins AFTER INSERT ON relay_manifest
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_manifest_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_manifest_upd AFTER UPDATE ON relay_manifest
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_manifest_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_manifest_del AFTER DELETE ON relay_manifest
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_fields_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_fields_upd AFTER UPDATE ON relay_source_fields
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_fields_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_fields_del AFTER DELETE ON relay_source_fields
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_cursors_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_cursors_del AFTER DELETE ON relay_cursors
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_processed_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_processed_upd AFTER UPDATE ON relay_processed
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_processed_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_processed_del AFTER DELETE ON relay_processed
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_events_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_events_del AFTER DELETE ON relay_events
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_intents_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_intents_del AFTER DELETE ON relay_reply_intents
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_sidecar_ins;
CREATE TRIGGER IF NOT EXISTS relay_rev_sidecar_ins AFTER INSERT ON relay_sidecar
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_sidecar_upd;
CREATE TRIGGER IF NOT EXISTS relay_rev_sidecar_upd AFTER UPDATE ON relay_sidecar
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
DROP TRIGGER IF EXISTS relay_rev_sidecar_del;
CREATE TRIGGER IF NOT EXISTS relay_rev_sidecar_del AFTER DELETE ON relay_sidecar
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
]]

local METHODS = {
  'import_prepare', 'import_source', 'import_batch', 'import_acks',
  'verify_import', 'activate', 'writer', 'cursor', 'accept_batch',
  'dispatch_page', 'complete_dispatch', 'get', 'put', 'delete', 'page',
  'resolve_operation', 'reply_dispatch_page', 'claim_reply', 'complete_reply',
  'fail_reply', 'status', 'proof',
}

-- Bump whenever the verification semantics change. A READY certificate and
-- activation are bound to this constant through relay_proof_state, so a cert
-- produced by an older verifier cannot be reused even if triggers match.
local PROOF_VERSION = 3
local SCHEMA_VERSION = 1

local KNOWN = {
  since = 'scalar',
  messages_since = 'scalar',
  processed_event_ids = 'array',
  quarantine = 'array',
  auto_join_timestamps = 'array',
  typed_line_timestamps = 'array',
  approvals = 'map',
  invite_dedupe = 'map',
  matrix_mail_routes = 'map',
  matrix_own_events = 'nested_array',
  matrix_reply_outbox = 'map',
  matrix_reply_results = 'map',
  matrix_thread_subscriptions = 'nested_map',
  matrix_unfollowed_threads = 'nested_map',
  pending_events = 'map',
}

local function fail(code, detail)
  return nil, detail and (code .. ': ' .. tostring(detail)) or code
end

local function invoke(fn, ...)
  local ok, value, why = pcall(fn, ...)
  if not ok then return nil, 'provider_error: ' .. tostring(value) end
  return value, why
end

local function intent_attempts(value)
  local attempts = tonumber(value)
  if attempts and attempts % 1 ~= 0 then attempts = nil end
  return attempts
end

local function identifier(value)
  return type(value) == 'string' and #value > 0 and #value <= 256
    and not value:find('[%c"\\]')
end

local function validate(opts)
  if type(opts) ~= 'table' then return fail('options', 'table required') end
  for _, provider in ipairs({ 'db', 'marker', 'anchors', 'owner', 'json', 'digest' }) do
    if type(opts[provider]) ~= 'table' then return fail('options', 'missing ' .. provider) end
  end
  for _, name in ipairs({ 'acquire' }) do
    if type(opts.db[name]) ~= 'function' then return fail('options', 'missing db.' .. name) end
  end
  for _, name in ipairs({ 'read', 'publish' }) do
    if type(opts.marker[name]) ~= 'function' then return fail('options', 'missing marker.' .. name) end
  end
  if type(opts.anchors.inspect) ~= 'function' then return fail('options', 'missing anchors.inspect') end
  for _, name in ipairs({ 'acquire', 'check', 'describe', 'release' }) do
    if type(opts.owner[name]) ~= 'function' then return fail('options', 'missing owner.' .. name) end
  end
  for _, name in ipairs({ 'decode_record', 'encode_record' }) do
    if type(opts.json[name]) ~= 'function' then return fail('options', 'missing json.' .. name) end
  end
  if type(opts.digest.sha256) ~= 'function' then return fail('options', 'missing digest.sha256') end
  local identity = opts.identity
  if type(identity) ~= 'table' then return fail('identity', 'table required') end
  for _, name in ipairs({ 'root_id', 'account_id', 'device_id', 'relay_id' }) do
    if not identifier(identity[name]) then return fail('identity', 'invalid ' .. name) end
  end
  if opts.limits ~= nil and type(opts.limits) ~= 'table' then return fail('limits', 'table required') end
  if opts.faults ~= nil and type(opts.faults) ~= 'function' then return fail('options', 'faults must be function or nil') end
  for name, ceiling in pairs(M.limits) do
    local value = opts.limits and opts.limits[name] or ceiling
    if type(value) ~= 'number' or value < 1 or value > ceiling or value % 1 ~= 0 then
      return fail('limits', 'invalid ' .. name)
    end
  end
  return true
end

local function query(db, sql, params)
  local rows, why = db:query(sql, params)
  if not rows then return nil, why end
  return rows
end

local function exec(db, sql, params)
  local changes, why = db:exec(sql, params)
  if changes == nil then return nil, why end
  return changes
end

local function begin(db)
  local ok, why = exec(db, 'BEGIN IMMEDIATE')
  if not ok then return nil, why end
  return true
end

local function commit(db)
  local ok, why = exec(db, 'COMMIT')
  if not ok then return nil, why end
  return true
end

local function rollback(db)
  pcall(db.exec, db, 'ROLLBACK')
end

local function encode(value)
  local ok, text = pcall(json.encode, value)
  if not ok then return nil, tostring(text) end
  return text
end

local function decode(value)
  local ok, text = pcall(json.decode, value)
  if not ok then return nil, tostring(text) end
  return text
end

local function hex_encode(value)
  return (value:gsub('.', function(byte) return string.format('%02x', string.byte(byte)) end))
end

local function hex_decode(value)
  if type(value) ~= 'string' or #value % 2 ~= 0 or not value:match('^[0-9a-f]*$') then return nil end
  return (value:gsub('(%x%x)', function(pair) return string.char(tonumber(pair, 16)) end))
end

-- The marker is a tiny versioned line document, not a general JSON blob. It is
-- parsed strictly before any database side effect: exact header, exact keys,
-- one value each, no extra lines, bounded length.
local function marker_parse(raw, limit)
  if type(raw) ~= 'string' or #raw == 0 or #raw > limit then return nil end
  local lines = {}
  for line in (raw .. '\n'):gmatch('(.-)\n') do
    lines[#lines + 1] = line
  end
  -- Exact header + five key lines; no blank lines, no extra content.
  if #lines ~= 6 or lines[1] ~= 'butler-relay-marker-v1' then return nil end
  local order = { 'version', 'store_id_hex', 'owner_id_hex', 'epoch', 'source_stamp_hex' }
  local values = {}
  for index = 2, 6 do
    local key, value = lines[index]:match('^([a-z_]+)=(.+)$')
    if not key or key ~= order[index - 1] or values[key] ~= nil then return nil end
    values[key] = value
  end
  if values.version ~= '1' then return nil end
  if not values.epoch:match('^[1-9][0-9]*$') then return nil end
  local epoch = tonumber(values.epoch)
  if not epoch or epoch < 1 or epoch % 1 ~= 0 then return nil end
  local store_id, owner_id = hex_decode(values.store_id_hex), hex_decode(values.owner_id_hex)
  if not identifier(store_id) or not identifier(owner_id) then return nil end
  if #values.source_stamp_hex % 2 ~= 0 or not values.source_stamp_hex:match('^[0-9a-f]*$') then
    return nil
  end
  return { version = 1, store_id = store_id, owner_id = owner_id, epoch = epoch }
end

local function marker_encode(store_id, owner_id, epoch, source_stamp)
  local raw = table.concat({
    'butler-relay-marker-v1',
    'version=1',
    'store_id_hex=' .. hex_encode(store_id),
    'owner_id_hex=' .. hex_encode(owner_id),
    'epoch=' .. tostring(epoch),
    'source_stamp_hex=' .. hex_encode(tostring(source_stamp or '')),
  }, '\n')
  if #raw > M.limits.marker_bytes then return nil end
  return raw
end

-- A bounded paged SHA-256 over source bytes. The root is a fixed-size digest
-- of per-chunk hex, so the digest provider never receives the whole source.
local function source_digest(opts, bytes)
  local chunk = (opts.limits and opts.limits.digest_chunk_bytes)
    or M.limits.digest_chunk_bytes
  local parts = {}
  for index = 1, #bytes, chunk do
    local hex, why = invoke(opts.digest.sha256, bytes:sub(index, index + chunk - 1))
    if type(hex) ~= 'string' then return nil, why or 'digest' end
    parts[#parts + 1] = hex
  end
  local joined = table.concat(parts)
  local root, why = invoke(opts.digest.sha256,
    'butler-relay-source-v1\0' .. tostring(#bytes) .. '\0' .. joined)
  if type(root) ~= 'string' then return nil, why or 'digest' end
  return root
end

local function trigger_map(db)
  local rows, why = query(db,
    "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name GLOB 'relay_*'")
  if not rows then return nil, why end
  local map = {}
  for _, row in ipairs(rows) do map[row.name] = row.sql end
  return map
end

local function trigger_text(map)
  local names = {}
  for name in pairs(map) do names[#names + 1] = name end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    local sql = tostring(map[name])
    parts[#parts + 1] = name .. '\0' .. tostring(#sql) .. '\0' .. sql
  end
  return table.concat(parts, '\1')
end

local function ensure_schema(db)
  -- Pending publication comes BEFORE repair DDL when the state table already
  -- exists. If the marker cannot be written, no trigger repair is applied, so
  -- a later open still sees the old fingerprint and retries. When the table is
  -- first created, a missing fingerprint row is itself the durable signal.
  local existing, existing_why = query(db,
    "SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name='relay_schema_state'")
  if not existing then return fail('schema', existing_why) end
  local had_state = existing[1] ~= nil
  local before, before_why = trigger_map(db)
  if not before then return fail('schema', before_why) end
  local before_text = trigger_text(before)
  local stored = nil
  if had_state then
    local rows, stored_why = query(db,
      'SELECT trigger_fingerprint,schema_version,pending FROM relay_schema_state ' ..
        'WHERE singleton=1')
    if not rows then return fail('schema', stored_why) end
    stored = rows[1]
  end
  local repair = not had_state or not stored
    or tonumber(stored.schema_version) ~= SCHEMA_VERSION
    or tonumber(stored.pending or 0) == 1
    or before_text ~= stored.trigger_fingerprint
  if repair and had_state then
    local marked, mark_why = exec(db,
      'INSERT OR REPLACE INTO relay_schema_state ' ..
        '(singleton,trigger_fingerprint,schema_version,pending) VALUES (1,?,?,1)',
      { stored and stored.trigger_fingerprint or before_text, SCHEMA_VERSION })
    if marked ~= 1 then return fail('schema', mark_why) end
  end
  local ok, why = db:batch(SCHEMA)
  if not ok then return fail('schema', why) end
  local after, after_why = trigger_map(db)
  if not after then return fail('schema', after_why) end
  local after_text = trigger_text(after)
  if repair or after_text ~= before_text then
    if not had_state then
      local marked, mark_why = exec(db,
        'INSERT OR REPLACE INTO relay_schema_state ' ..
          '(singleton,trigger_fingerprint,schema_version,pending) VALUES (1,?,?,1)',
        { before_text, SCHEMA_VERSION })
      if marked ~= 1 then return fail('schema', mark_why) end
    end
    local authority, count_why = query(db,
      'SELECT count(*) AS n FROM relay_authority')
    if not authority then return fail('schema', count_why) end
    if tonumber(authority[1].n) > 0 then
      local called, changed, bump_why = pcall(exec, db,
        'UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1')
      if not called or tonumber(changed) ~= 1 then
        pcall(exec, db, 'DELETE FROM relay_verify_certificates')
        pcall(exec, db, 'DELETE FROM relay_verify_progress')
        return fail('schema', 'repair_invalidate: ' .. tostring(called and changed or bump_why))
      end
    end
    local saved, save_why = exec(db,
      'INSERT OR REPLACE INTO relay_schema_state ' ..
        '(singleton,trigger_fingerprint,schema_version,pending) VALUES (1,?,?,0)',
      { after_text, SCHEMA_VERSION })
    if saved ~= 1 then return fail('schema', save_why) end
  end
  return true
end

local function manifest_sources(manifest)
  local sources = {}
  if type(manifest.sources) == 'table' then
    for _, source in ipairs(manifest.sources) do
      if type(source) == 'table' and identifier(source.id) then
        sources[#sources + 1] = {
          id = source.id,
          role = source.role or 'primary',
          stamp = source.stamp or manifest.source_stamp,
        }
      end
    end
  end
  if #sources == 0 then
    if not identifier(manifest.source_id) then return nil, 'source_id' end
    sources[1] = { id = manifest.source_id, role = 'primary',
      stamp = manifest.source_stamp }
  end
  local primary = 0
  for _, source in ipairs(sources) do
    if source.role == 'primary' then primary = primary + 1 end
    if source.role ~= 'primary' and source.role ~= 'backup_evidence'
        and source.role ~= 'acks' and source.role ~= 'drain' then
      return nil, 'source_role'
    end
  end
  if primary ~= 1 then return nil, 'primary_source' end
  return sources
end

function M.open(opts)
  local valid, why = validate(opts)
  if not valid then return nil, why end
  local limits = {}
  for name, ceiling in pairs(M.limits) do
    limits[name] = opts.limits and opts.limits[name] or ceiling
  end
  local identity = opts.identity
  local cap, acquire_why = invoke(opts.owner.acquire, identity)
  if not cap then return nil, 'blocked: ' .. tostring(acquire_why or 'legacy_owner_unknown') end
  local closed = false
  local lease
  local function release_all(disposition)
    if lease then pcall(lease.release, disposition) end
    pcall(opts.owner.release, cap, disposition)
    lease = nil
  end
  local checked, check_why = invoke(opts.owner.check, cap, 'open', identity)
  if not checked then
    release_all('refused')
    return nil, 'blocked: ' .. tostring(check_why or 'owner_fence')
  end
  local proof, proof_why = invoke(opts.owner.describe, cap)
  if type(proof) ~= 'table' or proof.root_id ~= identity.root_id
      or not identifier(proof.owner_id) or type(proof.epoch) ~= 'number'
      or proof.epoch < 1 or proof.epoch % 1 ~= 0 then
    release_all('refused')
    return nil, 'blocked: ' .. tostring(proof_why or 'owner_identity')
  end
  local material = identity.account_id .. '\0' .. identity.root_id .. '\0' .. identity.device_id .. '\0' .. identity.relay_id
  local store_hash, hash_why = invoke(opts.digest.sha256, material)
  if type(store_hash) ~= 'string' then
    release_all('refused')
    return nil, 'blocked: ' .. tostring(hash_why or 'identity_digest')
  end
  local store_id = 'store:' .. store_hash

  local function blocked_store(reason)
    local blocked = { blocked = reason }
    for _, name in ipairs(METHODS) do
      blocked[name] = function() return nil, 'blocked' end
    end
    blocked.close = function()
      if not closed then closed = true; release_all('blocked') end
      return true
    end
    return blocked
  end

  local open_fault = opts.faults and opts.faults('open', { identity = identity })
  if open_fault then return blocked_store('blocked: ' .. tostring(open_fault.code or 'open')) end

  -- Marker and anchor inspection are metadata-only and happen before the
  -- create-capable DB open. A missing or unreadable marker is never inferred
  -- from the database, and a malformed marker never reaches SQL.
  local anchor, anchor_why = invoke(opts.anchors.inspect)
  if type(anchor) ~= 'table' then
    return blocked_store('blocked: ' .. tostring(anchor_why or 'anchors'))
  end
  if anchor.manifest_status == 'unknown' then
    return blocked_store('blocked: manifest_unknown')
  end
  local marker, marker_why = invoke(opts.marker.read)
  if type(marker) ~= 'table' or (marker.status ~= 'missing' and marker.status ~= 'present') then
    return blocked_store('blocked: ' .. tostring(marker_why or 'marker_read'))
  end
  local parsed_marker = nil
  if marker.status == 'present' then
    parsed_marker = marker_parse(marker.raw, limits.marker_bytes)
    if not parsed_marker then return blocked_store('blocked: marker_invalid') end
    if anchor.db_exists == false then return blocked_store('blocked: marker_without_db') end
  end

  lease, why = invoke(opts.db.acquire, {
    name = 'relay', max_bytes = limits.db_bytes, timeout_ms = limits.sql_timeout_ms,
    max_rows = limits.max_rows, migrations = false,
  })
  if not lease or not lease.handle then
    return blocked_store('blocked: db_open')
  end
  local db = lease.handle
  local schema_ok, schema_why = ensure_schema(db)
  if not schema_ok then
    return blocked_store('blocked: schema')
  end
  local auth_rows, auth_why = query(db,
    'SELECT singleton,schema_version,store_id,phase,owner_id,epoch,source_stamp,' ..
      'import_verified,blocked_reason FROM relay_authority WHERE singleton=1')
  if not auth_rows then return blocked_store('blocked: ' .. tostring(auth_why)) end
  local auth = auth_rows[1]
  local state = 'unprepared'
  local active = false
  local blocked_reason
  if auth then
    if auth.store_id ~= store_id or auth.schema_version ~= 1 then
      state, blocked_reason = 'blocked', 'identity_mismatch'
    elseif auth.phase == 'blocked' then
      state, blocked_reason = 'blocked', auth.blocked_reason or 'blocked'
    elseif auth.phase == 'active' then
      if not parsed_marker or parsed_marker.store_id ~= store_id then
        state = 'not_active'
      elseif proof.epoch < auth.epoch then
        state, blocked_reason = 'blocked', 'stale_owner'
      elseif proof.epoch > auth.epoch then
        -- The root provider reports a newer verified owner. Take over only
        -- through a CAS on the old owner/epoch, then republish the marker.
        local began = begin(db)
        if not began then release_all('refused'); return nil, 'blocked: takeover_begin' end
        local changed = exec(db,
          'UPDATE relay_authority SET owner_id=?,epoch=? WHERE singleton=1 ' ..
            'AND phase=\'active\' AND store_id=? AND owner_id=? AND epoch=?',
          { proof.owner_id, proof.epoch, store_id, auth.owner_id, auth.epoch })
        if changed ~= 1 then
          rollback(db); release_all('refused'); return nil, 'blocked: takeover_cas'
        end
        local done = commit(db)
        if not done then rollback(db); release_all('refused'); return nil, 'blocked: takeover_commit' end
        local raw = marker_encode(store_id, proof.owner_id, proof.epoch, auth.source_stamp)
        local published = raw and opts.marker.publish(raw)
        if not published then
          state = 'not_active'
        else
          auth.owner_id, auth.epoch = proof.owner_id, proof.epoch
          state, active = 'active', true
        end
      elseif parsed_marker.epoch ~= auth.epoch or parsed_marker.owner_id ~= auth.owner_id then
        if proof.epoch <= auth.epoch then
          state, blocked_reason = 'blocked', 'stale_owner'
        else
          -- A verified provider takeover: advance only through a CAS on the
          -- old owner/epoch, then republish the marker for the new epoch.
          local began = begin(db)
          if not began then release_all('refused'); return nil, 'blocked: takeover_begin' end
          local changed = exec(db,
            'UPDATE relay_authority SET owner_id=?,epoch=? WHERE singleton=1 ' ..
              'AND phase=\'active\' AND store_id=? AND owner_id=? AND epoch=?',
            { proof.owner_id, proof.epoch, store_id, auth.owner_id, auth.epoch })
          if changed ~= 1 then
            rollback(db); release_all('refused'); return nil, 'blocked: takeover_cas'
          end
          local done = commit(db)
          if not done then rollback(db); release_all('refused'); return nil, 'blocked: takeover_commit' end
          local raw = marker_encode(store_id, proof.owner_id, proof.epoch, auth.source_stamp)
          local published = raw and opts.marker.publish(raw)
          if not published then
            state = 'not_active'
          else
            auth.owner_id, auth.epoch = proof.owner_id, proof.epoch
            state, active = 'active', true
          end
        end
      else
        state, active = 'active', true
      end
    elseif auth.phase == 'importing' then
      if proof.epoch < auth.epoch then
        state, blocked_reason = 'blocked', 'stale_owner'
      elseif proof.epoch > auth.epoch then
        -- A proven root-exclusive owner may rebind the importing checkpoint via
        -- owner/epoch CAS. Verified progress survives because data_revision
        -- excludes owner/epoch; the final certificate is rebound to this owner.
        local began = begin(db)
        if not began then release_all('refused'); return nil, 'blocked: takeover_begin' end
        local changed = exec(db,
          'UPDATE relay_authority SET owner_id=?,epoch=? WHERE singleton=1 ' ..
            'AND phase=\'importing\' AND store_id=? AND owner_id=? AND epoch=?',
          { proof.owner_id, proof.epoch, store_id, auth.owner_id, auth.epoch })
        if changed ~= 1 then
          rollback(db); release_all('refused'); return nil, 'blocked: takeover_cas'
        end
        local done = commit(db)
        if not done then rollback(db); release_all('refused'); return nil, 'blocked: takeover_commit' end
        auth.owner_id, auth.epoch = proof.owner_id, proof.epoch
        state = 'importing'
      elseif proof.owner_id ~= auth.owner_id then
        state, blocked_reason = 'blocked', 'stale_owner'
      else
        state = 'importing'
      end
    else
      state, blocked_reason = 'blocked', 'phase'
    end
  elseif marker.status == 'present' then
    state, blocked_reason = 'blocked', 'marker_without_authority'
  end

  local store = { closed = false, active = active, state = state,
    blocked_reason = blocked_reason, store_id = store_id,
    owner_id = auth and auth.owner_id or proof.owner_id,
    epoch = auth and auth.epoch or proof.epoch, limits = limits }
  local function current_auth()
    local rows, read_why = query(db,
      'SELECT store_id,phase,owner_id,epoch,source_stamp,import_verified,data_revision,blocked_reason ' ..
        'FROM relay_authority WHERE singleton=1')
    if not rows then return nil, read_why end
    if not rows[1] then return nil, 'unprepared' end
    return rows[1]
  end
  local function owner_ok(operation)
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = invoke(opts.owner.check, cap, operation or 'mutation', identity)
    if not ok then return nil, 'stale_writer' end
    return true
  end
  local function require_active()
    if store.closed then return nil, 'stale_writer' end
    if store.blocked_reason then return nil, 'blocked' end
    if not store.active then return nil, 'not_active' end
    return owner_ok('read')
  end
  local function writer()
    if store.closed or not store.active or store.blocked_reason then return nil, 'not_active' end
    return { store_id = store.store_id, owner_id = store.owner_id, epoch = store.epoch }
  end
  local function witness_digest(store_id, source_id, kind, role, stamp, bytes,
      raw_sha256, root_digest, chunk_size)
    local text = table.concat({ 'butler-relay-witness-v1', store_id, source_id,
      kind, role or '', stamp or '', tostring(bytes), raw_sha256,
      root_digest or '', tostring(chunk_size) }, '\0')
    return invoke(opts.digest.sha256, text)
  end

  local function lookup_witness(source_id, kind)
    local rows, why = query(db,
      'SELECT witness_id,kind,role,stamp,bytes,raw_sha256,root_digest,chunk_size ' ..
        'FROM relay_verify_witness WHERE store_id=? AND source_id=? AND kind=?',
      { store.store_id, source_id, kind })
    if not rows then return nil, why end
    return rows[1] or false
  end

  local function record_witness(source_id, kind, role, stamp, bytes, raw_sha256,
      root_digest)
    local chunk_size = limits.digest_chunk_bytes
    local witness_id, why = witness_digest(store.store_id, source_id, kind,
      role, stamp, bytes, raw_sha256, root_digest, chunk_size)
    if type(witness_id) ~= 'string' then return nil, why or 'witness_digest' end
    local existing, lookup_why = lookup_witness(source_id, kind)
    if existing == nil then return nil, lookup_why end
    if existing then
      if existing.witness_id ~= witness_id or existing.role ~= role
          or (existing.stamp or '') ~= (stamp or '')
          or existing.bytes ~= bytes or existing.raw_sha256 ~= raw_sha256
          or existing.root_digest ~= root_digest
          or existing.chunk_size ~= chunk_size then
        return nil, 'witness_conflict'
      end
      return existing.witness_id
    end
    local inserted, insert_why = exec(db,
      'INSERT INTO relay_verify_witness (witness_id,store_id,source_id,kind,' ..
        'role,stamp,bytes,raw_sha256,root_digest,chunk_size,created_at) ' ..
        'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      { witness_id, store.store_id, source_id, kind, role, stamp or '', bytes,
        raw_sha256, root_digest, chunk_size, os.date('!%Y-%m-%dT%H:%M:%SZ') })
    if inserted ~= 1 then return nil, insert_why or 'witness_conflict' end
    return witness_id
  end

  local function read_cursor()
    local rows, why = query(db, 'SELECT scope,present,value FROM relay_cursors')
    if not rows then return nil, why end
    local out = {}
    for _, row in ipairs(rows) do
      if row.present == 1 and row.value ~= '' then out[row.scope] = row.value end
    end
    return { since = out.sync, messages = out.messages }
  end
  local function cursor()
    if store.closed then
      if store.cursor_cache then return store.cursor_cache end
      return nil, 'stale_writer'
    end
    local ok, cursor_why = require_active()
    if not ok then return nil, cursor_why end
    local value, read_why = read_cursor()
    if not value then return nil, read_why end
    store.cursor_cache = value
    return value
  end
  local function operation_input(kind, parts)
    return kind .. '|' .. table.concat(parts, '|')
  end
  local function find_operation(operation_id)
    local rows, why = query(db,
      'SELECT operation_id,operation_kind,input_witness,result_json,owner_id,epoch ' ..
        'FROM relay_operations WHERE operation_id=?', { operation_id })
    if not rows then return nil, why end
    -- false means "no row"; nil means the query itself failed.
    return rows[1] or false
  end
  local function replay_operation(row)
    local value, why = decode(row.result_json)
    if value == nil then return fail('operation_result', why) end
    return value
  end
  local function cas(db_conn)
    local changes, why = exec(db_conn,
      'UPDATE relay_authority SET epoch=epoch WHERE singleton=1 AND phase=\'active\' ' ..
        'AND store_id=? AND owner_id=? AND epoch=?',
      { store.store_id, store.owner_id, store.epoch })
    if changes ~= 1 then return fail('stale_writer', why) end
    return true
  end
  local function fault(boundary, context)
    if not opts.faults then return nil end
    local value = opts.faults(boundary, context)
    if type(value) == 'table' then return value end
    return nil
  end

  function store:close()
    if closed then return true end
    closed = true
    store.closed = true
    release_all('closed')
    return true
  end
  function store:writer() return writer() end
  function store:cursor() return cursor() end

  function store:import_prepare(manifest)
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('prepare')
    if not ok then return nil, owner_why end
    if type(manifest) ~= 'table' then return fail('manifest', 'table required') end
    if manifest.legacy_owners_quiescent == false
        or manifest.external_fence_verified == false then
      return fail('legacy_owner_unknown')
    end
    if store.active then return fail('active') end
    if store.blocked_reason then return fail('blocked') end
    local sources, source_why = manifest_sources(manifest)
    if not sources then return fail('manifest', source_why) end
    local source_stamp = manifest.source_stamp or sources[1].stamp or ''
    local auth_now, auth_why = current_auth()
    if auth_now then
      if auth_now.phase == 'active' then return fail('active') end
      if auth_now.phase == 'blocked' then return fail('blocked') end
      if auth_now.source_stamp ~= source_stamp then return fail('manifest_conflict') end
      local existing, existing_why = query(db,
        'SELECT source_id,role,stamp FROM relay_manifest ORDER BY source_id')
      if not existing then return fail('manifest', existing_why) end
      if #existing ~= #sources then return fail('manifest_conflict') end
      local by_id = {}
      for _, row in ipairs(existing) do by_id[row.source_id] = row end
      for _, source in ipairs(sources) do
        local row = by_id[source.id]
        if not row or row.role ~= source.role or (row.stamp or '') ~= (source.stamp or '') then
          return fail('manifest_conflict')
        end
      end
      return true
    end
    local began = begin(db)
    if not began then return fail('manifest_begin') end
    local inserted, insert_why = exec(db,
      'INSERT INTO relay_authority (singleton,schema_version,store_id,phase,owner_id,epoch,' ..
        'source_stamp,import_verified) VALUES (1,1,?,\'importing\',?,?,?,0)',
      { store_id, store.owner_id, store.epoch, source_stamp })
    if inserted ~= 1 then rollback(db); return fail('manifest_insert', insert_why or inserted) end
    for _, source in ipairs(sources) do
      local added, add_why = exec(db,
        'INSERT INTO relay_manifest (source_id,role,stamp,marker_durability,db_durability) ' ..
          'VALUES (?,?,?,?,?)',
        { source.id, source.role, source.stamp or '', manifest.marker_durability or '',
          manifest.db_durability or '' })
      if added ~= 1 then rollback(db); return fail('manifest_insert', add_why or added) end
    end
    local done = commit(db)
    if not done then rollback(db); return fail('manifest_commit') end
    store.state = 'importing'
    return true
  end

  local function known_source(source_id)
    local rows, why = query(db,
      'SELECT source_id,role,stamp FROM relay_manifest WHERE source_id=?', { source_id })
    if not rows then return nil, why end
    if not rows[1] then return nil, 'missing:' .. tostring(#rows) end
    return rows[1]
  end

  local function add_field(source_id, path, parent_key, kind, count)
    return exec(db,
      'INSERT OR REPLACE INTO relay_source_fields (source_id,path,parent_key,kind,count) ' ..
        'VALUES (?,?,?,?,?)', { source_id, path, parent_key, kind, count })
  end

  local function add_unit(source_id, root_field, kind, parent_key, nested, expected)
    local added, why = exec(db,
      'INSERT INTO relay_import_units (source_id,root_field,kind,parent_key,nested,expected) ' ..
        'VALUES (?,?,?,?,?,?)',
      { source_id, root_field, kind, parent_key, nested, expected })
    if added ~= 1 then return nil, why end
    local rows, id_why = query(db, 'SELECT last_insert_rowid() AS id')
    if not rows then return nil, id_why end
    return rows[1].id
  end

  -- Freeze the bounded extraction order once, then import from the queue. This
  -- avoids re-scanning a 110k-element array for every 64-row page and keeps
  -- the batch query independent of source length.
  local function populate_queue(source_id, unit_id, root_field, kind, parent_key, nested)
    local path = '$.' .. root_field
    local chunk = 16384
    local offset = 0
    local total = 0
    local sql, base
    if kind == 'raw' then
      sql = 'INSERT INTO relay_import_queue (source_id,unit_id,seq,key,kind,parent_key,ordinal,payload_json) ' ..
        'SELECT ?,?,1,e.key,e.type,\'\',NULL,s.raw -> e.fullkey ' ..
        'FROM relay_import_source s,json_each(s.raw) e WHERE s.source_id=? AND e.key=?'
      local added, why = exec(db, sql, { source_id, unit_id, source_id, root_field })
      if added == nil then return nil, why end
      return added
    elseif nested == 1 then
      if kind == 'array' then
        sql = 'INSERT INTO relay_import_queue (source_id,unit_id,seq,key,kind,parent_key,ordinal,payload_json) ' ..
          'SELECT ?,?,CAST(e.key AS INTEGER)+1,e.key,e.type,?,e.key,r.value -> e.fullkey ' ..
          'FROM relay_import_source s,json_each(s.raw,?) r,json_each(r.value) e ' ..
          'WHERE s.source_id=? AND r.key=? LIMIT ? OFFSET ?'
        base = { source_id, unit_id, parent_key, path, source_id, parent_key }
      else
        sql = 'INSERT INTO relay_import_queue (source_id,unit_id,seq,key,kind,parent_key,ordinal,payload_json) ' ..
          'SELECT ?,?,? + ROW_NUMBER() OVER (ORDER BY CAST(e.key AS BLOB)),e.key,e.type,?,NULL,r.value -> e.fullkey ' ..
          'FROM relay_import_source s,json_each(s.raw,?) r,json_each(r.value) e ' ..
          'WHERE s.source_id=? AND r.key=? LIMIT ? OFFSET ?'
        base = { source_id, unit_id, offset, parent_key, path, source_id, parent_key }
      end
    elseif kind == 'array' then
      sql = 'INSERT INTO relay_import_queue (source_id,unit_id,seq,key,kind,parent_key,ordinal,payload_json) ' ..
        'SELECT ?,?,CAST(e.key AS INTEGER)+1,e.key,e.type,\'\',e.key,s.raw -> e.fullkey ' ..
        'FROM relay_import_source s,json_each(s.raw,?) e WHERE s.source_id=? LIMIT ? OFFSET ?'
      base = { source_id, unit_id, path, source_id }
    else
      sql = 'INSERT INTO relay_import_queue (source_id,unit_id,seq,key,kind,parent_key,ordinal,payload_json) ' ..
        'SELECT ?,?,? + ROW_NUMBER() OVER (ORDER BY CAST(e.key AS BLOB)),e.key,e.type,\'\',NULL,s.raw -> e.fullkey ' ..
        'FROM relay_import_source s,json_each(s.raw,?) e WHERE s.source_id=? LIMIT ? OFFSET ?'
      base = { source_id, unit_id, offset, path, source_id }
    end
    while true do
      local params = {}
      for index = 1, #base do params[index] = base[index] end
      if kind == 'array' or (nested == 1 and kind == 'array') then
        params[#params + 1] = chunk
        params[#params + 1] = offset
      else
        -- Map seq uses the current offset inside the SQL; refresh that slot.
        if kind == 'object' or (nested == 1 and kind == 'object') then
          params[#params + 1 - 2] = offset
        end
        params[#params + 1] = chunk
        params[#params + 1] = offset
      end
      local added, why = exec(db, sql, params)
      if added == nil then return nil, why end
      total = total + added
      offset = offset + added
      if added < chunk then break end
    end
    return total
  end

  function store:import_source(source_id, raw)
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('import_source')
    if not ok then return nil, owner_why end
    if store.active then return fail('active') end
    if store.blocked_reason then return fail('blocked') end
    if not identifier(source_id) or type(raw) ~= 'string' then return fail('source') end
    local hash, hash_why = source_digest(opts, raw)
    if not hash then return fail('source_digest', hash_why) end
    local existing, existing_why = query(db,
      'SELECT source_id,role,stamp,raw_sha256,bytes,status FROM relay_import_source WHERE source_id=?',
      { source_id })
    if not existing then return fail('source', existing_why) end
    if existing[1] then
      if existing[1].raw_sha256 ~= hash or existing[1].bytes ~= #raw then
        return fail('source_changed')
      end
      local witness, witness_why = lookup_witness(source_id, 'source')
      if witness == nil then return fail('source_witness', witness_why) end
      if not witness then return fail('source_witness_missing') end
      if witness.role ~= existing[1].role
          or (witness.stamp or '') ~= (existing[1].stamp or '')
          or witness.bytes ~= existing[1].bytes
          or witness.raw_sha256 ~= existing[1].raw_sha256
          or witness.chunk_size ~= limits.digest_chunk_bytes then
        return fail('witness_conflict')
      end
      return true
    end
    local declared, declared_why = known_source(source_id)
    if not declared then return fail('source_unknown', 'declared=' .. type(declared) .. ' why=' .. tostring(declared_why)) end
    if #raw > limits.source_bytes then return fail('source_too_large') end
    local root, root_why = query(db,
      'SELECT json_valid(?) AS valid,json_type(?) AS kind,length(CAST(? AS BLOB)) AS bytes',
      { raw, raw, raw })
    if not root then return fail('source', root_why) end
    if root[1].valid ~= 1 or root[1].kind ~= 'object' then return fail('root_shape') end
    local duplicates, duplicate_why = query(db,
      'SELECT count(*) AS n FROM (SELECT n.parent,n.key FROM json_tree(?) n ' ..
        'WHERE n.parent IS NOT NULL GROUP BY n.parent,n.key HAVING count(*)>1)', { raw })
    if not duplicates then return fail('source', duplicate_why) end
    if duplicates[1].n ~= 0 then return fail('duplicate_key') end
    local fields, field_why = query(db,
      'SELECT key,type,fullkey FROM json_each(?) ORDER BY CAST(key AS BLOB)', { raw })
    if not fields then return fail('source', field_why) end
    local root_by_key = {}
    for _, field in ipairs(fields) do root_by_key[field.key] = field end
    for name, expected in pairs(KNOWN) do
      local field = root_by_key[name]
      if field then
        local kind = field.type
        local valid = false
        if expected == 'scalar' then valid = kind == 'text' or kind == 'null'
        elseif expected == 'array' then valid = kind == 'array'
        elseif expected == 'map' or expected == 'nested_array' or expected == 'nested_map' then
          valid = kind == 'object'
        end
        if not valid then return fail('field_type', name) end
      end
    end
    local role = declared.role or 'primary'
    local began = begin(db)
    if not began then return fail('source_begin') end
    local inserted = exec(db,
      'INSERT INTO relay_import_source (source_id,role,stamp,raw,raw_sha256,bytes,status) ' ..
        'VALUES (?,?,?,?,?,?,?)',
      { source_id, role, declared.stamp or '', raw, hash, #raw,
        role == 'primary' and 'importing' or 'evidence' })
    if inserted ~= 1 then rollback(db); return fail('source_insert') end
    local auth_now, auth_now_why = current_auth()
    if not auth_now then rollback(db); return fail('source', auth_now_why) end
    local witness_id, witness_why = record_witness(source_id, 'source', role,
      declared.stamp or '', #raw, hash, auth_now.source_stamp)
    if not witness_id then rollback(db); return fail('witness', witness_why) end
    local root_added = add_field(source_id, '$', '', 'object', #fields)
    if root_added ~= 1 then rollback(db); return fail('source_fields') end
    for _, field in ipairs(fields) do
      local name, kind = field.key, field.type
      local path = '$.' .. name
      if name == 'since' or name == 'messages_since' then
        if role == 'primary' then
          local cursor_json, json_why = query(db, 'SELECT ? -> ? AS value', { raw, path })
          if not cursor_json then rollback(db); return fail('cursor', json_why) end
          local value_row, value_why = query(db, 'SELECT json_extract(?, ?) AS value', { raw, path })
          if not value_row then rollback(db); return fail('cursor', value_why) end
          local scope = name == 'since' and 'sync' or 'messages'
          local added = exec(db,
            'INSERT OR REPLACE INTO relay_cursors (scope,present,cursor_json,value) VALUES (?,1,?,?)',
            { scope, cursor_json[1].value, value_row[1].value or '' })
          if added ~= 1 then rollback(db); return fail('cursor') end
        end
        local field_added = add_field(source_id, path, '', kind, 1)
        if field_added ~= 1 then rollback(db); return fail('source_fields') end
      else
        local expected = KNOWN[name]
        local count = 0
        if expected == 'map' or expected == 'array'
            or expected == 'nested_array' or expected == 'nested_map' then
          local counted, count_why = query(db,
            'SELECT count(*) AS n FROM json_each(?, ?)', { raw, path })
          if not counted then rollback(db); return fail('source', count_why) end
          count = counted[1].n
          local field_added = add_field(source_id, path, '', kind, count)
          if field_added ~= 1 then rollback(db); return fail('source_fields') end
          if role == 'primary' then
            if expected == 'nested_array' or expected == 'nested_map' then
              local rooms, room_why = query(db,
                'SELECT key,type FROM json_each(?, ?) ORDER BY CAST(key AS BLOB)', { raw, path })
              if not rooms then rollback(db); return fail('source', room_why) end
              for _, room in ipairs(rooms) do
                local child_kind = expected == 'nested_array' and 'array' or 'object'
                if room.type == child_kind then
                  -- The room value is addressed by key, never by string-built
                  -- JSON path; keys are bound parameters below.
                  local row_count, count_row_why = query(db,
                    'SELECT count(*) AS n FROM json_each(?, ?) r, json_each(r.value) e ' ..
                      'WHERE r.key=?', { raw, path, room.key })
                  if not row_count then rollback(db); return fail('source', count_row_why) end
                  local n = row_count[1].n
                  local child_path = path .. '/' .. tostring(room.key)
                  local child_added = add_field(source_id, child_path, room.key, child_kind, n)
                  if child_added ~= 1 then rollback(db); return fail('source_fields') end
                  if n > 0 then
                    local unit_id, unit_why = add_unit(source_id, name, child_kind, room.key, 1, n)
                    if not unit_id then rollback(db); return fail('source_unit', unit_why) end
                  end
                end
              end
            elseif count > 0 then
              local unit_id, unit_why = add_unit(source_id, name, kind, '', 0, count)
                    if not unit_id then rollback(db); return fail('source_unit', unit_why) end
            end
          end
        else
          -- Unknown root field: retain its exact token as one bounded record.
          local field_added = add_field(source_id, path, '', kind, 1)
          if field_added ~= 1 then rollback(db); return fail('source_fields') end
          if role == 'primary' then
            local unit_id, unit_why = add_unit(source_id, name, 'raw', '', 0, 1)
                    if not unit_id then rollback(db); return fail('source_unit', unit_why) end
          end
        end
      end
    end
    local done = commit(db)
    if not done then rollback(db); return fail('source_commit') end
    return true
  end

  local function select_page(unit, source_id, remaining)
    local last = unit.last_key
    local sql, params
    if unit.kind == 'raw' then
      sql = 'WITH page AS MATERIALIZED (SELECT e.key AS key,e.type AS kind,e.fullkey AS fullkey,' ..
        's.raw -> e.fullkey AS payload FROM relay_import_source s,json_each(s.raw) e ' ..
        'WHERE s.source_id=? AND e.key=?) SELECT key,kind,payload,' ..
        'length(CAST(payload AS BLOB)) AS bytes,(SELECT count(*) FROM json_tree(payload)) AS nodes FROM page'
      params = { source_id, unit.root_field }
    elseif unit.nested == 1 then
      local condition = last == nil and '' or
        (unit.kind == 'array' and ' AND CAST(e.key AS INTEGER)>CAST(? AS INTEGER)' or
          ' AND CAST(e.key AS BLOB)>CAST(? AS BLOB)')
      sql = 'WITH page AS MATERIALIZED (SELECT e.key AS key,e.type AS kind,e.fullkey AS fullkey,' ..
        'r.value -> e.fullkey AS payload FROM relay_import_source s,' ..
        'json_each(s.raw,? ) r,json_each(r.value) e WHERE s.source_id=? AND r.key=?' ..
        condition .. (unit.kind == 'array' and '' or ' ORDER BY CAST(e.key AS BLOB)') ..
        ' LIMIT ?) SELECT key,kind,payload,json_extract(payload,\'$\') AS scalar,length(CAST(payload AS BLOB)) AS bytes,' ..
        '(SELECT count(*) FROM json_tree(payload)) AS nodes FROM page'
      params = { unit.root_field_path or ('$.' .. unit.root_field), source_id, unit.parent_key }
      if last ~= nil then params[#params + 1] = unit.kind == 'array' and tonumber(last) or last end
      params[#params + 1] = remaining
    else
      local condition = last == nil and '' or
        (unit.kind == 'array' and ' AND CAST(e.key AS INTEGER)>CAST(? AS INTEGER)' or
          ' AND CAST(e.key AS BLOB)>CAST(? AS BLOB)')
      sql = 'WITH page AS MATERIALIZED (SELECT e.key AS key,e.type AS kind,e.fullkey AS fullkey,' ..
        's.raw -> e.fullkey AS payload FROM relay_import_source s,' ..
        'json_each(s.raw,?) e WHERE s.source_id=?' .. condition ..
        (unit.kind == 'array' and '' or ' ORDER BY CAST(e.key AS BLOB)') ..
        ' LIMIT ?) SELECT key,kind,payload,json_extract(payload,\'$\') AS scalar,length(CAST(payload AS BLOB)) AS bytes,' ..
        '(SELECT count(*) FROM json_tree(payload)) AS nodes FROM page'
      params = { '$.' .. unit.root_field, source_id }
      if last ~= nil then params[#params + 1] = unit.kind == 'array' and tonumber(last) or last end
      params[#params + 1] = remaining
    end
    return query(db, sql, params)
  end

  local function insert_import_row(source_id, unit, row)
    if tonumber(row.bytes) > limits.record_bytes or tonumber(row.nodes) > limits.record_nodes then
      return fail('record_oversize')
    end
    local namespace = unit.kind == 'raw' and ('unknown:' .. unit.root_field) or unit.root_field
    local is_array = unit.kind == 'array'
    local record_key = is_array and tostring(row.key) or tostring(row.key)
    local ordinal = is_array and tonumber(row.key) or nil
    local added = exec(db,
      'INSERT OR REPLACE INTO relay_records (namespace,parent_key,record_key,ordinal,json_kind,payload_json) ' ..
        'VALUES (?,?,?,?,?,?)',
      { namespace, unit.parent_key or '', record_key, ordinal, row.kind, row.payload })
    if added ~= 1 then return fail('record_insert') end
    if unit.nested == 0 and unit.kind ~= 'raw' and unit.root_field == 'processed_event_ids' then
      if row.kind ~= 'text' then return fail('field_type', 'processed_event_ids') end
      local event_id = row.scalar
      if type(event_id) ~= 'string' or event_id == '' then return fail('processed_value') end
      local processed = exec(db,
        'INSERT OR REPLACE INTO relay_processed (source_id,ordinal,event_id) VALUES (?,?,?)',
        { source_id, ordinal, event_id })
      if processed ~= 1 then return fail('processed_insert') end
    elseif unit.nested == 0 and unit.kind ~= 'raw' and unit.root_field == 'pending_events' then
      if row.kind ~= 'object' then return fail('field_type', 'pending_events') end
      local event_id = record_key
      local room, room_why = query(db, 'SELECT json_extract(?, \'$.room_id\') AS room', { row.payload })
      if not room then return fail('event', room_why) end
      local room_id = room[1].room or ''
      -- Stable identity excludes store/epoch/process and includes account,
      -- room, event and destination; the same event imports identically
      -- across a store migration or later epoch.
      local source_key = identity.account_id .. '|' .. room_id .. '|' .. event_id .. '|butler'
      local event = exec(db,
        'INSERT OR IGNORE INTO relay_events (event_id,room_id,source_key,payload_json,state) ' ..
          'VALUES (?,?,?,?,\'pending\')',
        { event_id, room_id, source_key, row.payload })
      if event == nil then return fail('event_insert') end
      if event == 0 then
        local existing, existing_why = query(db,
          'SELECT payload_json,source_key FROM relay_events WHERE event_id=?', { event_id })
        if not existing then return fail('event', existing_why) end
        if not existing[1] or existing[1].payload_json ~= row.payload
            or existing[1].source_key ~= source_key then
          return fail('value_conflict', 'pending_events')
        end
      end
    elseif unit.nested == 0 and unit.kind ~= 'raw' and unit.root_field == 'matrix_reply_outbox' then
      if row.kind ~= 'object' then return fail('field_type', 'matrix_reply_outbox') end
      local fields, field_why = query(db,
        'SELECT json_extract(?, \'$.txn_id\') AS txn,' ..
          ' json_extract(?, \'$.attempts\') AS attempts', { row.payload, row.payload })
      if not fields then return fail('outbox', field_why) end
      local txn = fields[1].txn
      if txn ~= nil and (type(txn) ~= 'string' or txn == '') then txn = nil end
      local attempts = intent_attempts(fields[1].attempts)
      local inserted = exec(db,
        'INSERT OR REPLACE INTO relay_reply_intents ' ..
          '(reply_id,txn_id,state,attempts,payload_json,owner_id,epoch,imported) ' ..
          'VALUES (?,?,\'uncertain\',?,?,?,?,1)',
        { record_key, txn, attempts, row.payload, store.owner_id, store.epoch })
      if inserted ~= 1 then return fail('reply_intent') end
    end
    return true
  end

  local function select_queue(unit, source_id, remaining)
    return query(db,
      'SELECT key,kind,payload_json AS payload,json_extract(payload_json,\'$\') AS scalar,' ..
        'length(CAST(payload_json AS BLOB)) AS bytes,' ..
        '(SELECT count(*) FROM json_tree(payload_json)) AS nodes ' ..
        'FROM relay_import_queue WHERE source_id=? AND unit_id=? AND seq>? ' ..
        'ORDER BY seq LIMIT ?',
      { source_id, unit.unit_id, tonumber(unit.last_seq) or 0, remaining })
  end

  function store:import_batch(source_id, limit)
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('import_batch')
    if not ok then return nil, owner_why end
    if store.active then return fail('active') end
    if store.blocked_reason then return fail('blocked') end
    if type(limit) ~= 'number' or limit < 1 or limit > limits.page_rows or limit % 1 ~= 0 then
      return fail('batch_limit')
    end
    local source, source_why = query(db,
      'SELECT source_id,role,status,staged_count FROM relay_import_source WHERE source_id=?',
      { source_id })
    if not source then return fail('source', source_why) end
    if not source[1] then return fail('source_unknown') end
    if source[1].role ~= 'primary' then return { count = 0, done = true } end
    if source[1].status == 'blocked' then return fail('blocked') end
    if source[1].status == 'verified' then return { count = 0, done = true } end
    local began = begin(db)
    if not began then return fail('batch_begin') end
    local total = 0
    local remaining = limit
    while remaining > 0 do
      local units, unit_why = query(db,
        'SELECT unit_id,source_id,root_field,kind,parent_key,nested,expected,done,last_key,last_seq ' ..
          'FROM relay_import_units WHERE source_id=? AND done=0 ORDER BY unit_id LIMIT 1',
        { source_id })
      if not units then rollback(db); return fail('batch_unit', unit_why) end
      local unit = units[1]
      if not unit then break end
      local requested = remaining
      local rows, page_why = select_page(unit, source_id, requested)
      if not rows then rollback(db); return fail('batch_page', page_why) end
      if #rows == 0 then
        local done = exec(db,
          'UPDATE relay_import_units SET done=1 WHERE unit_id=?', { unit.unit_id })
        if done ~= 1 then rollback(db); return fail('batch_unit') end
      else
        for _, row in ipairs(rows) do
          local inserted, insert_why = insert_import_row(source_id, unit, row)
          if not inserted then
            rollback(db)
            pcall(exec, db, 'UPDATE relay_import_source SET status=\'blocked\' WHERE source_id=?',
              { source_id })
            return fail(insert_why)
          end
        end
        total = total + #rows
        remaining = remaining - #rows
        local last = tostring(rows[#rows].key)
        -- A raw unit holds one exact token; it is complete even when its row
        -- filled the remaining batch budget, so it must not be re-read.
        local done = (#rows < requested or unit.kind == 'raw') and 1 or 0
        -- A short page is the last page. A full page stays resumable; the
        -- next call observes an empty page and closes the unit.
        local update = exec(db,
          'UPDATE relay_import_units SET last_key=?,done=? WHERE unit_id=?',
          { last, done, unit.unit_id })
        if update ~= 1 then rollback(db); return fail('batch_unit') end
      end
    end
    local pending, pending_why = query(db,
      'SELECT count(*) AS n FROM relay_import_units WHERE source_id=? AND done=0', { source_id })
    if not pending then rollback(db); return fail('batch_unit', pending_why) end
    local updated = exec(db,
      'UPDATE relay_import_source SET staged_count=staged_count+?,status=? WHERE source_id=?',
      { total, pending[1].n == 0 and 'staged' or 'importing', source_id })
    if updated ~= 1 then rollback(db); return fail('batch_count') end
    local done = commit(db)
    if not done then rollback(db); return fail('batch_commit') end
    return { count = total, done = pending[1].n == 0 }
  end

  function store:import_acks(source_id, raw, stamp)
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('import_acks')
    if not ok then return nil, owner_why end
    if store.active then return fail('active') end
    if store.blocked_reason then return fail('blocked') end
    if not identifier(source_id) or type(raw) ~= 'string' then return fail('sidecar') end
    if #raw > limits.source_bytes then return fail('sidecar_too_large') end
    local hash, hash_why = source_digest(opts, raw)
    if not hash then return fail('sidecar_digest', hash_why) end
    local existing, existing_why = query(db,
      'SELECT raw_sha256,stamp FROM relay_sidecar WHERE source_id=? AND kind=\'acks\'', { source_id })
    if not existing then return fail('sidecar', existing_why) end
    if existing[1] and existing[1].raw_sha256 ~= hash then return fail('source_changed') end
    if existing[1] then
      local witness, witness_why = lookup_witness(source_id, 'sidecar')
      if witness == nil then return fail('sidecar_witness', witness_why) end
      if not witness then return fail('source_witness_missing') end
      if witness.raw_sha256 ~= existing[1].raw_sha256
          or (witness.stamp or '') ~= (existing[1].stamp or '')
          or witness.chunk_size ~= limits.digest_chunk_bytes then
        return fail('witness_conflict')
      end
    end
    local began = begin(db)
    if not began then return fail('sidecar_begin') end
    if not existing[1] then
      local auth_now, auth_now_why = current_auth()
      if not auth_now then rollback(db); return fail('sidecar', auth_now_why) end
      local witness_id, witness_why = record_witness(source_id, 'sidecar', source_id,
        stamp or '', #raw, hash, auth_now.source_stamp)
      if not witness_id then rollback(db); return fail('witness', witness_why) end
    end
    local sidecar = exec(db,
      'INSERT OR REPLACE INTO relay_sidecar (source_id,kind,raw,raw_sha256,stamp) ' ..
        'VALUES (?,?,?,?,?)', { source_id, 'acks', raw, hash, stamp or '' })
    if sidecar ~= 1 then rollback(db); return fail('sidecar_insert') end
    for id in (raw .. '\n'):gmatch('(.-)\n') do
      id = id:gsub('\r$', '')
      if id ~= '' then
        local event, event_why = query(db,
          'SELECT state FROM relay_events WHERE event_id=?', { id })
        if not event then rollback(db); return fail('sidecar', event_why) end
        if event[1] then
          if event[1].state == 'pending' then
            local changed = exec(db,
              'UPDATE relay_events SET state=\'delivered\' WHERE event_id=? AND state=\'pending\'',
              { id })
            if changed ~= 1 then rollback(db); return fail('sidecar_ack') end
          end
        else
          local processed, processed_why = query(db,
            'SELECT 1 AS present FROM relay_processed WHERE event_id=? LIMIT 1', { id })
          if not processed then rollback(db); return fail('sidecar', processed_why) end
          if not processed[1] then rollback(db); return fail('ack_unknown', id) end
        end
      end
    end
    local done = commit(db)
    if not done then rollback(db); return fail('sidecar_commit') end
    return true
  end

  local function primary_source()
    local rows, why = query(db,
      'SELECT source_id,status,staged_count FROM relay_import_source WHERE role=\'primary\' ' ..
        'ORDER BY source_id LIMIT 1')
    if not rows then return nil, why end
    return rows[1]
  end

  -- Metadata-only planning never returns record payload to Lua. The bounded
  -- prefix is then checked by an exact SQL join that returns only counts.
  local function verify_source_meta(unit, source_id, after, limit)
    local path = '$.' .. unit.root_field
    local payload, from, params
    if unit.kind == 'raw' then
      from = 'FROM relay_import_source s,json_each(s.raw) e WHERE s.source_id=? AND e.key=?'
      payload = 's.raw -> e.fullkey'
      params = { source_id, unit.root_field }
    elseif unit.nested == 1 then
      from = 'FROM relay_import_source s,json_each(s.raw,?) r,json_each(r.value) e ' ..
        'WHERE s.source_id=? AND r.key=?'
      payload = 'r.value -> e.fullkey'
      params = { path, source_id, unit.parent_key }
    else
      from = 'FROM relay_import_source s,json_each(s.raw,?) e WHERE s.source_id=?'
      payload = 's.raw -> e.fullkey'
      params = { path, source_id }
    end
    local condition = ''
    if unit.kind ~= 'raw' and after ~= nil then
      if unit.kind == 'array' then
        condition = ' AND CAST(e.key AS INTEGER)>CAST(? AS INTEGER)'
      else
        condition = ' AND CAST(e.key AS BLOB)>CAST(? AS BLOB)'
      end
      params[#params + 1] = after
    end
    local order = unit.kind == 'array' and '' or ' ORDER BY CAST(e.key AS BLOB)'
    local sql = 'SELECT e.key AS key,e.type AS kind,' ..
      'length(CAST(' .. payload .. ' AS BLOB)) AS bytes ' ..
      from .. condition .. order .. ' LIMIT ?'
    params[#params + 1] = limit
    return query(db, sql, params)
  end

  -- Node counts are computed only for the byte prefix that already fits the
  -- call budget, never for all 64 candidate rows.
  local function verify_source_nodes(unit, source_id, after, limit)
    local path = '$.' .. unit.root_field
    local payload, from, params
    if unit.kind == 'raw' then
      from = 'FROM relay_import_source s,json_each(s.raw) e WHERE s.source_id=? AND e.key=?'
      payload = 's.raw -> e.fullkey'
      params = { source_id, unit.root_field }
    elseif unit.nested == 1 then
      from = 'FROM relay_import_source s,json_each(s.raw,?) r,json_each(r.value) e ' ..
        'WHERE s.source_id=? AND r.key=?'
      payload = 'r.value -> e.fullkey'
      params = { path, source_id, unit.parent_key }
    else
      from = 'FROM relay_import_source s,json_each(s.raw,?) e WHERE s.source_id=?'
      payload = 's.raw -> e.fullkey'
      params = { path, source_id }
    end
    local condition = ''
    if unit.kind ~= 'raw' and after ~= nil then
      if unit.kind == 'array' then
        condition = ' AND CAST(e.key AS INTEGER)>CAST(? AS INTEGER)'
      else
        condition = ' AND CAST(e.key AS BLOB)>CAST(? AS BLOB)'
      end
      params[#params + 1] = after
    end
    local order = unit.kind == 'array' and '' or ' ORDER BY CAST(e.key AS BLOB)'
    local sql = 'WITH src AS MATERIALIZED (SELECT e.key AS key,' .. payload ..
      ' AS payload ' .. from .. condition .. order .. ' LIMIT ?) ' ..
      'SELECT key,(SELECT count(*) FROM json_tree(payload)) AS nodes FROM src'
    params[#params + 1] = limit
    return query(db, sql, params)
  end

  local function verify_source_prefix(unit, source_id, after, limit)
    local path = '$.' .. unit.root_field
    local payload, from, params
    if unit.kind == 'raw' then
      from = 'FROM relay_import_source s,json_each(s.raw) e WHERE s.source_id=? AND e.key=?'
      payload = 's.raw -> e.fullkey'
      params = { source_id, unit.root_field }
    elseif unit.nested == 1 then
      from = 'FROM relay_import_source s,json_each(s.raw,?) r,json_each(r.value) e ' ..
        'WHERE s.source_id=? AND r.key=?'
      payload = 'r.value -> e.fullkey'
      params = { path, source_id, unit.parent_key }
    else
      from = 'FROM relay_import_source s,json_each(s.raw,?) e WHERE s.source_id=?'
      payload = 's.raw -> e.fullkey'
      params = { path, source_id }
    end
    local condition = ''
    if unit.kind ~= 'raw' and after ~= nil then
      if unit.kind == 'array' then
        condition = ' AND CAST(e.key AS INTEGER)>CAST(? AS INTEGER)'
      else
        condition = ' AND CAST(e.key AS BLOB)>CAST(? AS BLOB)'
      end
      params[#params + 1] = after
    end
    local order = unit.kind == 'array' and '' or ' ORDER BY CAST(e.key AS BLOB)'
    local record_key = unit.kind == 'array' and 'CAST(src.key AS TEXT)' or 'src.key'
    local sql = 'WITH src AS MATERIALIZED (SELECT e.key AS key,e.type AS kind,' ..
      payload .. ' AS payload ' .. from .. condition .. order .. ' LIMIT ?) ' ..
      'SELECT count(*) AS n,COALESCE(sum(CASE WHEN ' ..
      'r.record_key IS NULL OR r.json_kind<>src.kind OR r.payload_json<>src.payload ' ..
      'OR (?=\'array\' AND (r.ordinal IS NULL OR CAST(r.ordinal AS TEXT)<>CAST(src.key AS TEXT))) ' ..
      'OR (?=\'object\' AND r.ordinal IS NOT NULL) THEN 1 ELSE 0 END),0) AS bad ' ..
      'FROM src LEFT JOIN relay_records r ON r.namespace=? AND r.parent_key=? ' ..
      'AND r.record_key=' .. record_key
    params[#params + 1] = limit
    params[#params + 1] = unit.kind
    params[#params + 1] = unit.kind
    params[#params + 1] = (unit.kind == 'raw' and ('unknown:' .. unit.root_field) or unit.root_field)
    params[#params + 1] = unit.parent_key or ''
    return query(db, sql, params)
  end

  local function witness_inputs()
    local sources, source_why = query(db,
      'SELECT source_id,role,stamp,bytes,raw_sha256 FROM relay_import_source ' ..
        'ORDER BY CASE WHEN role=\'primary\' THEN 0 ELSE 1 END,source_id')
    if not sources then return nil, source_why end
    local inputs = {}
    for _, source in ipairs(sources) do
      if source.role == 'primary' or source.role == 'backup_evidence' then
        inputs[#inputs + 1] = { kind = 'source', source_id = source.source_id,
          role = source.role, stamp = source.stamp or '',
          bytes = tonumber(source.bytes) or 0, raw_sha256 = source.raw_sha256 }
      end
    end
    local sidecars, sidecar_why = query(db,
      'SELECT source_id,kind,stamp,raw_sha256,length(CAST(raw AS BLOB)) AS bytes ' ..
        'FROM relay_sidecar ORDER BY source_id,kind')
    if not sidecars then return nil, sidecar_why end
    for _, sidecar in ipairs(sidecars) do
      inputs[#inputs + 1] = { kind = 'sidecar', source_id = sidecar.source_id,
        role = sidecar.source_id, stamp = sidecar.stamp or '',
        bytes = tonumber(sidecar.bytes) or 0, raw_sha256 = sidecar.raw_sha256,
        sidecar_kind = sidecar.kind }
    end
    return inputs
  end

  local function manifest_membership()
    local manifest, manifest_why = query(db,
      'SELECT source_id,role,stamp FROM relay_manifest ORDER BY source_id')
    if not manifest then return nil, manifest_why end
    local sources, source_why = query(db,
      'SELECT source_id,role,stamp FROM relay_import_source ORDER BY source_id')
    if not sources then return nil, source_why end
    if #manifest ~= #sources then return nil, 'manifest_membership' end
    for index, row in ipairs(manifest) do
      local source = sources[index]
      if not source or source.source_id ~= row.source_id or source.role ~= row.role
          or (source.stamp or '') ~= (row.stamp or '') then
        return nil, 'manifest_membership'
      end
    end
    return true
  end

  local function witness_chunk(input, offset, chunk_size)
    local sql, params
    if input.kind == 'source' then
      sql = 'SELECT substr(CAST(raw AS BLOB),?,?) AS chunk,' ..
        'length(CAST(raw AS BLOB)) AS bytes FROM relay_import_source WHERE source_id=?'
      params = { offset + 1, chunk_size, input.source_id }
    else
      sql = 'SELECT substr(CAST(raw AS BLOB),?,?) AS chunk,' ..
        'length(CAST(raw AS BLOB)) AS bytes FROM relay_sidecar ' ..
        'WHERE source_id=? AND kind=?'
      params = { offset + 1, chunk_size, input.source_id, input.sidecar_kind }
    end
    local rows, why = query(db, sql, params)
    if not rows then return nil, why end
    if not rows[1] or rows[1].chunk == nil then return nil, 'source_changed' end
    return rows[1].chunk, tonumber(rows[1].bytes) or 0
  end

  -- Every retained sealed baseline must still have its live original. This is
  -- the sealed-baseline -> source reverse direction; deleting both the manifest
  -- and import_source rows must not drop a witnessed original from the proof.
  local function sealed_witness_ok(witness)
    if witness.kind == 'source' then
      local live, live_why = query(db,
        'SELECT role,stamp,bytes,raw_sha256 FROM relay_import_source WHERE source_id=?',
        { witness.source_id })
      if not live then return nil, live_why end
      local source = live[1]
      if not source or source.role ~= witness.role
          or (source.stamp or '') ~= (witness.stamp or '')
          or tonumber(source.bytes) ~= tonumber(witness.bytes)
          or source.raw_sha256 ~= witness.raw_sha256 then
        return nil, 'source_missing:' .. witness.source_id
      end
      local manifest, manifest_why = query(db,
        'SELECT role,stamp FROM relay_manifest WHERE source_id=?', { witness.source_id })
      if not manifest then return nil, manifest_why end
      if not manifest[1] or manifest[1].role ~= witness.role
          or (manifest[1].stamp or '') ~= (witness.stamp or '') then
        return nil, 'manifest_missing:' .. witness.source_id
      end
    else
      local live, live_why = query(db,
        'SELECT 1 AS ok FROM relay_sidecar WHERE source_id=? AND raw_sha256=? LIMIT 1',
        { witness.source_id, witness.raw_sha256 })
      if not live then return nil, live_why end
      if not live[1] then return nil, 'sidecar_missing:' .. witness.source_id end
    end
    return true
  end

  -- Sealed-baseline -> source reverse, one witness per call.
  local function sealed_step(p)
    local cursor = p.phase_cursor and decode(p.phase_cursor) or nil
    if type(cursor) ~= 'table' or cursor.task ~= 'sealed' then
      return fail('witness_state')
    end
    local sql = 'SELECT source_id,kind,role,stamp,bytes,raw_sha256 ' ..
      'FROM relay_verify_witness WHERE store_id=?'
    local params = { store.store_id }
    if cursor.started then
      sql = sql .. ' AND (source_id,kind)>(?,?)'
      params[#params + 1] = cursor.source_id or ''
      params[#params + 1] = cursor.kind or ''
    end
    sql = sql .. ' ORDER BY source_id,kind LIMIT 1'
    local rows, why = query(db, sql, params)
    if not rows then return fail('witness', why) end
    if rows[1] then
      local ok, witness_why = sealed_witness_ok(rows[1])
      if not ok then return fail('import_incomplete', witness_why) end
      p.phase_cursor = encode({ task = 'sealed', started = true,
        source_id = rows[1].source_id, kind = rows[1].kind })
      return { count = 0 }
    end
    p.phase, p.phase_cursor = 'source_rows', encode({ task = 'keys' })
    p.unit_id, p.cursor = nil, nil
    p.processed_rows, p.bytes, p.nodes = 0, 0, 0
    return { count = 0 }
  end

  -- WITNESS is a persisted one-chunk-per-call rehash. It never inserts or
  -- replaces a baseline; a missing baseline refuses the unsealed source.
  local function witness_step(p, auth, max_bytes)
    local inputs, input_why = witness_inputs()
    if not inputs then return fail('witness', input_why) end
    local membership, membership_why = manifest_membership()
    if not membership then return fail('import_incomplete', membership_why) end
    local cursor = p.phase_cursor and decode(p.phase_cursor) or nil
    if type(cursor) == 'table' and cursor.task == 'sealed' then
      return sealed_step(p)
    end
    if type(cursor) ~= 'table' then cursor = { index = 1, offset = 0, chunks = '' } end
    local index, offset, chunks = tonumber(cursor.index) or 1,
      tonumber(cursor.offset) or 0, cursor.chunks or ''
    if index > #inputs then
      local primary
      for _, input in ipairs(inputs) do
        if input.kind == 'source' and input.role == 'primary' then primary = input; break end
      end
      local witness = primary and lookup_witness(primary.source_id, 'source')
      if not primary or not witness then return fail('source_witness_missing') end
      p.witness_id = witness.witness_id
      p.phase_cursor = encode({ task = 'sealed' })
      return { count = 0 }
    end
    local input = inputs[index]
    local witness, witness_why = lookup_witness(input.source_id, input.kind)
    if witness == nil then return fail('witness', witness_why) end
    if not witness then return fail('source_witness_missing') end
    local expected_kind = input.kind == 'source' and 'source' or 'sidecar'
    if witness.witness_id == nil or witness.role ~= input.role
        or (witness.stamp or '') ~= (input.stamp or '')
        or witness.bytes ~= input.bytes or witness.raw_sha256 ~= input.raw_sha256
        or witness.root_digest ~= auth.source_stamp
        or witness.kind ~= expected_kind then
      return fail('source_changed')
    end
    local chunk_size = tonumber(witness.chunk_size) or limits.digest_chunk_bytes
    if chunk_size < 1 or chunk_size > limits.digest_chunk_bytes then
      return fail('witness_chunk')
    end
    if input.bytes == 0 then
      local final_input = 'butler-relay-source-v1\0' .. '0\0'
      local digest, digest_why = invoke(opts.digest.sha256, final_input)
      if type(digest) ~= 'string' then return fail('witness_digest', digest_why) end
      if digest ~= witness.raw_sha256 then return fail('source_changed') end
      p.phase_cursor = encode({ index = index + 1, offset = 0, chunks = '' })
      return { count = 0, bytes = 0 }
    end
    if offset < input.bytes and max_bytes < chunk_size then
      return fail('budget_too_small')
    end
    local want = math.min(chunk_size, input.bytes - offset)
    if want > max_bytes then want = max_bytes end
    if want < 1 then
      return fail('witness_progress')
    end
    local chunk, current_bytes = witness_chunk(input, offset, want)
    if not chunk then return fail('source_changed', current_bytes) end
    if current_bytes ~= input.bytes then return fail('source_changed') end
    if #chunk ~= want then return fail('source_changed') end
    local hex, hex_why = invoke(opts.digest.sha256, chunk)
    if type(hex) ~= 'string' then return fail('witness_digest', hex_why) end
    if #chunks + #hex > 32768 then return fail('digest_budget') end
    offset = offset + #chunk
    chunks = chunks .. hex
    if offset < input.bytes then
      p.phase_cursor = encode({ index = index, offset = offset, chunks = chunks })
      return { count = 0, bytes = #chunk }
    end
    local final_input = 'butler-relay-source-v1\0' .. tostring(input.bytes) .. '\0' .. chunks
    if #final_input > 65536 then return fail('digest_budget') end
    local digest, digest_why = invoke(opts.digest.sha256, final_input)
    if type(digest) ~= 'string' then return fail('witness_digest', digest_why) end
    if digest ~= witness.raw_sha256 then return fail('source_changed') end
    p.phase_cursor = encode({ index = index + 1, offset = 0, chunks = '' })
    return { count = 0, bytes = #chunk }
  end

  local function source_field_matches(primary, path, parent_key, kind, count)
    local rows, why = query(db,
      'SELECT kind,count,parent_key FROM relay_source_fields ' ..
        'WHERE source_id=? AND path=? AND parent_key=?',
      { primary.source_id, path, parent_key or '' })
    if not rows then return nil, why end
    local row = rows[1]
    if not row then return nil, 'field_missing:' .. path end
    if row.kind ~= kind then return nil, 'field_kind:' .. path end
    if tonumber(row.count) ~= count then return nil, 'field_count:' .. path end
    return true
  end

  local function source_unit_matches(primary, root_field, kind, parent_key, nested, expected)
    local rows, why = query(db,
      'SELECT count(*) AS n FROM relay_import_units WHERE source_id=? AND root_field=? ' ..
        'AND kind=? AND parent_key=? AND nested=? AND expected=?',
      { primary.source_id, root_field, kind, parent_key or '', nested, expected })
    if not rows then return nil, why end
    local n = tonumber(rows[1].n) or 0
    if n ~= 1 then
      return nil, 'unit_missing:' .. root_field .. '/' .. tostring(parent_key or '') ..
        '/' .. tostring(n)
    end
    return true
  end

  -- Original-source domain coverage, paged over json_each with a bounded key
  -- cursor. Every original root key must have its exact source field, and
  -- every original nonempty collection must have its exact import unit. Stored
  -- units/fields are not trusted to enumerate themselves.
  local function domain_step(p, primary, max_rows)
    local cursor = p.phase_cursor and decode(p.phase_cursor) or nil
    if type(cursor) ~= 'table' then cursor = { task = 'keys' } end
    if cursor.task == 'rooms' then
      local parent = cursor.parent
      local expected_kind = KNOWN[parent] == 'nested_array' and 'array' or 'object'
      local sql = 'SELECT e.key AS room_key,e.type AS room_kind,' ..
        'CASE WHEN e.type IN (\'object\',\'array\') ' ..
        'THEN (SELECT count(*) FROM json_each(e.value)) ELSE 0 END AS children ' ..
        'FROM relay_import_source s,json_each(s.raw) p,json_each(p.value) e ' ..
        'WHERE s.source_id=? AND p.key=?'
      local params = { primary.source_id, parent }
      if cursor.started then
        sql = sql .. ' AND CAST(e.key AS BLOB)>CAST(? AS BLOB)'
        params[#params + 1] = cursor.room_key or ''
      end
      sql = sql .. ' ORDER BY CAST(e.key AS BLOB) LIMIT 1'
      local rows, why = query(db, sql, params)
      if not rows then return fail('domain', why) end
      for _, row in ipairs(rows) do
        if row.room_kind == expected_kind then
          local n = tonumber(row.children) or 0
          local path = '$.' .. parent .. '/' .. tostring(row.room_key)
          local field_ok, field_why = source_field_matches(primary, path,
            row.room_key, expected_kind, n)
          if not field_ok then return fail('import_incomplete', field_why) end
          if n > 0 then
            local unit_ok, unit_why = source_unit_matches(primary, parent,
              expected_kind, row.room_key, 1, n)
            if not unit_ok then return fail('import_incomplete', unit_why) end
          end
        end
      end
      if #rows == 1 then
        p.phase_cursor = encode({ task = 'rooms', parent = parent, started = true,
          room_key = rows[#rows].room_key })
      else
        p.phase_cursor = encode({ task = 'keys', started = true, key = parent })
      end
      return { count = #rows }
    end
    if cursor.task ~= 'keys' then return fail('domain_state') end
    local sql = 'SELECT e.key AS key,e.type AS kind,' ..
      'CASE WHEN e.type IN (\'object\',\'array\') ' ..
      'THEN (SELECT count(*) FROM json_each(e.value)) ELSE 0 END AS children ' ..
      'FROM relay_import_source s,json_each(s.raw) e WHERE s.source_id=?'
    local params = { primary.source_id }
    if cursor.started then
      sql = sql .. ' AND CAST(e.key AS BLOB)>CAST(? AS BLOB)'
      params[#params + 1] = cursor.key or ''
    end
    sql = sql .. ' ORDER BY CAST(e.key AS BLOB) LIMIT 1'
    local rows, why = query(db, sql, params)
    if not rows then return fail('domain', why) end
    for _, row in ipairs(rows) do
      local name, kind = row.key, row.kind
      local n = tonumber(row.children) or 0
      local path = '$.' .. name
      local expected = KNOWN[name]
      if expected == nil then
        local field_ok, field_why = source_field_matches(primary, path, '', kind, 1)
        if not field_ok then return fail('import_incomplete', field_why) end
        local unit_ok, unit_why = source_unit_matches(primary, name, 'raw', '', 0, 1)
        if not unit_ok then return fail('import_incomplete', unit_why) end
      elseif expected == 'scalar' then
        local field_ok, field_why = source_field_matches(primary, path, '', kind, 1)
        if not field_ok then return fail('import_incomplete', field_why) end
      elseif expected == 'array' or expected == 'map' then
        local field_ok, field_why = source_field_matches(primary, path, '', kind, n)
        if not field_ok then return fail('import_incomplete', field_why) end
        if n > 0 then
          local unit_ok, unit_why = source_unit_matches(primary, name, kind, '', 0, n)
          if not unit_ok then return fail('import_incomplete', unit_why) end
        end
      else
        local field_ok, field_why = source_field_matches(primary, path, '', kind, n)
        if not field_ok then return fail('import_incomplete', field_why) end
        if n > 0 then
          p.phase_cursor = encode({ task = 'rooms', parent = name })
          return { count = #rows }
        end
      end
    end
    if #rows == 1 then
      p.phase_cursor = encode({ task = 'keys', started = true, key = rows[#rows].key })
    else
      p.phase_cursor = encode({ task = 'cursors' })
    end
    return { count = #rows }
  end

  local function cursor_parity(primary)
    local scopes = { { scope = 'sync', path = '$.since' },
      { scope = 'messages', path = '$.messages_since' } }
    for _, item in ipairs(scopes) do
      local source, why = query(db,
        'SELECT json_type(raw,?) AS kind,raw->? AS token,json_extract(raw,?) AS value ' ..
          'FROM relay_import_source WHERE source_id=?', { item.path, item.path, item.path, primary.source_id })
      if not source then return nil, why end
      local row, row_why = query(db,
        'SELECT scope,present,cursor_json,value FROM relay_cursors WHERE scope=?', { item.scope })
      if not row then return nil, row_why end
      local present = source[1] and source[1].kind ~= nil
      if present then
        if not row[1] or tonumber(row[1].present) ~= 1
            or row[1].cursor_json ~= source[1].token
            or (row[1].value or '') ~= (source[1].value or '') then
          return nil, 'cursor'
        end
      elseif row[1] then
        return nil, 'cursor'
      end
    end
    local extra, extra_why = query(db,
      'SELECT scope FROM relay_cursors WHERE scope NOT IN (\'sync\',\'messages\')')
    if not extra then return nil, extra_why end
    if #extra ~= 0 then return nil, 'cursor' end
    return true
  end

  local function structure_unit_ok(primary, unit)
    local path = '$.' .. unit.root_field
    local expected = tonumber(unit.expected) or 0
    if expected < 1 then return nil, 'unit' end
    local domain = KNOWN[unit.root_field]
    if unit.kind == 'raw' then
      if domain ~= nil or expected ~= 1 or (unit.parent_key or '') ~= ''
          or tonumber(unit.nested) ~= 0 then return nil, 'unit' end
      local field, field_why = query(db,
        'SELECT type FROM relay_import_source s,json_each(s.raw) e ' ..
          'WHERE s.source_id=? AND e.key=?', { primary.source_id, unit.root_field })
      if not field then return nil, field_why end
      if not field[1] then return nil, 'unit' end
    elseif unit.nested == 1 then
      local child_kind = domain == 'nested_array' and 'array'
        or (domain == 'nested_map' and 'object' or nil)
      if not child_kind or unit.kind ~= child_kind then return nil, 'unit' end
      local parent, parent_why = query(db,
        'SELECT count(*) AS n FROM relay_import_source s,json_each(s.raw,?) r,' ..
          'json_each(r.value) e WHERE s.source_id=? AND r.key=? AND r.type=?',
        { path, primary.source_id, unit.parent_key, child_kind })
      if not parent then return nil, parent_why end
      if not parent[1] or tonumber(parent[1].n) ~= expected then return nil, 'unit' end
    else
      local root_kind = domain == 'array' and 'array'
        or (domain == 'map' and 'object' or nil)
      if not root_kind or unit.kind ~= root_kind
          or (unit.parent_key or '') ~= '' then return nil, 'unit' end
      local counted, count_why = query(db,
        'SELECT count(*) AS n FROM relay_import_source s,json_each(s.raw,?) e ' ..
          'WHERE s.source_id=?', { path, primary.source_id })
      if not counted then return nil, count_why end
      if tonumber(counted[1].n) ~= expected then return nil, 'unit' end
    end
    return true
  end

  local function top_field_ok(primary, name, kind, count)
    local domain = KNOWN[name]
    local sql = 'SELECT e.type AS kind,' ..
      'CASE WHEN e.type IN (\'object\',\'array\') ' ..
      'THEN (SELECT count(*) FROM json_each(e.value)) ELSE 0 END AS n ' ..
      'FROM relay_import_source s,json_each(s.raw) e ' ..
      'WHERE s.source_id=? AND e.key=?'
    local actual, why = query(db, sql, { primary.source_id, name })
    if not actual then return nil, why end
    if not actual[1] then return false end
    local expected = 1
    if domain == 'array' or domain == 'map'
        or domain == 'nested_array' or domain == 'nested_map' then
      expected = tonumber(actual[1].n) or 0
    end
    return actual[1].kind == kind and expected == tonumber(count)
  end

  local function child_field_ok(primary, path, parent_key, kind, count)
    local slash = path:find('/', 3, true)
    if not slash then return false end
    local root = path:sub(3, slash - 1)
    local room = path:sub(slash + 1)
    if KNOWN[root] ~= 'nested_array' and KNOWN[root] ~= 'nested_map' then
      return false
    end
    if room ~= (parent_key or '') then return false end
    local actual, why = query(db,
      'SELECT r.type AS kind,' ..
        'CASE WHEN r.type IN (\'object\',\'array\') ' ..
        'THEN (SELECT count(*) FROM json_each(r.value)) ELSE 0 END AS n ' ..
        'FROM relay_import_source s,json_each(s.raw) p,json_each(p.value) r ' ..
        'WHERE s.source_id=? AND p.key=? AND r.key=?',
      { primary.source_id, root, room })
    if not actual then return nil, why end
    if not actual[1] or actual[1].kind ~= kind then return false end
    return tonumber(actual[1].n) == tonumber(count)
  end

  -- A stored field must have exactly one canonical interpretation against the
  -- original raw: top-level (parent='') or nested child (parent=room). A literal
  -- '/' in a valid top-level unknown key is therefore not an alias.
  local function structure_field_ok(primary, field)
    local path = field.path
    if path ~= '$' and path:sub(1, 2) ~= '$.' then return nil, 'field' end
    local parent_key = field.parent_key or ''
    if path == '$' then
      if parent_key ~= '' or field.kind ~= 'object' then return nil, 'field' end
      local counted, count_why = query(db,
        'SELECT count(*) AS n FROM relay_import_source s,json_each(s.raw) e WHERE s.source_id=?',
        { primary.source_id })
      if not counted then return nil, count_why end
      if tonumber(counted[1].n) ~= tonumber(field.count) then return nil, 'field' end
      return true
    end
    local matches = 0
    if parent_key == '' then
      local top, top_why = top_field_ok(primary, path:sub(3), field.kind, field.count)
      if top == nil then return nil, top_why end
      if top then matches = matches + 1 end
    end
    local child, child_why = child_field_ok(primary, path, parent_key,
      field.kind, field.count)
    if child == nil then return nil, child_why end
    if child then matches = matches + 1 end
    if matches ~= 1 then return nil, 'field' end
    return true
  end

  -- Structure parity is paged with the same bounded cursor: units then fields.
  -- It proves stored units/fields map back to the original domain exactly.
  local function structure_step(p, primary, max_rows)
    local cursor = p.phase_cursor and decode(p.phase_cursor) or nil
    if type(cursor) ~= 'table' then cursor = { task = 'cursors' } end
    if cursor.task == 'cursors' then
      local cursor_ok, cursor_why = cursor_parity(primary)
      if not cursor_ok then return nil, cursor_why end
      local root, root_why = query(db,
        'SELECT path,parent_key,kind,count FROM relay_source_fields ' ..
          'WHERE source_id=? AND path=?', { primary.source_id, '$' })
      if not root then return nil, root_why end
      if not root[1] then return nil, 'field_missing:$' end
      local root_ok, root_field_why = structure_field_ok(primary, root[1])
      if not root_ok then return nil, root_field_why end
      p.phase_cursor = encode({ task = 'units', unit_id = 0 })
      return { count = 0 }
    end
    if cursor.task == 'units' then
      local rows, why = query(db,
        'SELECT unit_id,root_field,kind,parent_key,nested,expected ' ..
          'FROM relay_import_units WHERE source_id=? AND unit_id>? ORDER BY unit_id LIMIT 1',
        { primary.source_id, tonumber(cursor.unit_id) or 0 })
      if not rows then return nil, why end
      for _, unit in ipairs(rows) do
        local ok, unit_why = structure_unit_ok(primary, unit)
        if not ok then return nil, unit_why end
      end
      if #rows == 1 then
        p.phase_cursor = encode({ task = 'units', unit_id = rows[#rows].unit_id })
      else
        p.phase_cursor = encode({ task = 'fields', path = '' })
      end
      return { count = #rows }
    end
    if cursor.task == 'fields' then
      local rows, why = query(db,
        'SELECT path,parent_key,kind,count FROM relay_source_fields ' ..
          'WHERE source_id=? AND path>? ORDER BY path LIMIT 1',
        { primary.source_id, cursor.path or '' })
      if not rows then return nil, why end
      for _, field in ipairs(rows) do
        local ok, field_why = structure_field_ok(primary, field)
        if not ok then return nil, field_why end
      end
      if #rows == 1 then
        p.phase_cursor = encode({ task = 'fields', path = rows[#rows].path })
      else
        p.phase_cursor = nil
      end
      return { count = #rows }
    end
    return nil, 'structure_state'
  end

  local function reverse_origin(unit, row)
    local path = '$.' .. unit.root_field
    local found, why
    if unit.kind == 'raw' then
      found, why = query(db,
        'SELECT 1 AS ok FROM relay_import_source s,json_each(s.raw) e ' ..
          'WHERE s.source_id=? AND e.key=? LIMIT 1', { row.source_id, unit.root_field })
    elseif unit.nested == 1 then
      found, why = query(db,
        'SELECT 1 AS ok FROM relay_import_source s,json_each(s.raw,?) r,json_each(r.value) e ' ..
          'WHERE s.source_id=? AND r.key=? AND CAST(e.key AS TEXT)=? LIMIT 1',
        { path, row.source_id, unit.parent_key, row.record_key })
    elseif unit.kind == 'array' then
      found, why = query(db,
        'SELECT 1 AS ok FROM relay_import_source s,json_each(s.raw,?) e ' ..
          'WHERE s.source_id=? AND CAST(e.key AS TEXT)=? LIMIT 1',
        { path, row.source_id, row.record_key })
    else
      found, why = query(db,
        'SELECT 1 AS ok FROM relay_import_source s,json_each(s.raw,?) e ' ..
          'WHERE s.source_id=? AND e.key=? LIMIT 1',
        { path, row.source_id, row.record_key })
    end
    if not found then return nil, why end
    return found[1] ~= nil
  end

  local function reverse_unit(namespace, parent_key, primary)
    local root_field = namespace
    local want_raw = false
    if namespace:sub(1, 8) == 'unknown:' then
      root_field = namespace:sub(9)
      want_raw = true
    end
    if want_raw and (parent_key or '') ~= '' then return {} end
    local units, why = query(db,
      'SELECT unit_id,expected FROM relay_import_units ' ..
        'WHERE source_id=? AND root_field=? AND parent_key=? AND kind' ..
        (want_raw and '=\'raw\' AND nested=0' or '<>\'raw\'') .. ' LIMIT 2',
      { primary.source_id, root_field, parent_key or '' })
    if not units then return nil, why end
    return units
  end

  local function reverse_step(p, primary, max_rows)
    local cursor = p.phase_cursor and decode(p.phase_cursor) or nil
    if type(cursor) ~= 'table' then cursor = { task = 'records' } end
    if cursor.task == 'records' then
      -- Exact namespace/parent injectivity: every target group must map to one
      -- exact canonical unit, never an unknown: alias of a real domain. The
      -- first page starts before the empty namespace so ('','') is inspected.
      local groups, why
      if cursor.namespace == nil then
        groups, why = query(db,
          'SELECT namespace,parent_key,count(*) AS n FROM relay_records ' ..
            'GROUP BY namespace,parent_key ORDER BY namespace,parent_key LIMIT ?',
          { max_rows })
      else
        groups, why = query(db,
          'SELECT namespace,parent_key,count(*) AS n FROM relay_records ' ..
            'WHERE (namespace,parent_key) > (?,?) ' ..
            'GROUP BY namespace,parent_key ORDER BY namespace,parent_key LIMIT ?',
          { cursor.namespace, cursor.parent_key or '', max_rows })
      end
      if not groups then return fail('reverse', why) end
      for _, group in ipairs(groups) do
        local units, unit_why = reverse_unit(group.namespace, group.parent_key, primary)
        if not units then return fail('reverse', unit_why) end
        if #units == 0 then return fail('import_incomplete', 'extra_record') end
        if #units > 1 then return fail('import_incomplete', 'duplicate_unit') end
        if tonumber(group.n) ~= tonumber(units[1].expected) then
          return fail('import_incomplete', 'record_coverage')
        end
      end
      if #groups == max_rows then
        local last = groups[#groups]
        p.phase_cursor = encode({ task = 'records',
          namespace = last.namespace, parent_key = last.parent_key })
      else
        p.phase_cursor = encode({ task = 'units', unit_id = 0 })
      end
      return { count = #groups }
    end
    if cursor.task == 'units' then
      local rows, why = query(db,
        'SELECT unit_id,root_field,kind,parent_key,nested,expected FROM relay_import_units ' ..
          'WHERE source_id=? AND unit_id>? ORDER BY unit_id LIMIT ?',
        { primary.source_id, tonumber(cursor.unit_id) or 0, max_rows })
      if not rows then return fail('reverse', why) end
      for _, unit in ipairs(rows) do
        -- Canonical target domain, including an expected=0 domain that can
        -- never appear in the target-group page.
        local namespace = unit.kind == 'raw' and ('unknown:' .. unit.root_field)
          or unit.root_field
        local counted, count_why = query(db,
          'SELECT count(*) AS n FROM relay_records WHERE namespace=? AND parent_key=?',
          { namespace, unit.parent_key or '' })
        if not counted then return fail('reverse', count_why) end
        if tonumber(counted[1].n) ~= tonumber(unit.expected) then
          return fail('import_incomplete', 'record_coverage')
        end
        local path = '$.' .. unit.root_field
        local found, found_why
        if unit.nested == 1 then
          found, found_why = query(db,
            'SELECT 1 AS ok FROM relay_import_source s,json_each(s.raw,?) r ' ..
              'WHERE s.source_id=? AND r.key=? LIMIT 1',
            { path, primary.source_id, unit.parent_key })
        elseif unit.kind == 'raw' then
          found, found_why = query(db,
            'SELECT 1 AS ok FROM relay_import_source s,json_each(s.raw) e ' ..
              'WHERE s.source_id=? AND e.key=? LIMIT 1',
            { primary.source_id, unit.root_field })
        else
          found, found_why = query(db,
            'SELECT 1 AS ok FROM relay_import_source s,json_each(s.raw,?) e ' ..
              'WHERE s.source_id=? LIMIT 1', { path, primary.source_id })
        end
        if not found then return fail('reverse', found_why) end
        if not found[1] then return fail('import_incomplete', 'extra_unit') end
      end
      if #rows == 1 then
        p.phase_cursor = encode({ task = 'units', unit_id = rows[#rows].unit_id })
      else
        p.phase = 'derived'
        p.phase_cursor = nil
      end
      return { count = #rows }
    end
    return fail('reverse_state')
  end

  local function derived_checks(primary, auth)
    local bad
    local function check(sql, params)
      local rows, why = query(db, sql, params)
      if not rows then return nil, why end
      return tonumber(rows[1].bad) or 0
    end
    local function mismatch(why)
      return fail('import_incomplete', why)
    end
    -- Processed index: exact source,ordinal,event_id both ways.
    local bad, why = check(
      'SELECT count(*) AS bad FROM relay_processed p LEFT JOIN relay_records r ' ..
        'ON r.namespace=\'processed_event_ids\' AND r.parent_key=\'\' ' ..
        'AND r.ordinal=p.ordinal ' ..
        'WHERE p.source_id<>? OR r.record_key IS NULL ' ..
        'OR p.event_id<>json_extract(r.payload_json,\'$\')',
      { primary.source_id })
    if not bad then return fail('derived', why) end
    if bad ~= 0 then return mismatch('processed') end
    bad, why = check(
      'SELECT count(*) AS bad FROM relay_records r LEFT JOIN relay_processed p ' ..
        'ON p.source_id=? AND p.ordinal=r.ordinal ' ..
        'WHERE r.namespace=\'processed_event_ids\' AND r.parent_key=\'\' ' ..
        'AND (p.ordinal IS NULL OR p.event_id<>json_extract(r.payload_json,\'$\'))',
      { primary.source_id })
    if not bad then return fail('derived', why) end
    if bad ~= 0 then return mismatch('processed') end
    -- Pending events: exact payload/room/source key; pending unless the
    -- witnessed ack sidecar names it, then delivered.
    bad, why = check(
      'SELECT count(*) AS bad FROM relay_records r LEFT JOIN relay_events e ' ..
        'ON e.event_id=r.record_key WHERE r.namespace=\'pending_events\' AND (' ..
        'e.event_id IS NULL OR e.payload_json<>r.payload_json ' ..
        'OR e.room_id<>COALESCE(json_extract(r.payload_json,\'$.room_id\'),\'\') ' ..
        'OR e.source_key<>?||\'|\'||COALESCE(json_extract(r.payload_json,\'$.room_id\'),\'\')||\'|\'||r.record_key||\'|butler\' ' ..
        'OR (e.state=\'delivered\' AND NOT EXISTS (SELECT 1 FROM relay_sidecar sc ' ..
          'WHERE sc.kind IN (\'acks\',\'drain\') AND instr(char(10)||replace(sc.raw,char(13)||char(10),char(10))||char(10),char(10)||e.event_id||char(10))>0)) ' ..
        'OR (e.state=\'pending\' AND EXISTS (SELECT 1 FROM relay_sidecar sc ' ..
          'WHERE sc.kind IN (\'acks\',\'drain\') AND instr(char(10)||replace(sc.raw,char(13)||char(10),char(10))||char(10),char(10)||e.event_id||char(10))>0)) ' ..
        'OR e.inbox_mail_id IS NOT NULL ' ..
        'OR e.state NOT IN (\'pending\',\'delivered\'))',
      { identity.account_id })
    if not bad then return fail('derived', why) end
    if bad ~= 0 then return mismatch('event') end
    bad, why = check(
      'SELECT count(*) AS bad FROM relay_events e LEFT JOIN relay_records r ' ..
        'ON r.namespace=\'pending_events\' AND r.record_key=e.event_id ' ..
        'WHERE r.record_key IS NULL', {})
    if not bad then return fail('derived', why) end
    if bad ~= 0 then return mismatch('event') end
    -- Imported outbox intents: exact payload/normalization, uncertain only.
    bad, why = check(
      'SELECT count(*) AS bad FROM relay_records r LEFT JOIN relay_reply_intents i ' ..
        'ON i.reply_id=r.record_key WHERE r.namespace=\'matrix_reply_outbox\' AND (' ..
        'i.reply_id IS NULL OR i.payload_json<>r.payload_json OR i.imported<>1 ' ..
        'OR i.state<>\'uncertain\' ' ..
        'OR i.txn_id IS NOT (CASE WHEN json_type(r.payload_json,\'$.txn_id\')=\'text\' ' ..
          'AND json_extract(r.payload_json,\'$.txn_id\')<>\'\' ' ..
          'THEN json_extract(r.payload_json,\'$.txn_id\') ELSE NULL END) ' ..
        ')' , {})
    if not bad then return fail('derived', why) end
    if bad ~= 0 then return mismatch('intent') end
    bad, why = check(
      'SELECT count(*) AS bad FROM relay_reply_intents i LEFT JOIN relay_records r ' ..
        'ON r.namespace=\'matrix_reply_outbox\' AND r.record_key=i.reply_id ' ..
        'WHERE r.record_key IS NULL', {})
    if not bad then return fail('derived', why) end
    if bad ~= 0 then return mismatch('intent') end
    -- Extra/absent cursors and structural fields are checked before reverse.
    local cursor_ok, cursor_why = cursor_parity(primary)
    if not cursor_ok then return mismatch(cursor_why or 'cursor') end
    return true
  end

  -- Outbox attempts are normalized in Lua with the exact same tonumber rule as
  -- the importer; SQL GLOB/CAST cannot reproduce 1junk/hex/exponent semantics.
  local function outbox_step(p, max_rows)
    local cursor = p.phase_cursor and decode(p.phase_cursor) or nil
    if type(cursor) ~= 'table' or cursor.task ~= 'outbox' then
      return fail('derived_state')
    end
    -- No payload enters Lua. Attempts are classified in SQL and only bounded
    -- scalars (<=64B trimmed or <=16 significant hex digits) are fetched for
    -- the exact Lua tonumber rule. Long all-digit values compare by SQL number;
    -- long nonnumeric values require stored NULL; other long numeric forms are
    -- an explicit oversize refusal.
    local trimmed = 'trim(json_extract(r.payload_json,\'$.attempts\'),' ..
      '\' \'||char(9)||char(10)||char(13))'
    local tlen = 'length(CAST(' .. trimmed .. ' AS BLOB))'
    local digits = '(' .. tlen .. '<=308 AND ' .. tlen .. '>0 AND ' ..
      trimmed .. ' NOT GLOB \'*[^0-9]*\')'
    local signed = '(' .. tlen .. '<=308 AND substr(' .. trimmed .. ',1,1) IN (\'+\',\'-\') ' ..
      'AND length(substr(' .. trimmed .. ',2))>0 ' ..
      'AND substr(' .. trimmed .. ',2) NOT GLOB \'*[^0-9]*\')'
    local hexsig = 'ltrim(substr(' .. trimmed .. ',3),\'0\')'
    local hex = '(substr(' .. trimmed .. ',1,2) IN (\'0x\',\'0X\') ' ..
      'AND substr(' .. trimmed .. ',3) NOT GLOB \'*[^0-9a-fA-F]*\' ' ..
      'AND length(' .. hexsig .. ')<=16)'
    local nonnumeric = '(NOT ' .. digits .. ' AND NOT ' .. signed .. ' AND NOT ' .. hex ..
      ' AND substr(' .. trimmed .. ',1,2) NOT IN (\'0x\',\'0X\') ' ..
      'AND ' .. trimmed .. ' GLOB \'*[^0-9eE+.-]*\')'
    local sql = 'SELECT r.record_key AS reply_id,' ..
      'json_type(r.payload_json,\'$.attempts\') AS attempts_type,' ..
      tlen .. ' AS attempts_trim_len,' ..
      'CASE WHEN ' .. tlen .. '<=64 THEN ' .. trimmed .. ' ELSE NULL END AS attempts_trim,' ..
      'CASE WHEN ' .. tlen .. '>64 AND ' .. hex ..
        ' THEN CASE WHEN (' .. hexsig .. ')=\'\' THEN \'0x0\' ' ..
          'ELSE \'0x\'||(' .. hexsig .. ') END ELSE NULL END AS attempts_hex,' ..
      'CASE WHEN ' .. tlen .. '>64 AND (' .. digits .. ' OR ' .. signed .. ') ' ..
        'AND i.attempts IS CAST(' .. trimmed .. ' AS REAL) THEN 1 ELSE 0 END AS attempts_number_equal,' ..
      'CASE WHEN ' .. tlen .. '>64 AND ' .. nonnumeric .. ' THEN 1 ELSE 0 END AS attempts_nonnumeric,' ..
      'CASE WHEN ' .. tlen .. '>64 AND NOT ' .. digits .. ' AND NOT ' .. signed ..
        ' AND NOT ' .. hex .. ' AND NOT ' .. nonnumeric .. ' THEN 1 ELSE 0 END AS attempts_ambiguous,' ..
      'CASE WHEN json_type(r.payload_json,\'$.attempts\')=\'true\' THEN 1 ' ..
        'WHEN json_type(r.payload_json,\'$.attempts\')=\'false\' THEN 0 ' ..
        'WHEN json_type(r.payload_json,\'$.attempts\') IN (\'integer\',\'real\') ' ..
          'THEN json_extract(r.payload_json,\'$.attempts\') ' ..
        'ELSE NULL END AS attempts_raw,' ..
      'CASE WHEN i.txn_id IS (CASE WHEN json_type(r.payload_json,\'$.txn_id\')=\'text\' ' ..
        'AND json_extract(r.payload_json,\'$.txn_id\')<>\'\' ' ..
        'THEN json_extract(r.payload_json,\'$.txn_id\') ELSE NULL END) ' ..
        'THEN 1 ELSE 0 END AS txn_equal,' ..
      'i.reply_id AS intent_reply,i.imported AS imported,i.state AS state,' ..
      'i.attempts AS attempts,' ..
      'CASE WHEN i.payload_json=r.payload_json THEN 1 ELSE 0 END AS payload_equal ' ..
      'FROM relay_records r LEFT JOIN relay_reply_intents i ' ..
      'ON i.reply_id=r.record_key WHERE r.namespace=\'matrix_reply_outbox\''
    local params = {}
    if cursor.started then
      sql = sql .. ' AND r.record_key>?'
      params[#params + 1] = cursor.reply_id or ''
    end
    sql = sql .. ' ORDER BY r.record_key LIMIT ?'
    params[#params + 1] = max_rows
    local rows, why = query(db, sql, params)
    if not rows then return fail('derived', why) end
    for _, row in ipairs(rows) do
      if row.intent_reply == nil or tonumber(row.payload_equal) ~= 1
          or tonumber(row.imported) ~= 1 or row.state ~= 'uncertain'
          or tonumber(row.txn_equal) ~= 1 then
        return fail('import_incomplete', 'intent')
      end
      local stored_attempts = row.attempts ~= nil and tonumber(row.attempts) or nil
      if row.attempts_type == 'text' then
        local tlen = tonumber(row.attempts_trim_len) or 0
        if tlen <= 64 then
          if intent_attempts(row.attempts_trim) ~= stored_attempts then
            return fail('import_incomplete', 'intent')
          end
        elseif tonumber(row.attempts_number_equal) == 1 then
          -- exact SQL numeric comparison already succeeded
        elseif row.attempts_hex ~= nil then
          if intent_attempts(row.attempts_hex) ~= stored_attempts then
            return fail('import_incomplete', 'intent')
          end
        elseif tonumber(row.attempts_nonnumeric) == 1 then
          if stored_attempts ~= nil then
            return fail('import_incomplete', 'intent')
          end
        elseif tonumber(row.attempts_ambiguous) == 1 then
          return fail('import_incomplete', 'intent_oversize')
        else
          return fail('import_incomplete', 'intent')
        end
      else
        if intent_attempts(row.attempts_raw) ~= stored_attempts then
          return fail('import_incomplete', 'intent')
        end
      end
    end
    if #rows == max_rows then
      p.phase_cursor = encode({ task = 'outbox', started = true,
        reply_id = rows[#rows].reply_id })
      return { count = #rows }
    end
    p.phase_cursor = nil
    return { count = #rows, done = true }
  end

  local function certificate_id_for(verification_id, source_id, witness_id,
      data_revision, rows, bytes, nodes, owner_id, epoch)
    local stamp = store.store_id .. '\0' .. verification_id .. '\0' ..
      source_id .. '\0' .. tostring(witness_id) .. '\0' ..
      tostring(data_revision) .. '\0' .. tostring(rows) .. '\0' ..
      tostring(bytes) .. '\0' .. tostring(nodes) .. '\0' ..
      tostring(owner_id) .. '\0' .. tostring(epoch) .. '\0' ..
      tostring(PROOF_VERSION)
    return invoke(opts.digest.sha256, stamp)
  end

  function store:verify_import(options)
    if options == nil then options = {} end
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('verify')
    if not ok then return nil, owner_why end
    if store.blocked_reason then return nil, 'blocked' end
    if store.active then return fail('active') end
    if type(options) ~= 'table' then return fail('options') end
    local function budget(name, default, ceiling)
      local value = options[name]
      if value == nil then return default end
      if type(value) ~= 'number' or value % 1 ~= 0 or value < 1 or value > ceiling then
        return nil
      end
      return value
    end
    local max_rows = budget('max_rows', 64, 64)
    local max_units = budget('max_units', 64, 64)
    local max_bytes = budget('max_bytes', 262144, 262144)
    local max_nodes = budget('max_nodes', 8192, 8192)
    if not max_rows then return fail('budget', 'max_rows') end
    if not max_units then return fail('budget', 'max_units') end
    if not max_bytes then return fail('budget', 'max_bytes') end
    if not max_nodes then return fail('budget', 'max_nodes') end
    local primary, primary_why = primary_source()
    if not primary then return fail('import_incomplete', primary_why) end
    if primary.status == 'blocked' then return fail('blocked') end
    if primary.status == 'evidence' then return fail('import_incomplete') end
    local incomplete, incomplete_why = query(db,
      'SELECT count(*) AS n FROM relay_import_units WHERE source_id=? AND done=0',
      { primary.source_id })
    if not incomplete then return fail('verify', incomplete_why) end
    if incomplete[1].n ~= 0 then return fail('import_incomplete') end
    local auth, auth_why = current_auth()
    if not auth then return fail('import_incomplete', auth_why) end
    if auth.phase ~= 'importing' then return fail('not_active') end
    local verification_id = 'verify:' .. store.store_id .. ':' .. primary.source_id
    local progress, progress_why = query(db,
      'SELECT verification_id,source_id,revision,data_revision,unit_id,cursor,state,' ..
        'processed_rows,bytes,nodes,certificate_id,witness_id,phase,phase_cursor,owner_id,epoch ' ..
        'FROM relay_verify_progress WHERE verification_id=?', { verification_id })
    if not progress then return fail('verify', progress_why) end
    local p = progress[1]
    if p then p.phase = p.phase or 'witness' end
    local protocol, protocol_why = query(db,
      'SELECT proof_version FROM relay_proof_state WHERE verification_id=?',
      { verification_id })
    if not protocol then return fail('verify', protocol_why) end
    local protocol_current = protocol[1] ~= nil
      and tonumber(protocol[1].proof_version) == PROOF_VERSION
    if p and p.state == 'ready' and p.phase == 'ready'
        and p.data_revision == auth.data_revision
        and p.owner_id == store.owner_id and p.epoch == store.epoch then
      local cert, cert_why = query(db,
        'SELECT certificate_id,verification_id,source_id,witness_id,data_revision,processed_rows,bytes,nodes,owner_id,epoch ' ..
          'FROM relay_verify_certificates WHERE certificate_id=?', { p.certificate_id })
      if not cert then return fail('verify', cert_why) end
      local c = cert[1]
      local proof_store, proof_store_why = query(db,
        'SELECT store_id FROM relay_proof_state WHERE verification_id=?',
        { verification_id })
      if not proof_store then return fail('verify', proof_store_why) end
      local cert_ok = c ~= nil
      if cert_ok then
        local digest, digest_why = certificate_id_for(c.verification_id,
          c.source_id, c.witness_id, c.data_revision, c.processed_rows,
          c.bytes, c.nodes, c.owner_id, c.epoch)
        if not digest then return fail('certificate', digest_why) end
        cert_ok = digest == c.certificate_id
          and c.certificate_id == p.certificate_id
      end
      if cert_ok and c.verification_id == verification_id
          and c.source_id == primary.source_id
          and c.witness_id == p.witness_id
          and c.data_revision == auth.data_revision
          and c.owner_id == store.owner_id and c.epoch == store.epoch
          and proof_store[1] and proof_store[1].store_id == store.store_id
          and protocol_current then
        return { verified = true, done = true, state = 'ready', count = 0,
          verification_id = verification_id, revision = p.revision,
          data_revision = auth.data_revision, phase = 'ready',
          unit_id = p.unit_id, cursor = p.cursor,
          processed_rows = p.processed_rows, bytes = p.bytes, nodes = p.nodes,
          certificate_id = p.certificate_id, witness_id = p.witness_id }
      end
    end
    local first, first_why = query(db,
      'SELECT min(unit_id) AS id FROM relay_import_units WHERE source_id=?',
      { primary.source_id })
    if not first then return fail('verify', first_why) end
    local began = begin(db)
    if not began then return fail('verify_begin') end
    local cas_ok, cas_why = exec(db,
      'UPDATE relay_authority SET epoch=epoch WHERE singleton=1 AND phase=\'importing\' ' ..
        'AND store_id=? AND owner_id=? AND epoch=?',
      { store.store_id, store.owner_id, store.epoch })
    if cas_ok ~= 1 then rollback(db); return fail('stale_writer', cas_why) end
    if not p or p.data_revision ~= auth.data_revision or p.state == 'ready'
        or not protocol_current then
      exec(db, 'DELETE FROM relay_verify_certificates WHERE verification_id=?',
        { verification_id })
      exec(db, 'DELETE FROM relay_proof_state WHERE verification_id=?',
        { verification_id })
      local state_ok, state_why = exec(db,
        'INSERT OR REPLACE INTO relay_proof_state ' ..
          '(verification_id,store_id,proof_version,created_at) VALUES (?,?,?,?)',
        { verification_id, store.store_id, PROOF_VERSION,
          os.date('!%Y-%m-%dT%H:%M:%SZ') })
      if state_ok ~= 1 then rollback(db); return fail('verify_state', state_why) end
      p = { verification_id = verification_id, source_id = primary.source_id,
        revision = 0, data_revision = auth.data_revision, unit_id = first[1].id,
        cursor = nil, state = 'backlog', processed_rows = 0, bytes = 0, nodes = 0,
        certificate_id = nil, witness_id = nil, phase = 'witness', phase_cursor = nil,
        owner_id = store.owner_id, epoch = store.epoch }
      local reset_ok, reset_why = exec(db,
        'INSERT OR REPLACE INTO relay_verify_progress ' ..
          '(verification_id,source_id,revision,data_revision,unit_id,cursor,state,' ..
          'processed_rows,bytes,nodes,certificate_id,witness_id,phase,phase_cursor,owner_id,epoch) ' ..
          'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        { p.verification_id, p.source_id, p.revision, p.data_revision, p.unit_id,
          p.cursor, p.state, p.processed_rows, p.bytes, p.nodes, p.certificate_id,
          p.witness_id, p.phase, p.phase_cursor, p.owner_id, p.epoch })
      if reset_ok ~= 1 then rollback(db); return fail('verify_reset', reset_why) end
    else
      p.owner_id, p.epoch = store.owner_id, store.epoch
    end
    local expected_revision = tonumber(p.revision) or 0
    local result
    if p.phase == 'witness' then
      local stepped, step_why = witness_step(p, auth, max_bytes)
      if not stepped then rollback(db); return nil, step_why end
      if p.phase == 'source_rows' and p.unit_id == nil then
        p.unit_id = first[1].id
      end
      result = { count = stepped.count or 0, bytes = stepped.bytes or 0, nodes = 0,
        state = 'backlog', phase = p.phase }
    elseif p.phase == 'source_rows' then
      local cursor_state = p.phase_cursor and decode(p.phase_cursor) or nil
      if p.phase_cursor == 'meta' then
        p.phase_cursor = encode({ task = 'cursors' })
        result = { count = 0, bytes = 0, nodes = 0, state = 'backlog',
          phase = 'source_rows' }
      elseif type(cursor_state) == 'table'
          and (cursor_state.task == 'cursors' or cursor_state.task == 'units'
            or cursor_state.task == 'fields') then
        local stepped, step_why = structure_step(p, primary, max_rows)
        if not stepped then rollback(db); return fail('import_incomplete', step_why) end
        result = { count = stepped.count or 0, bytes = 0, nodes = 0,
          state = 'backlog', phase = 'source_rows' }
      elseif type(cursor_state) == 'table' then
        local stepped, step_why = domain_step(p, primary, max_rows)
        if not stepped then rollback(db); return nil, step_why end
        result = { count = stepped.count or 0, bytes = 0, nodes = 0,
          state = 'backlog', phase = 'source_rows' }
      else
        local processed_this, bytes_this, nodes_this = 0, 0, 0
        local total_rows = tonumber(p.processed_rows) or 0
        local total_bytes = tonumber(p.bytes) or 0
        local total_nodes = tonumber(p.nodes) or 0
        local unit_id, cursor = p.unit_id, p.cursor
        local finished_all = unit_id == nil
        local units_this = 0
        while processed_this < max_rows and unit_id ~= nil and units_this < 1 do
          local units, unit_why = query(db,
            'SELECT unit_id,root_field,kind,parent_key,nested,expected FROM relay_import_units ' ..
              'WHERE source_id=? AND unit_id=?', { primary.source_id, unit_id })
          if not units then rollback(db); return fail('verify_unit', unit_why) end
          local unit = units[1]
          if not unit then rollback(db); return fail('import_incomplete', 'unit_missing') end
          local limit = math.min(max_rows - processed_this, 64)
          local meta, page_why = verify_source_meta(unit, primary.source_id, cursor, limit)
          if not meta then rollback(db); return fail('verify_page', page_why) end
          if #meta == 0 then
            units_this = units_this + 1
            local next_unit, next_why = query(db,
              'SELECT min(unit_id) AS id FROM relay_import_units WHERE source_id=? AND unit_id>?',
              { primary.source_id, unit_id })
            if not next_unit then rollback(db); return fail('verify_unit', next_why) end
            unit_id, cursor = next_unit[1].id, nil
            if unit_id == nil then finished_all = true end
          else
            local byte_fits, byte_prefix = 0, 0
            for index, row in ipairs(meta) do
              local row_bytes = tonumber(row.bytes) or 0
              if bytes_this + byte_prefix + row_bytes > max_bytes then
                if processed_this == 0 and index == 1 then
                  rollback(db); return fail('budget_too_small')
                end
                break
              end
              byte_fits, byte_prefix = index, byte_prefix + row_bytes
            end
            if byte_fits == 0 then break end
            local nodes, nodes_why = verify_source_nodes(unit, primary.source_id,
              cursor, byte_fits)
            if not nodes or #nodes ~= byte_fits then
              rollback(db); return fail('verify_page', nodes_why or 'node_prefix')
            end
            local fits, prefix_bytes, prefix_nodes = 0, 0, 0
            for index = 1, byte_fits do
              local row_bytes = tonumber(meta[index].bytes) or 0
              local row_nodes = tonumber(nodes[index].nodes) or 0
              if nodes_this + prefix_nodes + row_nodes > max_nodes then
                if processed_this == 0 and index == 1 then
                  rollback(db); return fail('budget_too_small')
                end
                break
              end
              fits, prefix_bytes, prefix_nodes = index, prefix_bytes + row_bytes,
                prefix_nodes + row_nodes
            end
            if fits == 0 then break end
            local checked, check_why = verify_source_prefix(unit, primary.source_id,
              cursor, fits)
            if not checked then rollback(db); return fail('verify_page', check_why) end
            if tonumber(checked[1].n) ~= fits or tonumber(checked[1].bad) ~= 0 then
              rollback(db); return fail('import_incomplete', 'identity')
            end
            for index = 1, fits do
              local row = meta[index]
              processed_this = processed_this + 1
              total_rows = total_rows + 1
              cursor = tostring(row.key)
            end
            bytes_this, nodes_this = bytes_this + prefix_bytes, nodes_this + prefix_nodes
            total_bytes, total_nodes = total_bytes + prefix_bytes, total_nodes + prefix_nodes
            if fits < #meta then break end
            -- A raw unit is one exact source token, so it is exhausted after
            -- its single row even when that row filled the page limit.
            if #meta < limit or unit.kind == 'raw' then
              units_this = units_this + 1
              local next_unit, next_why = query(db,
                'SELECT min(unit_id) AS id FROM relay_import_units WHERE source_id=? AND unit_id>?',
                { primary.source_id, unit_id })
              if not next_unit then rollback(db); return fail('verify_unit', next_why) end
              unit_id, cursor = next_unit[1].id, nil
              if unit_id == nil then finished_all = true end
            else
              break
            end
          end
        end
        p.unit_id, p.cursor = unit_id, cursor
        p.processed_rows, p.bytes, p.nodes = total_rows, total_bytes, total_nodes
        if finished_all then
          if tonumber(primary.staged_count) ~= total_rows then
            rollback(db); return fail('import_incomplete', 'verified_count')
          end
          p.phase, p.phase_cursor = 'target_reverse', nil
          p.phase_cursor = encode({ task = 'records' })
        end
        result = { count = processed_this, bytes = bytes_this, nodes = nodes_this,
          state = 'backlog', phase = p.phase }
      end
    elseif p.phase == 'target_reverse' then
      local stepped, step_why = reverse_step(p, primary, max_rows)
      if not stepped then rollback(db); return nil, step_why end
      result = { count = stepped.count or 0, bytes = 0, nodes = 0,
        state = 'backlog', phase = p.phase }
    elseif p.phase == 'derived' then
      local derived_cursor = p.phase_cursor and decode(p.phase_cursor) or nil
      local done_checks = false
      if type(derived_cursor) ~= 'table' then
        local derived, derived_why = derived_checks(primary, auth)
        if not derived then rollback(db); return nil, derived_why end
        p.phase_cursor = encode({ task = 'outbox' })
        result = { count = 0, bytes = 0, nodes = 0, state = 'backlog',
          phase = 'derived' }
      elseif derived_cursor.task == 'outbox' then
        local stepped, step_why = outbox_step(p, max_rows)
        if not stepped then rollback(db); return nil, step_why end
        if p.phase_cursor ~= nil then
          result = { count = stepped.count or 0, bytes = 0, nodes = 0,
            state = 'backlog', phase = 'derived' }
        else
          done_checks = true
        end
      else
        rollback(db); return fail('derived_state')
      end
      if done_checks then
      local total_rows = tonumber(p.processed_rows) or 0
      local total_bytes = tonumber(p.bytes) or 0
      local total_nodes = tonumber(p.nodes) or 0
      local cert_id, cert_why = certificate_id_for(verification_id,
        primary.source_id, p.witness_id, auth.data_revision, total_rows,
        total_bytes, total_nodes, store.owner_id, store.epoch)
      if type(cert_id) ~= 'string' then rollback(db); return fail('certificate', cert_why) end
      local cert_ok, cert_err = exec(db,
        'INSERT OR REPLACE INTO relay_verify_certificates ' ..
          '(certificate_id,verification_id,source_id,witness_id,data_revision,' ..
          'processed_rows,bytes,nodes,owner_id,epoch,created_at) ' ..
          'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        { cert_id, verification_id, primary.source_id, p.witness_id,
          auth.data_revision, total_rows, total_bytes, total_nodes, store.owner_id,
          store.epoch, os.date('!%Y-%m-%dT%H:%M:%SZ') })
      if cert_ok ~= 1 then rollback(db); return fail('certificate', cert_err) end
      local version_ok, version_err = exec(db,
        'INSERT OR REPLACE INTO relay_proof_state ' ..
          '(verification_id,store_id,proof_version,created_at) VALUES (?,?,?,?)',
        { verification_id, store.store_id, PROOF_VERSION,
          os.date('!%Y-%m-%dT%H:%M:%SZ') })
      if version_ok ~= 1 then rollback(db); return fail('certificate', version_err) end
      p.state, p.certificate_id, p.phase, p.phase_cursor = 'ready', cert_id, 'ready', nil
      local source_ok, source_why = exec(db,
        'UPDATE relay_import_source SET status=\'verified\',verified_count=staged_count ' ..
          'WHERE source_id=?', { primary.source_id })
      if source_ok ~= 1 then rollback(db); return fail('verify_source', source_why) end
      local authority_ok = exec(db,
        'UPDATE relay_authority SET import_verified=1 WHERE singleton=1 AND phase=\'importing\'')
      if authority_ok ~= 1 then rollback(db); return fail('verify_authority') end
      result = { count = 0, bytes = 0, nodes = 0, state = 'ready', phase = 'ready' }
      end
    else
      rollback(db); return fail('verify_phase')
    end
    p.revision = expected_revision + 1
    p.data_revision = auth.data_revision
    p.owner_id, p.epoch = store.owner_id, store.epoch
    local saved, save_why = exec(db,
      'INSERT OR REPLACE INTO relay_verify_progress ' ..
        '(verification_id,source_id,revision,data_revision,unit_id,cursor,state,' ..
        'processed_rows,bytes,nodes,certificate_id,witness_id,phase,phase_cursor,owner_id,epoch) ' ..
        'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      { p.verification_id, p.source_id, p.revision, p.data_revision, p.unit_id,
        p.cursor, p.state, p.processed_rows, p.bytes, p.nodes, p.certificate_id,
        p.witness_id, p.phase, p.phase_cursor, p.owner_id, p.epoch })
    if saved ~= 1 then rollback(db); return fail('verify_save', save_why) end
    local done = commit(db)
    if not done then
      local detail = { verification_id = verification_id,
        expected_revision = expected_revision, next_revision = p.revision,
        data_revision = auth.data_revision }
      store.blocked_reason = 'unknown_commit'
      store.active = false
      pcall(store.close, store)
      return nil, 'unknown_commit', detail
    end
    return { verified = p.state == 'ready', done = p.state == 'ready',
      state = p.state, count = result.count or 0,
      verification_id = verification_id, revision = p.revision,
      data_revision = auth.data_revision, phase = p.phase,
      unit_id = p.unit_id, cursor = p.cursor,
      processed_rows = p.processed_rows, bytes = p.bytes, nodes = p.nodes,
      certificate_id = p.certificate_id, witness_id = p.witness_id }
  end

  -- Read-only producer proof for the startup/archive coordinator. It returns
  -- necessary inputs, never an archive authorization: the coordinator must
  -- reread this under the current owner and match its own inventory.
  function store:proof(certificate_id)
    if store.closed then return nil, 'stale_writer' end
    if type(certificate_id) ~= 'string' or certificate_id == '' then
      return fail('certificate_id')
    end
    local certificates, cert_why = query(db,
      'SELECT certificate_id,verification_id,source_id,witness_id,data_revision,' ..
        'processed_rows,bytes,nodes,owner_id,epoch FROM relay_verify_certificates ' ..
        'WHERE certificate_id=?', { certificate_id })
    if not certificates then return fail('proof', cert_why) end
    local certificate = certificates[1]
    if not certificate then return fail('proof_missing') end
    local progress, progress_why = query(db,
      'SELECT verification_id,revision,state,phase,data_revision,certificate_id,' ..
        'witness_id,processed_rows,bytes,nodes,owner_id,epoch ' ..
        'FROM relay_verify_progress WHERE verification_id=?',
      { certificate.verification_id })
    if not progress then return fail('proof', progress_why) end
    local checkpoint = progress[1]
    if not checkpoint or checkpoint.state ~= 'ready'
        or checkpoint.phase ~= 'ready'
        or checkpoint.certificate_id ~= certificate.certificate_id
        or checkpoint.witness_id ~= certificate.witness_id then
      return fail('proof_missing')
    end
    local state, state_why = query(db,
      'SELECT store_id,proof_version FROM relay_proof_state WHERE verification_id=?',
      { certificate.verification_id })
    if not state then return fail('proof', state_why) end
    if not state[1] or state[1].store_id ~= store.store_id
        or tonumber(state[1].proof_version) ~= PROOF_VERSION then
      return fail('proof_stale')
    end
    local auth, auth_why = current_auth()
    if not auth then return fail('proof', auth_why) end
    if auth.store_id ~= store.store_id
        or certificate.data_revision ~= auth.data_revision
        or certificate.owner_id ~= auth.owner_id
        or certificate.epoch ~= auth.epoch then
      return fail('proof_stale')
    end
    local digest, digest_why = certificate_id_for(certificate.verification_id,
      certificate.source_id, certificate.witness_id, certificate.data_revision,
      certificate.processed_rows, certificate.bytes, certificate.nodes,
      certificate.owner_id, certificate.epoch)
    if not digest then return fail('proof', digest_why) end
    if digest ~= certificate.certificate_id then return fail('proof_stale') end
    local witnesses, witness_why = query(db,
      'SELECT source_id,kind,role,stamp,bytes,raw_sha256,root_digest,chunk_size ' ..
        'FROM relay_verify_witness WHERE store_id=? AND source_id=? AND kind=\'source\'',
      { store.store_id, certificate.source_id })
    if not witnesses then return fail('proof', witness_why) end
    if not witnesses[1] then return fail('witness_missing') end
    return {
      store_id = store.store_id,
      verification_id = certificate.verification_id,
      revision = checkpoint.revision,
      data_revision = certificate.data_revision,
      certificate_id = certificate.certificate_id,
      witness_id = certificate.witness_id,
      proof_version = PROOF_VERSION,
      processed_rows = certificate.processed_rows,
      bytes = certificate.bytes,
      nodes = certificate.nodes,
      owner_id = certificate.owner_id,
      epoch = certificate.epoch,
      source = witnesses[1],
    }
  end

  function store:activate()
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('activate')
    if not ok then return nil, owner_why end
    if store.active then return writer() end
    if store.blocked_reason then return fail('blocked') end
    local auth, auth_why = current_auth()
    if not auth then return fail('import_incomplete', auth_why) end
    if auth.store_id ~= store.store_id then return fail('blocked', 'identity_mismatch') end
    if auth.phase == 'active' then
      local raw = marker_encode(store.store_id, store.owner_id, store.epoch, auth.source_stamp)
      local published = raw and opts.marker.publish(raw)
      if not published then return fail('marker_publish') end
      store.active, store.state, store.blocked_reason = true, 'active', nil
      return writer()
    end
    if auth.phase ~= 'importing' or auth.import_verified ~= 1 then
      return fail('import_incomplete')
    end
    local primary, primary_why = primary_source()
    if not primary or primary.status ~= 'verified' then
      return fail('import_incomplete', primary_why)
    end
    -- Activation is a constant indexed proof: the durable checkpoint must be
    -- ready for the current proof inputs and bound to this owner/epoch, and the
    -- certificate must be the same record. No scan, COUNT or bulk delete.
    local verification_id = 'verify:' .. store.store_id .. ':' .. primary.source_id
    local progress, progress_why = query(db,
      'SELECT state,phase,data_revision,certificate_id,witness_id,owner_id,epoch ' ..
        'FROM relay_verify_progress WHERE verification_id=?', { verification_id })
    if not progress then return fail('import_incomplete', progress_why) end
    local checkpoint = progress[1]
    if not checkpoint or checkpoint.state ~= 'ready' or checkpoint.phase ~= 'ready'
        or checkpoint.data_revision ~= auth.data_revision
        or type(checkpoint.witness_id) ~= 'string'
        or checkpoint.owner_id ~= store.owner_id or checkpoint.epoch ~= store.epoch
        or type(checkpoint.certificate_id) ~= 'string' then
      return fail('import_incomplete', 'certificate')
    end
    local certificates, cert_why = query(db,
      'SELECT certificate_id,verification_id,source_id,witness_id,data_revision,' ..
        'processed_rows,bytes,nodes,owner_id,epoch FROM relay_verify_certificates ' ..
        'WHERE certificate_id=?', { checkpoint.certificate_id })
    if not certificates then return fail('import_incomplete', cert_why) end
    local certificate = certificates[1]
    if not certificate or certificate.verification_id ~= verification_id
        or certificate.source_id ~= primary.source_id
        or certificate.witness_id ~= checkpoint.witness_id
        or certificate.data_revision ~= auth.data_revision
        or certificate.owner_id ~= store.owner_id
        or certificate.epoch ~= store.epoch then
      return fail('import_incomplete', 'certificate')
    end
    local proof_state, proof_state_why = query(db,
      'SELECT store_id,proof_version FROM relay_proof_state WHERE verification_id=?',
      { verification_id })
    if not proof_state then return fail('import_incomplete', proof_state_why) end
    if not proof_state[1] or proof_state[1].store_id ~= store.store_id
        or tonumber(proof_state[1].proof_version) ~= PROOF_VERSION then
      return fail('import_incomplete', 'proof_version')
    end
    local cert_digest, cert_digest_why = certificate_id_for(
      certificate.verification_id, certificate.source_id, certificate.witness_id,
      certificate.data_revision, certificate.processed_rows, certificate.bytes,
      certificate.nodes, certificate.owner_id, certificate.epoch)
    if not cert_digest then return fail('certificate', cert_digest_why) end
    if cert_digest ~= certificate.certificate_id
        or certificate.certificate_id ~= checkpoint.certificate_id then
      return fail('import_incomplete', 'certificate')
    end
    local raw = marker_encode(store.store_id, store.owner_id, store.epoch, auth.source_stamp)
    if not raw or #raw > limits.marker_bytes then return fail('marker_size') end
    local marker_fault = fault('active_marker_publish', { raw = raw })
    if marker_fault then return fail('marker_publish', marker_fault.code) end
    local began = begin(db)
    if not began then return fail('activate_begin') end
    local changed = exec(db,
      'UPDATE relay_authority SET phase=\'active\',import_verified=1,blocked_reason=NULL ' ..
        'WHERE singleton=1 AND phase=\'importing\' AND store_id=? AND owner_id=? AND epoch=? ' ..
        'AND data_revision=? AND import_verified=1',
      { store.store_id, store.owner_id, store.epoch, auth.data_revision })
    if changed ~= 1 then rollback(db); return fail('stale_writer') end
    local done = commit(db)
    if not done then rollback(db); return fail('activate_commit') end
    local published, publish_why = invoke(opts.marker.publish, raw)
    if not published then
      store.active, store.state, store.blocked_reason = false, 'not_active', nil
      return fail('marker_publish', type(publish_why) == 'table' and publish_why.code or publish_why)
    end
    -- The primary source bytes are evidence only. Retain the digest/metadata,
    -- retire the raw staging blob; backup evidence remains untouched.
    pcall(exec, db, 'UPDATE relay_import_source SET raw=NULL WHERE source_id=?', { primary.source_id })
    store.active, store.state, store.blocked_reason = true, 'active', nil
    store.owner_id, store.epoch = auth.owner_id, auth.epoch
    local cached = read_cursor()
    if cached then store.cursor_cache = cached end
    return writer()
  end

  function store:accept_batch(writer_token, batch)
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('accept_batch')
    if not ok then return nil, owner_why end
    if store.blocked_reason then return fail('blocked') end
    if not store.active then return fail('not_active') end
    if type(writer_token) ~= 'table' or writer_token.store_id ~= store.store_id
        or writer_token.owner_id ~= store.owner_id or writer_token.epoch ~= store.epoch then
      return fail('stale_writer')
    end
    if type(batch) ~= 'table' or not identifier(batch.operation_id) then
      return fail('operation')
    end
    local expected = batch.expected_cursor
    local next_cursor = batch.next_cursor
    local events = batch.events or {}
    if expected ~= nil and type(expected) ~= 'string' then return fail('cursor') end
    if next_cursor ~= nil and type(next_cursor) ~= 'string' then return fail('cursor') end
    if type(events) ~= 'table' then return fail('events') end
    local encoded_events, encode_why = encode(events)
    if not encoded_events then return fail('events', encode_why) end
    local witness = operation_input('accept_batch', { tostring(expected or ''), tostring(next_cursor or ''),
      encoded_events })
    local began = begin(db)
    if not began then return fail('begin') end
    local cas_ok, cas_why = cas(db)
    if not cas_ok then rollback(db); return nil, cas_why end
    local operation, operation_why = find_operation(batch.operation_id)
    if operation == nil then rollback(db); return fail('operation', operation_why) end
    if operation then
      if operation.input_witness ~= witness then
        rollback(db); return fail('operation_conflict')
      end
      rollback(db)
      return replay_operation(operation)
    end
    local current, current_why = query(db,
      'SELECT value FROM relay_cursors WHERE scope=\'sync\' AND present=1')
    if not current then rollback(db); return fail('cursor', current_why) end
    local current_value = current[1] and current[1].value or nil
    if current_value ~= expected then rollback(db); return fail('cursor_conflict') end
    for _, event in ipairs(events) do
      if type(event) ~= 'table' or not identifier(event.event_id)
          or type(event.room_id) ~= 'string' or type(event.payload_json) ~= 'string' then
        rollback(db); return fail('event')
      end
      local valid, valid_why = query(db,
        'SELECT json_valid(?) AS valid,length(CAST(? AS BLOB)) AS bytes,' ..
          '(SELECT count(*) FROM json_tree(?)) AS nodes',
        { event.payload_json, event.payload_json, event.payload_json })
      if not valid then rollback(db); return fail('event', valid_why) end
      if valid[1].valid ~= 1 or tonumber(valid[1].bytes) > limits.record_bytes
          or tonumber(valid[1].nodes) > limits.record_nodes then
        rollback(db); return fail('event_shape')
      end
      local source_key = event.source_key
      if source_key == nil then
        source_key = identity.account_id .. '|' .. event.room_id .. '|' .. event.event_id .. '|butler'
      end
      if not identifier(source_key) then rollback(db); return fail('event_source') end
      local existing, existing_why = query(db,
        'SELECT payload_json,source_key,room_id FROM relay_events WHERE event_id=?',
        { event.event_id })
      if not existing then rollback(db); return fail('event', existing_why) end
      if existing[1] then
        if existing[1].payload_json ~= event.payload_json
            or existing[1].source_key ~= source_key
            or existing[1].room_id ~= event.room_id then
          rollback(db); return fail('value_conflict', event.event_id)
        end
      else
        local inserted = exec(db,
          'INSERT INTO relay_events (event_id,room_id,source_key,payload_json,state) ' ..
            'VALUES (?,?,?,?,\'pending\')',
          { event.event_id, event.room_id, source_key, event.payload_json })
        if inserted ~= 1 then rollback(db); return fail('event_insert') end
      end
    end
    local cursor_json = next_cursor and encode(next_cursor) or 'null'
    local cursor_set = exec(db,
      'INSERT INTO relay_cursors (scope,present,cursor_json,value) VALUES (\'sync\',?,?,?) ' ..
        'ON CONFLICT(scope) DO UPDATE SET present=excluded.present,cursor_json=excluded.cursor_json,' ..
        'value=excluded.value',
      { next_cursor and 1 or 0, cursor_json, next_cursor })
    if cursor_set ~= 1 then rollback(db); return fail('cursor_write') end
    local result = { count = #events, cursor = next_cursor }
    local encoded_result, result_why = encode(result)
    if not encoded_result then rollback(db); return fail('result', result_why) end
    local operation_set = exec(db,
      'INSERT INTO relay_operations (operation_id,operation_kind,input_witness,result_json,owner_id,epoch) ' ..
        'VALUES (?,?,?,?,?,?)',
      { batch.operation_id, 'accept_batch', witness, encoded_result, store.owner_id, store.epoch })
    if operation_set ~= 1 then rollback(db); return fail('operation_write') end
    local before_commit = fault('before_commit', { operation = batch.operation_id })
    if before_commit then rollback(db); return fail(before_commit.code or 'fault') end
    local commit_fault = fault('commit_reply_after_commit', { operation = batch.operation_id })
    if commit_fault then
      local blocked = exec(db,
        'UPDATE relay_authority SET phase=\'blocked\',blocked_reason=? WHERE singleton=1 ' ..
          'AND store_id=? AND owner_id=? AND epoch=?',
        { 'unknown_commit', store.store_id, store.owner_id, store.epoch })
      if blocked ~= 1 then rollback(db); return fail('blocked') end
      local done = commit(db)
      if not done then rollback(db); return fail('blocked') end
      store.blocked_reason = 'unknown_commit'
      return fail(commit_fault.code or 'unknown_commit')
    end
    local done = commit(db)
    if not done then rollback(db); return fail('commit') end
    store.cursor_cache = { since = next_cursor, messages = store.cursor_cache and store.cursor_cache.messages }
    return result
  end

  function store:resolve_operation(operation_id)
    if store.closed then return nil, 'stale_writer' end
    if not identifier(operation_id) then return fail('operation') end
    local operation, operation_why = find_operation(operation_id)
    if operation == nil then return fail('operation', operation_why) end
    if operation then
      if store.blocked_reason == 'unknown_commit' then
        local began = begin(db)
        if not began then return fail('resolve_begin') end
        local cleared = exec(db,
          'UPDATE relay_authority SET phase=\'active\',blocked_reason=NULL WHERE singleton=1 ' ..
            'AND phase=\'blocked\' AND store_id=? AND owner_id=? AND epoch=?',
          { store.store_id, store.owner_id, store.epoch })
        if cleared ~= 1 then rollback(db); return fail('blocked') end
        local done = commit(db)
        if not done then rollback(db); return fail('resolve_commit') end
        store.blocked_reason, store.active, store.state = nil, true, 'active'
      end
      local result, result_why = replay_operation(operation)
      if result == nil then return nil, result_why end
      return { status = 'committed', result = result }
    end
    if store.blocked_reason == 'unknown_commit' then
      local began = begin(db)
      if not began then return fail('resolve_begin') end
      local cleared = exec(db,
        'UPDATE relay_authority SET phase=\'active\',blocked_reason=NULL WHERE singleton=1 ' ..
          'AND phase=\'blocked\' AND store_id=? AND owner_id=? AND epoch=?',
        { store.store_id, store.owner_id, store.epoch })
      if cleared ~= 1 then rollback(db); return fail('blocked') end
      local done = commit(db)
      if not done then rollback(db); return fail('resolve_commit') end
      store.blocked_reason, store.active, store.state = nil, true, 'active'
    end
    return { status = 'absent' }
  end

  local function mutation_gate(writer_token, operation_id)
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('mutation')
    if not ok then return nil, owner_why end
    if store.blocked_reason then return nil, 'blocked' end
    if not store.active then return nil, 'not_active' end
    if type(writer_token) ~= 'table' or writer_token.store_id ~= store.store_id
        or writer_token.owner_id ~= store.owner_id or writer_token.epoch ~= store.epoch then
      return nil, 'stale_writer'
    end
    if not identifier(operation_id) then return nil, 'operation' end
    return true
  end

  function store:put(writer_token, namespace, key, payload_json, operation_id)
    local ok, gate_why = mutation_gate(writer_token, operation_id)
    if not ok then return nil, gate_why end
    if not identifier(namespace) or type(key) ~= 'string' or type(payload_json) ~= 'string' then
      return fail('record')
    end
    local valid, valid_why = query(db,
      'SELECT json_valid(?) AS valid,json_type(?) AS kind,length(CAST(? AS BLOB)) AS bytes,' ..
        '(SELECT count(*) FROM json_tree(?)) AS nodes',
      { payload_json, payload_json, payload_json, payload_json })
    if not valid then return fail('record', valid_why) end
    if valid[1].valid ~= 1 or tonumber(valid[1].bytes) > limits.record_bytes
        or tonumber(valid[1].nodes) > limits.record_nodes then
      return fail('record_shape')
    end
    local witness = operation_input('put', { namespace, key, payload_json })
    local began = begin(db)
    if not began then return fail('begin') end
    local cas_ok, cas_why = cas(db)
    if not cas_ok then rollback(db); return nil, cas_why end
    local operation, operation_why = find_operation(operation_id)
    if operation == nil then rollback(db); return fail('operation', operation_why) end
    if operation then
      if operation.input_witness ~= witness then rollback(db); return fail('operation_conflict') end
      rollback(db)
      return replay_operation(operation)
    end
    local added = exec(db,
      'INSERT INTO relay_records (namespace,parent_key,record_key,ordinal,json_kind,payload_json) ' ..
        'VALUES (?,?,?,?,?,?) ON CONFLICT(namespace,parent_key,record_key) DO UPDATE SET ' ..
        'json_kind=excluded.json_kind,payload_json=excluded.payload_json,ordinal=NULL',
      { namespace, '', key, nil, valid[1].kind, payload_json })
    if added ~= 1 then rollback(db); return fail('record_write') end
    local result = { operation_id = operation_id, namespace = namespace, key = key }
    local encoded, encode_why = encode(result)
    if not encoded then rollback(db); return fail('result', encode_why) end
    local stored = exec(db,
      'INSERT INTO relay_operations (operation_id,operation_kind,input_witness,result_json,owner_id,epoch) ' ..
        'VALUES (?,?,?,?,?,?)',
      { operation_id, 'put', witness, encoded, store.owner_id, store.epoch })
    if stored ~= 1 then rollback(db); return fail('operation_write') end
    local before_commit = fault('before_commit', { operation = operation_id })
    if before_commit then rollback(db); return fail(before_commit.code or 'fault') end
    local done = commit(db)
    if not done then rollback(db); return fail('commit') end
    return result
  end

  function store:get(namespace, parent_key, key)
    local ok, read_why = require_active()
    if not ok then return nil, read_why end
    local rows, why = query(db,
      'SELECT namespace,parent_key,record_key,ordinal,json_kind,payload_json ' ..
        'FROM relay_records WHERE namespace=? AND parent_key=? AND record_key=?',
      { namespace, parent_key or '', key })
    if not rows then return nil, why end
    return rows[1]
  end

  function store:delete(writer_token, namespace, key, operation_id)
    local ok, gate_why = mutation_gate(writer_token, operation_id)
    if not ok then return nil, gate_why end
    if not identifier(namespace) or type(key) ~= 'string' then return fail('record') end
    local witness = operation_input('delete', { namespace, key })
    local began = begin(db)
    if not began then return fail('begin') end
    local cas_ok, cas_why = cas(db)
    if not cas_ok then rollback(db); return nil, cas_why end
    local operation, operation_why = find_operation(operation_id)
    if operation == nil then rollback(db); return fail('operation', operation_why) end
    if operation then
      if operation.input_witness ~= witness then rollback(db); return fail('operation_conflict') end
      rollback(db)
      return replay_operation(operation)
    end
    local deleted = exec(db,
      'DELETE FROM relay_records WHERE namespace=? AND parent_key=\'\' AND record_key=?',
      { namespace, key })
    if deleted == nil then rollback(db); return fail('record_delete') end
    local result = { operation_id = operation_id, namespace = namespace, key = key }
    local encoded, encode_why = encode(result)
    if not encoded then rollback(db); return fail('result', encode_why) end
    local stored = exec(db,
      'INSERT INTO relay_operations (operation_id,operation_kind,input_witness,result_json,owner_id,epoch) ' ..
        'VALUES (?,?,?,?,?,?)',
      { operation_id, 'delete', witness, encoded, store.owner_id, store.epoch })
    if stored ~= 1 then rollback(db); return fail('operation_write') end
    local done = commit(db)
    if not done then rollback(db); return fail('commit') end
    return result
  end

  function store:page(namespace, options)
    local ok, read_why = require_active()
    if not ok then return nil, read_why end
    options = options or {}
    local limit = tonumber(options.limit) or limits.page_rows
    if limit < 1 or limit > limits.page_rows or limit % 1 ~= 0 then return fail('page_limit') end
    local parent = options.parent_key or ''
    local after = options.after_key
    local rows, why = query(db,
      'SELECT namespace,parent_key,record_key,ordinal,json_kind,payload_json FROM relay_records ' ..
        'WHERE namespace=? AND parent_key=? AND (? IS NULL OR ' ..
        '(ordinal IS NOT NULL AND ordinal>CAST(? AS INTEGER)) OR ' ..
        '(ordinal IS NULL AND record_key>?)) ' ..
        'ORDER BY CASE WHEN ordinal IS NULL THEN 0 ELSE 1 END,ordinal,record_key LIMIT ?',
      { namespace, parent, after, after, after, limit })
    if not rows then return nil, why end
    return rows
  end

  function store:dispatch_page(limit)
    local ok, read_why = require_active()
    if not ok then return nil, read_why end
    limit = tonumber(limit) or limits.page_rows
    if limit < 1 or limit > limits.page_rows or limit % 1 ~= 0 then return fail('page_limit') end
    local rows, why = query(db,
      'SELECT event_id,room_id,source_key,payload_json FROM relay_events ' ..
        'WHERE state=\'pending\' ORDER BY event_id LIMIT ?', { limit })
    if not rows then return nil, why end
    return rows
  end

  function store:complete_dispatch(writer_token, event_id, receipt, changes)
    if type(changes) ~= 'table' then return fail('operation') end
    local ok, gate_why = mutation_gate(writer_token, changes.operation_id)
    if not ok then return nil, gate_why end
    if not identifier(event_id) or type(receipt) ~= 'table' then return fail('receipt') end
    local mail_id = receipt.mail_id
    if mail_id ~= nil and type(mail_id) ~= 'string' then return fail('receipt') end
    local receipt_json, receipt_why = encode(receipt)
    if not receipt_json then return fail('receipt', receipt_why) end
    local witness = operation_input('complete_dispatch', { event_id, receipt_json })
    local began = begin(db)
    if not began then return fail('begin') end
    local cas_ok, cas_why = cas(db)
    if not cas_ok then rollback(db); return nil, cas_why end
    local operation, operation_why = find_operation(changes.operation_id)
    if operation == nil then rollback(db); return fail('operation', operation_why) end
    if operation then
      if operation.input_witness ~= witness then rollback(db); return fail('operation_conflict') end
      rollback(db)
      return replay_operation(operation)
    end
    local updated = exec(db,
      'UPDATE relay_events SET state=\'delivered\',inbox_mail_id=? ' ..
        'WHERE event_id=? AND state=\'pending\'', { mail_id or '', event_id })
    if updated ~= 1 then rollback(db); return fail('not_pending') end
    local result = { event_id = event_id, mail_id = mail_id }
    local encoded, encode_why = encode(result)
    if not encoded then rollback(db); return fail('result', encode_why) end
    local stored = exec(db,
      'INSERT INTO relay_operations (operation_id,operation_kind,input_witness,result_json,owner_id,epoch) ' ..
        'VALUES (?,?,?,?,?,?)',
      { changes.operation_id, 'complete_dispatch', witness, encoded, store.owner_id, store.epoch })
    if stored ~= 1 then rollback(db); return fail('operation_write') end
    local done = commit(db)
    if not done then rollback(db); return fail('commit') end
    return result
  end

  function store:reply_dispatch_page(limit)
    local ok, read_why = require_active()
    if not ok then return nil, read_why end
    limit = tonumber(limit) or limits.page_rows
    if limit < 1 or limit > limits.page_rows or limit % 1 ~= 0 then return fail('page_limit') end
    local rows, why = query(db,
      'SELECT reply_id,txn_id,state,attempts,payload_json FROM relay_reply_intents ' ..
        'WHERE state=\'prepared\' AND imported=0 ORDER BY reply_id LIMIT ?', { limit })
    if not rows then return nil, why end
    return rows
  end

  function store:claim_reply(writer_token, reply_id, operation_id)
    local ok, gate_why = mutation_gate(writer_token, operation_id)
    if not ok then return nil, gate_why end
    if not identifier(reply_id) then return fail('reply') end
    local witness = operation_input('claim_reply', { reply_id })
    local began = begin(db)
    if not began then return fail('begin') end
    local cas_ok, cas_why = cas(db)
    if not cas_ok then rollback(db); return nil, cas_why end
    local operation, operation_why = find_operation(operation_id)
    if operation == nil then rollback(db); return fail('operation', operation_why) end
    if operation then
      if operation.input_witness ~= witness then rollback(db); return fail('operation_conflict') end
      rollback(db)
      return replay_operation(operation)
    end
    local changed = exec(db,
      'UPDATE relay_reply_intents SET state=\'in_flight\',attempts=COALESCE(attempts,0)+1 ' ..
        'WHERE reply_id=? AND state=\'prepared\' AND imported=0', { reply_id })
    if changed ~= 1 then rollback(db); return fail('not_prepared') end
    local result = { reply_id = reply_id, state = 'in_flight' }
    local encoded = encode(result)
    if not encoded then rollback(db); return fail('result') end
    local stored = exec(db,
      'INSERT INTO relay_operations (operation_id,operation_kind,input_witness,result_json,owner_id,epoch) ' ..
        'VALUES (?,?,?,?,?,?)',
      { operation_id, 'claim_reply', witness, encoded, store.owner_id, store.epoch })
    if stored ~= 1 then rollback(db); return fail('operation_write') end
    local done = commit(db)
    if not done then rollback(db); return fail('commit') end
    return result
  end

  local function finish_reply(writer_token, reply_id, state, operation_id)
    local ok, gate_why = mutation_gate(writer_token, operation_id)
    if not ok then return nil, gate_why end
    if not identifier(reply_id) then return fail('reply') end
    local witness = operation_input('reply_' .. state, { reply_id })
    local began = begin(db)
    if not began then return fail('begin') end
    local cas_ok, cas_why = cas(db)
    if not cas_ok then rollback(db); return nil, cas_why end
    local operation, operation_why = find_operation(operation_id)
    if operation == nil then rollback(db); return fail('operation', operation_why) end
    if operation then
      if operation.input_witness ~= witness then rollback(db); return fail('operation_conflict') end
      rollback(db)
      return replay_operation(operation)
    end
    local changed = exec(db,
      'UPDATE relay_reply_intents SET state=? WHERE reply_id=? AND state=\'in_flight\' AND imported=0',
      { state, reply_id })
    if changed ~= 1 then rollback(db); return fail('not_in_flight') end
    local result = { reply_id = reply_id, state = state }
    local encoded = encode(result)
    if not encoded then rollback(db); return fail('result') end
    local stored = exec(db,
      'INSERT INTO relay_operations (operation_id,operation_kind,input_witness,result_json,owner_id,epoch) ' ..
        'VALUES (?,?,?,?,?,?)',
      { operation_id, 'reply_' .. state, witness, encoded, store.owner_id, store.epoch })
    if stored ~= 1 then rollback(db); return fail('operation_write') end
    local done = commit(db)
    if not done then rollback(db); return fail('commit') end
    return result
  end

  function store:complete_reply(writer_token, reply_id, operation_id)
    return finish_reply(writer_token, reply_id, 'sent', operation_id)
  end
  function store:fail_reply(writer_token, reply_id, operation_id)
    return finish_reply(writer_token, reply_id, 'failed', operation_id)
  end

  function store:status()
    if store.closed then return nil, 'stale_writer' end
    local auth, auth_why = current_auth()
    local result = { phase = store.state, active = store.active,
      blocked = store.blocked_reason, store_id = store.store_id,
      owner_id = store.owner_id, epoch = store.epoch }
    if auth then
      result.phase, result.import_verified = auth.phase, auth.import_verified == 1
    elseif auth_why and auth_why ~= 'unprepared' then
      return nil, auth_why
    end
    return result
  end

  return store
end

return M
