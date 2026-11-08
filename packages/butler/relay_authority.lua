-- Relay startup authority: backend selection, durable startup job and the
-- single bounded store step that admits/imports/verifies/activates the relay.
--
-- This module is deliberately dependency-injected. The owner capability, the
-- SQL store opener, the inbox producer proof and the filesystem are supplied by
-- the caller. Nothing here invents an owner, reads the inbox shadow counts, or
-- loads the legacy JSON state: a missing positive proof blocks before poll.
local M = {}

local function load_migrate(deps)
  local module = deps and deps.migrate
  if type(module) == 'table' and type(module.step) == 'function' then return module end
  local ok, loaded = pcall(require, 'butler.relay_store_migrate')
  if ok and type(loaded) == 'table' and type(loaded.step) == 'function' then
    return loaded
  end
  return nil
end

local HEX64 = '^[0-9a-f]+$'

local function is_int(value)
  return type(value) == 'number' and value % 1 == 0
end

local function identifier(value)
  return type(value) == 'string' and value ~= ''
end

local function hex64(value)
  return type(value) == 'string' and #value == 64 and value:match(HEX64) ~= nil
end

local function dec(value) return string.format('%.0f', tonumber(value) or 0) end

-- Exact producer framing: each value is length-prefixed, concatenated with no
-- separator. This mirrors the inbox compatibility proof so a substituted or
-- truncated field changes the digest.
local function frame(values)
  local out = {}
  for index = 1, #values do out[index] = #values[index] .. ':' .. values[index] end
  return table.concat(out)
end

local function sha(deps, text)
  local digest = deps and deps.digest and deps.digest.sha256
  if type(digest) ~= 'function' then return nil, 'digest_missing' end
  local ok, value = pcall(digest, text)
  if not ok or type(value) ~= 'string' or #value ~= 64 then return nil, 'digest_failed' end
  return value
end

local function proof_reason(err)
  if type(err) == 'table' then return tostring(err.code or err.field or 'unavailable') end
  return tostring(err or 'unavailable')
end

