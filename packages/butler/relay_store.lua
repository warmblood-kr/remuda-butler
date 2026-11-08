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
  blocked_reason TEXT
);
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
]]

local METHODS = {
  'import_prepare', 'import_source', 'import_batch', 'import_acks',
  'verify_import', 'activate', 'writer', 'cursor', 'accept_batch',
  'dispatch_page', 'complete_dispatch', 'get', 'put', 'delete', 'page',
  'resolve_operation', 'reply_dispatch_page', 'claim_reply', 'complete_reply',
  'fail_reply', 'status',
}

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

local function ensure_schema(db)
  local ok, why = db:batch(SCHEMA)
  if not ok then return fail('schema', why) end
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
      state = 'importing'
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
      'SELECT store_id,phase,owner_id,epoch,source_stamp,import_verified,blocked_reason ' ..
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
      'SELECT source_id,raw_sha256,bytes,status FROM relay_import_source WHERE source_id=?',
      { source_id })
    if not existing then return fail('source', existing_why) end
    if existing[1] then
      if existing[1].raw_sha256 ~= hash or existing[1].bytes ~= #raw then
        return fail('source_changed')
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
      local attempts = tonumber(fields[1].attempts)
      if attempts and attempts % 1 ~= 0 then attempts = nil end
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
        local done = #rows < requested and 1 or 0
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
      'SELECT raw_sha256 FROM relay_sidecar WHERE source_id=? AND kind=\'acks\'', { source_id })
    if not existing then return fail('sidecar', existing_why) end
    if existing[1] and existing[1].raw_sha256 ~= hash then return fail('source_changed') end
    local began = begin(db)
    if not began then return fail('sidecar_begin') end
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

  local function verify_unit(unit, source_id)
    local namespace = unit.kind == 'raw' and ('unknown:' .. unit.root_field) or unit.root_field
    local from, payload, source_params
    if unit.kind == 'raw' then
      from = 'FROM relay_import_source s,json_each(s.raw) e WHERE s.source_id=? AND e.key=?'
      payload = 's.raw -> e.fullkey'
      source_params = { source_id, unit.root_field }
    elseif unit.nested == 1 then
      from = 'FROM relay_import_source s,json_each(s.raw,?) r,json_each(r.value) e ' ..
        'WHERE s.source_id=? AND r.key=?'
      payload = 'r.value -> e.fullkey'
      source_params = { '$.' .. unit.root_field, source_id, unit.parent_key }
    else
      from = 'FROM relay_import_source s,json_each(s.raw,?) e WHERE s.source_id=?'
      payload = 's.raw -> e.fullkey'
      source_params = { '$.' .. unit.root_field, source_id }
    end
    local last = nil
    while true do
      local condition = last == nil and '' or
        (unit.kind == 'array' and ' AND CAST(e.key AS INTEGER)>CAST(? AS INTEGER)' or
          ' AND CAST(e.key AS BLOB)>CAST(? AS BLOB)')
      local order = unit.kind == 'array' and '' or ' ORDER BY CAST(e.key AS BLOB)'
      local record_key = unit.kind == 'array' and 'CAST(src.key AS TEXT)' or 'src.key'
      local sql = 'WITH src AS MATERIALIZED (SELECT e.key AS key,e.type AS kind,' ..
        payload .. ' AS payload ' .. from .. condition .. order .. ' LIMIT 64) ' ..
        'SELECT max(src.key) AS last,count(*) AS n,COALESCE(sum(CASE WHEN ' ..
        'r.record_key IS NULL OR r.json_kind<>src.kind OR r.payload_json<>src.payload ' ..
        'OR (?=\'array\' AND (r.ordinal IS NULL OR CAST(r.ordinal AS TEXT)<>CAST(src.key AS TEXT))) ' ..
        'OR (?=\'object\' AND r.ordinal IS NOT NULL) THEN 1 ELSE 0 END),0) AS bad ' ..
        'FROM src LEFT JOIN relay_records r ON r.namespace=? AND r.parent_key=? ' ..
        'AND r.record_key=' .. record_key
      local params = {}
      for index = 1, #source_params do params[index] = source_params[index] end
      if last ~= nil then params[#params + 1] = unit.kind == 'array' and tonumber(last) or last end
      params[#params + 1] = unit.kind
      params[#params + 1] = unit.kind
      params[#params + 1] = namespace
      params[#params + 1] = unit.parent_key or ''
      local rows, why = query(db, sql, params)
      if not rows then return nil, why end
      local row = rows[1]
      if tonumber(row.n) == 0 then break end
      if tonumber(row.bad) ~= 0 then return nil, 'identity' end
      last = row.last
      if tonumber(row.n) < 64 then break end
    end
    return true
  end

  local function primary_source()
    local rows, why = query(db,
      'SELECT source_id,status,staged_count FROM relay_import_source WHERE role=\'primary\' ' ..
        'ORDER BY source_id LIMIT 1')
    if not rows then return nil, why end
    return rows[1]
  end

  function store:verify_import()
    if store.closed then return nil, 'stale_writer' end
    local ok, owner_why = owner_ok('verify')
    if not ok then return nil, owner_why end
    if store.active then return fail('active') end
    if store.blocked_reason then return fail('blocked') end
    local primary, primary_why = primary_source()
    if not primary then return fail('import_incomplete', primary_why) end
    if primary.status == 'blocked' then return fail('blocked') end
    if primary.status == 'evidence' then return fail('import_incomplete') end
    local incomplete, incomplete_why = query(db,
      'SELECT count(*) AS n FROM relay_import_units WHERE source_id=? AND done=0',
      { primary.source_id })
    if not incomplete then return fail('verify', incomplete_why) end
    if incomplete[1].n ~= 0 then return fail('import_incomplete') end
    local last = 0
    while true do
      local units, unit_why = query(db,
        'SELECT unit_id,root_field,kind,parent_key,nested,expected FROM relay_import_units ' ..
          'WHERE source_id=? AND unit_id>? ORDER BY unit_id LIMIT 1',
        { primary.source_id, last })
      if not units then return fail('verify', unit_why) end
      local unit = units[1]
      if not unit then break end
      last = unit.unit_id
      local namespace = unit.kind == 'raw' and ('unknown:' .. unit.root_field) or unit.root_field
      local counted, count_why = query(db,
        'SELECT count(*) AS n FROM relay_records WHERE namespace=? AND parent_key=?',
        { namespace, unit.parent_key or '' })
      if not counted then return fail('verify', count_why) end
      if counted[1].n ~= unit.expected then return fail('import_incomplete', namespace) end
      local unit_ok, unit_why = verify_unit(unit, primary.source_id)
      if not unit_ok then return fail('import_incomplete', namespace .. ':' .. tostring(unit_why)) end
    end
    local cursor_fields, cursor_field_why = query(db,
      'SELECT path,kind FROM relay_source_fields WHERE source_id=? ' ..
        'AND (path=\'$.since\' OR path=\'$.messages_since\') ORDER BY path',
      { primary.source_id })
    if not cursor_fields then return fail('verify', cursor_field_why) end
    for _, field in ipairs(cursor_fields) do
      local scope = field.path == '$.since' and 'sync' or 'messages'
      local expected, expected_why = query(db,
        'SELECT s.raw -> ? AS value FROM relay_import_source s WHERE s.source_id=?',
        { field.path, primary.source_id })
      if not expected then return fail('verify', expected_why) end
      local stored, stored_why = query(db,
        'SELECT present,cursor_json FROM relay_cursors WHERE scope=?', { scope })
      if not stored then return fail('verify', stored_why) end
      if not stored[1] or stored[1].present ~= 1
          or stored[1].cursor_json ~= expected[1].value then
        return fail('import_incomplete', 'cursor:' .. scope)
      end
    end
    local records, records_why = query(db, 'SELECT count(*) AS n FROM relay_records')
    if not records then return fail('verify', records_why) end
    if records[1].n ~= primary.staged_count then return fail('import_incomplete', 'row_count') end
    local event_count, event_why = query(db,
      'SELECT count(*) AS n FROM relay_events')
    if not event_count then return fail('verify', event_why) end
    local pending_records, pending_why = query(db,
      'SELECT count(*) AS n FROM relay_records WHERE namespace=\'pending_events\'')
    if not pending_records then return fail('verify', pending_why) end
    if event_count[1].n ~= pending_records[1].n then return fail('import_incomplete', 'pending') end
    local intent_count, intent_why = query(db,
      'SELECT count(*) AS n FROM relay_reply_intents WHERE imported=1')
    if not intent_count then return fail('verify', intent_why) end
    local outbox_records, outbox_why = query(db,
      'SELECT count(*) AS n FROM relay_records WHERE namespace=\'matrix_reply_outbox\'')
    if not outbox_records then return fail('verify', outbox_why) end
    if intent_count[1].n ~= outbox_records[1].n then return fail('import_incomplete', 'outbox') end
    local began = begin(db)
    if not began then return fail('verify_begin') end
    local verified = exec(db,
      'UPDATE relay_import_source SET status=\'verified\',verified_count=staged_count ' ..
        'WHERE source_id=? AND status IN (\'importing\',\'staged\')', { primary.source_id })
    if verified ~= 1 then rollback(db); return fail('verify_update') end
    local authority = exec(db,
      'UPDATE relay_authority SET import_verified=1,source_stamp=source_stamp ' ..
        'WHERE singleton=1 AND phase=\'importing\'')
    if authority ~= 1 then rollback(db); return fail('verify_authority') end
    local cleared = exec(db, 'DELETE FROM relay_import_queue WHERE source_id=?',
      { primary.source_id })
    if cleared == nil then rollback(db); return fail('verify_queue') end
    local done = commit(db)
    if not done then rollback(db); return fail('verify_commit') end
    return { verified = true, count = tonumber(primary.staged_count) or 0 }
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
    local raw = marker_encode(store.store_id, store.owner_id, store.epoch, auth.source_stamp)
    if not raw or #raw > limits.marker_bytes then return fail('marker_size') end
    local marker_fault = fault('active_marker_publish', { raw = raw })
    if marker_fault then return fail('marker_publish', marker_fault.code) end
    local began = begin(db)
    if not began then return fail('activate_begin') end
    local changed = exec(db,
      'UPDATE relay_authority SET phase=\'active\',import_verified=1,blocked_reason=NULL ' ..
        'WHERE singleton=1 AND phase=\'importing\' AND store_id=? AND owner_id=? AND epoch=?',
      { store.store_id, store.owner_id, store.epoch })
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
        'WHERE namespace=? AND parent_key=? AND (? IS NULL OR ?=\'\' OR ' ..
        '(ordinal IS NOT NULL AND ordinal>CAST(? AS INTEGER)) OR ' ..
        '(ordinal IS NULL AND record_key>?)) ' ..
        'ORDER BY CASE WHEN ordinal IS NULL THEN 0 ELSE 1 END,ordinal,record_key LIMIT ?',
      { namespace, parent, after, after, after, after, limit })
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