-- Consume the REAL inbox producer proof. Every field is checked individually
-- and the framed compatibility hash plus its ready/payload inputs are
-- recomputed. A bare boolean, a cached status, a count or a standalone hash
-- never passes.
function M.assert_inbox_compatible(cfg, proof, deps)
  if type(proof) ~= 'table' then return nil, 'proof_missing' end
  if proof.state ~= nil and proof.state ~= 'active' then
    return nil, 'proof_state:' .. tostring(proof.reason or proof.reason_field or 'blocked')
  end
  if proof.contract ~= 'inbox-compatibility-v1' then return nil, 'proof_contract' end
  if proof.authority ~= 'sql' then return nil, 'proof_authority' end
  if proof.format_version ~= 1 then return nil, 'proof_format_version' end
  if proof.protocol ~= 'sql-inbox-v1' then return nil, 'proof_protocol' end
  if not is_int(proof.schema_version) or proof.schema_version < 1 then
    return nil, 'proof_schema_version'
  end
  if not identifier(proof.importer_version) then return nil, 'proof_importer_version' end
  if not identifier(proof.root) then return nil, 'proof_root' end
  local expected_root = cfg and (cfg.inbox_root or cfg.root)
  if expected_root ~= nil and proof.root ~= expected_root then
    return nil, 'proof_root_mismatch'
  end
  if not identifier(proof.store_id) then return nil, 'proof_store_id' end
  if not identifier(proof.owner_id) then return nil, 'proof_owner_id' end
  if not is_int(proof.epoch) or proof.epoch < 1 then return nil, 'proof_epoch' end
  if not identifier(proof.generation) then return nil, 'proof_generation' end
  if not identifier(proof.source_set_id) then return nil, 'proof_source_set_id' end
  if not is_int(proof.revision) or proof.revision < 0 then return nil, 'proof_revision' end
  if not is_int(proof.data_revision) or proof.data_revision < 0 then
    return nil, 'proof_data_revision'
  end
  if not is_int(proof.tail_watermark) or proof.tail_watermark < 0 then
    return nil, 'proof_tail_watermark'
  end
  if not identifier(proof.certificate_id) then return nil, 'proof_certificate_id' end
  if not identifier(proof.verification_id) then return nil, 'proof_verification_id' end
  if not hex64(proof.proof_hash) then return nil, 'proof_hash' end
  if not hex64(proof.compatibility_hash) then return nil, 'proof_compatibility_hash' end
  local capabilities = proof.capabilities
  if type(capabilities) ~= 'table' or capabilities.external_accept ~= true
      or capabilities.legacy_bridge_original_id ~= true then
    return nil, 'proof_capabilities'
  end
  local marker, ready, auth = proof.marker, proof.ready, proof.authority_row
  if type(marker) == 'table' then
    if marker.state ~= 'SQL_ACTIVE' or marker.origin ~= 'migration'
        or marker.generation ~= proof.generation
        or tonumber(marker.epoch) ~= proof.epoch
        or marker.operation_id == nil or marker.proof_hash ~= proof.proof_hash
        or tonumber(marker.tail_watermark) ~= proof.tail_watermark then
      return nil, 'proof_marker_conflict'
    end
  end
  if type(auth) == 'table' then
    if auth.root ~= proof.root or tonumber(auth.epoch) ~= proof.epoch
        or auth.generation ~= proof.generation or auth.proof_hash ~= proof.proof_hash
        or tonumber(auth.tail_watermark) ~= proof.tail_watermark then
      return nil, 'proof_authority_conflict'
    end
  end
  if type(ready) ~= 'table' then return nil, 'proof_ready' end
  if ready.complete ~= 1 then return nil, 'proof_ready_incomplete' end
  if ready.certificate_id ~= proof.certificate_id then
    return nil, 'proof_ready_certificate'
  end
  if not is_int(ready.certificate_revision) or ready.certificate_revision < 0 then
    return nil, 'proof_ready_certificate_revision'
  end
  if ready.proof_hash ~= proof.proof_hash
      or ready.generation ~= proof.generation
      or ready.root ~= proof.root
      or tonumber(ready.target_epoch) ~= proof.epoch
      or tonumber(ready.tail_watermark) ~= proof.tail_watermark then
    return nil, 'proof_ready_conflict'
  end
  if ready.operation_id == nil or ready.operation_id == '' then
    return nil, 'proof_ready_operation'
  end
  if not hex64(ready.base_hash) or not hex64(ready.tail_hash) then
    return nil, 'proof_ready_hash'
  end
  if not is_int(ready.stage_revision) or ready.stage_revision < 0 then
    return nil, 'proof_ready_revision'
  end
  if ready.stage_revision ~= proof.revision then return nil, 'proof_ready_revision_conflict' end
  if not hex64(ready.payload_hash) then return nil, 'proof_ready_payload' end
  local ready_proof, ready_why = sha(deps, frame({ 'ready-v1', proof.root,
    proof.generation, dec(ready.target_epoch), ready.base_hash,
    dec(ready.tail_watermark), ready.tail_hash, dec(ready.stage_revision) }))
  if not ready_proof then return nil, ready_why end
  if ready_proof ~= ready.proof_hash then return nil, 'proof_ready_digest' end
  local payload, payload_why = sha(deps, frame({ 'inbox-cutover-payload-v1',
    ready.operation_id, proof.proof_hash, dec(ready.tail_watermark) }))
  if not payload then return nil, payload_why end
  if payload ~= ready.payload_hash then return nil, 'proof_payload_digest' end
  local material = table.concat({ 'butler-inbox-compat-v1', proof.store_id,
    proof.owner_id, dec(proof.epoch), proof.generation, proof.source_set_id,
    dec(proof.revision), dec(proof.data_revision), dec(proof.tail_watermark),
    proof.certificate_id, proof.verification_id, proof.proof_hash,
    proof.protocol }, '\0')
  local digest, digest_why = sha(deps, material)
  if not digest then return nil, digest_why end
  if digest ~= proof.compatibility_hash then
    return nil, 'proof_compatibility_digest'
  end
  return true
end

local function provider_missing(deps)
  if type(deps) ~= 'table' then return 'deps' end
  if type(deps.open_store) ~= 'function' then return 'open_store' end
  if type(deps.digest) ~= 'table' or type(deps.digest.sha256) ~= 'function' then
    return 'digest'
  end
  if type(deps.fs) ~= 'table' or type(deps.fs.write_atomic) ~= 'function' then
    return 'fs'
  end
  if type(deps.identity) ~= 'table' then return 'identity' end
  for _, name in ipairs({ 'root_id', 'account_id', 'device_id', 'relay_id' }) do
    if not identifier(deps.identity[name]) then return 'identity.' .. name end
  end
  if type(deps.json) ~= 'table' or type(deps.json.encode) ~= 'function' then
    return 'json'
  end
  if load_migrate(deps) == nil then return 'migrate' end
  local owner = deps.owner
  if type(owner) ~= 'table' then return 'owner' end
  for _, name in ipairs({ 'acquire', 'check', 'describe', 'release' }) do
    if type(owner[name]) ~= 'function' then return 'owner.' .. name end
  end
  return nil
end

local function job_path(cfg)
  return cfg.job_path or (cfg.config_path .. '.relay-job')
end

local function job_id_for(deps, cfg)
  local digest = deps.digest.sha256
  local material = tostring(cfg.config_path) .. '\0' .. deps.identity.root_id ..
    '\0' .. deps.identity.account_id .. '\0' .. deps.identity.device_id ..
    '\0' .. deps.identity.relay_id
  local ok, value = pcall(digest, material)
  if ok and type(value) == 'string' and value ~= '' then return 'job:' .. value end
  return 'job:' .. tostring(cfg.config_path)
end

local jobs = {}
local active

local function persist(entry)
  local json = entry.deps.json
  if type(json) ~= 'table' or type(json.encode) ~= 'function' then
    return nil, 'json_missing'
  end
  local ok, text = pcall(json.encode, entry.job)
  if not ok or type(text) ~= 'string' then return nil, 'job_encode' end
  local wrote, write_why = entry.deps.fs.write_atomic(job_path(entry.cfg), text,
    { private = true })
  if not wrote then return nil, tostring(write_why or 'job_write') end
  return true
end

-- Restart resumes the SAME content-free job refs. This is a tiny metadata file
-- (paths, stamps, certificate ids), never mailbox content and never the legacy
-- whole-state JSON.
local function load_job(cfg, deps, job_id)
  local path = job_path(cfg)
  local raw
  if type(deps.fs.read) == 'function' then
    local ok, value = pcall(deps.fs.read, path)
    if ok then raw = value end
  else
    local file = io.open(path, 'rb')
    if file then raw = file:read(262144); file:close() end
  end
  if type(raw) ~= 'string' or raw == '' or #raw > 262144 then return nil end
  local json = deps.json
  if type(json) ~= 'table' or type(json.decode) ~= 'function' then return nil end
  local ok, job = pcall(json.decode, raw)
  if not ok or type(job) ~= 'table' or job.id ~= job_id
      or job.config_path ~= cfg.config_path or type(job.sources) ~= 'table' then
    return nil
  end
  return job
end

local function lookup(job_id)
  local entry = jobs[job_id]
  if entry then return entry end
  return nil, 'job_unknown'
end

-- start(cfg, deps) -> receipt | nil, 'blocked: reason'
-- No store is opened, no marker published and no poll begins until the real
-- inbox producer proof and a real owner provider are present and compatible.
function M.start(cfg, deps)
  if type(cfg) ~= 'table' or not identifier(cfg.config_path) then
    return nil, 'blocked: config'
  end
  if type(deps) ~= 'table' or type(deps.inbox_proof) ~= 'function' then
    return nil, 'blocked: inbox_proof_missing'
  end
  local missing = provider_missing(deps)
  if missing then return nil, 'blocked: ' .. missing .. '_missing' end
  local proof, proof_err = deps.inbox_proof()
  if type(proof) ~= 'table' then
    return nil, 'blocked: inbox_proof_' .. proof_reason(proof_err)
  end
  local compatible, why = M.assert_inbox_compatible(cfg, proof, deps)
  if not compatible then return nil, 'blocked: inbox_' .. tostring(why) end
  local job_id = job_id_for(deps, cfg)
  local entry = jobs[job_id]
  if not entry then
    local store, store_why = deps.open_store(cfg, deps)
    if not store then
      return nil, 'blocked: store_' .. tostring(store_why or 'open')
    end
    entry = { job_id = job_id, cfg = cfg, deps = deps, store = store,
      job = load_job(cfg, deps, job_id) or
        { id = job_id, config_path = cfg.config_path,
          inbox_root = proof.root, source_stamps = cfg.source_stamps,
          verify = cfg.verify, batch_limit = cfg.batch_limit } }
    jobs[job_id] = entry
  end
  entry.deps, entry.cfg = deps, cfg
  if entry.job.inbox_root ~= proof.root then
    return nil, 'blocked: inbox_root_changed'
  end
  active = entry
  local wrote, write_why = persist(entry)
  if not wrote then return nil, 'blocked: job_' .. tostring(write_why) end
  return { backend = 'sql', store = entry.store, writer = entry.job.writer,
    job_id = job_id, phase = entry.job.phase or 'inventory', proof = proof,
    job = entry.job }
end

local function step_opts(entry, budget)
  local job, cfg = entry.job, entry.cfg
  local stamps = job.source_stamps or cfg.source_stamps or {}
  local opts = { since_path = cfg.since_path or (cfg.config_path .. '.since'),
    since_stamp = stamps.since,
    backup_path = cfg.backup_path or (stamps.backup and
      (cfg.config_path .. '.since.bak') or nil), backup_stamp = stamps.backup,
    ack_path = cfg.ack_path or (stamps.acks and
      (cfg.config_path .. '.acks') or nil), ack_stamp = stamps.acks,
    drain_path = cfg.drain_path or (stamps.drain and
      (cfg.config_path .. '.acks.drain') or nil), drain_stamp = stamps.drain,
    fs = entry.deps.fs, batch_limit = budget and budget.batch_limit or job.batch_limit,
    verify = budget and budget.verify or job.verify }
  for key, value in pairs(budget or {}) do
    if key ~= 'batch_limit' and key ~= 'verify' then opts[key] = value end
  end
  return opts
end

-- advance(job_id, budget) -> exactly ONE bounded store action.
function M.advance(job_id, budget)
  local entry, why = lookup(job_id)
  if not entry then return nil, why end
  local migrate = load_migrate(entry.deps)
  if not migrate then return nil, 'migrate_missing' end
  local result, step_why, detail = migrate.step(entry.store, entry.job,
    step_opts(entry, budget))
  if not result then return nil, step_why, detail end
  local wrote, write_why = persist(entry)
  if not wrote then return nil, 'job_' .. tostring(write_why) end
  result.job_id = job_id
  result.done = entry.job.phase == 'done'
  result.phase = entry.job.phase
  result.certificate_id = entry.job.certificate_id
  return result
end

-- status(job_id) -> refs/counts only, never mailbox content.
function M.status(job_id)
  local entry, why = lookup(job_id)
  if not entry then return nil, why end
  local job = entry.job
  local result = { job_id = job_id, phase = job.phase or 'inventory',
    done = job.phase == 'done', inbox_root = job.inbox_root,
    certificate_id = job.certificate_id, verification_id = job.verification_id,
    proof_store_id = job.proof_store_id, proof_revision = job.proof_revision,
    proof_data_revision = job.proof_data_revision, writer = job.writer == true }
  if type(entry.store.status) == 'function' then
    local ok, store_status = pcall(entry.store.status, entry.store)
    if ok and type(store_status) == 'table' then result.store = store_status end
  end
  return result
end

-- Read the current relay certificate back under the current owner. This is a
-- certref for the joint coordinator; it never authorizes archive on its own.
function M.proof(job_id)
  local entry, why = lookup(job_id)
  if not entry then return nil, why end
  local job = entry.job
  if job.phase ~= 'done' or not identifier(job.certificate_id) then
    return nil, 'proof_missing'
  end
  local proof, proof_why = entry.store:proof(job.certificate_id)
  if not proof then return nil, proof_why end
  return { store_id = proof.store_id, verification_id = proof.verification_id,
    revision = proof.revision, data_revision = proof.data_revision,
    certificate_id = proof.certificate_id, witness_id = proof.witness_id,
    proof_version = proof.proof_version }
end

-- Reread one relay certificate under the current owner. The inbox coordinator
-- stores this certref instead of inventing relay verification.
function M.certificate(certificate_id)
  if type(certificate_id) ~= 'string' or certificate_id == '' then
    return nil, 'certificate_id'
  end
  if active == nil then return nil, 'authority_not_active' end
  local proof, proof_why = active.store:proof(certificate_id)
  if not proof then return nil, proof_why end
  return { store_id = proof.store_id, verification_id = proof.verification_id,
    revision = proof.revision, data_revision = proof.data_revision,
    certificate_id = proof.certificate_id, witness_id = proof.witness_id,
    proof_version = proof.proof_version }
end

-- Relay artifacts for the archive plan, as refs only. DB/WAL/SHM, the
-- authority marker, Matrix config/token and live inbox objects are excluded.
function M.inventories()
  if active == nil then return nil, 'authority_not_active' end
  local cfg = active.cfg
  return { { path = cfg.since_path or (cfg.config_path .. '.since'),
      role = 'relay_state' },
    { path = cfg.backup_path or (cfg.config_path .. '.since.bak'),
      role = 'backup_evidence' },
    { path = cfg.ack_path or (cfg.config_path .. '.acks'), role = 'ack_sidecar' },
    { path = cfg.drain_path or (cfg.config_path .. '.acks.drain'),
      role = 'drain_sidecar' } }
end

-- Central admission gate used by relay.start/relay.new (including Matrix
-- setup/restart). Installed authority modules must authorize; an install with
-- no authority keeps the legacy path unchanged for tests and old deployments.
function M.authorize(cfg)
  if active == nil then return nil, 'authority_not_active' end
  if type(cfg) ~= 'table' or cfg.config_path ~= active.cfg.config_path then
    return nil, 'authority_config_mismatch'
  end
  if active.job.phase ~= 'done' or not active.job.writer then
    return nil, 'authority_' .. tostring(active.job.phase or 'inventory')
  end
  local proof, proof_err = active.deps.inbox_proof()
  if type(proof) ~= 'table' then
    return nil, 'inbox_proof_' .. proof_reason(proof_err)
  end
  local compatible, why = M.assert_inbox_compatible(active.cfg, proof, active.deps)
  if not compatible then return nil, 'inbox_' .. tostring(why) end
  local relay_proof, relay_why = M.proof(active.job_id)
  if not relay_proof then return nil, 'relay_proof_' .. tostring(relay_why) end
  return true
end

function M.active_job()
  return active and active.job_id or nil
end

-- Exact adapter for the joint inbox startup coordinator. The coordinator binds
-- its owner/store/digest/fs providers once, then passes only the live
-- `{inbox_proof = function() ... end}` on start.
function M.adapter(providers)
  if type(providers) ~= 'table' then return nil, 'providers' end
  local bound = {}
  for key, value in pairs(providers) do bound[key] = value end
  return {
    start = function(cfg, opts)
      local deps = {}
      for key, value in pairs(bound) do deps[key] = value end
      deps.inbox_proof = opts and opts.inbox_proof or bound.inbox_proof
      return M.start(cfg, deps)
    end,
    advance = M.advance,
    certificate = M.certificate,
    proof = M.proof,
    status = M.status,
    inventories = M.inventories,
    authorize = M.authorize,
  }
end

return M
