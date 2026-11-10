-- Automatic, restartable legacy JSON -> relay store migration.
--
-- The caller supplies a proven exclusive cold-start owner, the active store
-- capability, and file/digest providers. This module never calls legacy
-- load_state, never merges .bak, and never deletes the source sidecars. It only
-- stages raw bytes through the store's bounded import API. A crash resumes from
-- store progress; a changed source is refused by the store.
local M = {}

local function read_file(path)
  local file, err = io.open(path, 'rb')
  if not file then return nil, tostring(err) end
  local raw = file:read('*a')
  file:close()
  if raw == nil then return nil, 'read failed' end
  return raw
end

local function read_provider(opts, path)
  if opts.fs and type(opts.fs.read) == 'function' then
    local ok, raw, err = pcall(opts.fs.read, path)
    if not ok then return nil, tostring(raw) end
    return raw, err
  end
  return read_file(path)
end

local function read_chunk(opts, path, offset, limit)
  if opts.fs and type(opts.fs.read_range) == 'function' then
    local ok, chunk, err = pcall(opts.fs.read_range, path, offset, limit)
    if not ok then return nil, tostring(chunk) end
    if chunk == nil then return nil, tostring(err or 'read_range') end
    return chunk
  end
  local file, err = io.open(path, 'rb')
  if not file then return nil, tostring(err) end
  local size = file:seek('end')
  if offset > size then file:close(); return nil, 'offset' end
  local seeked, seek_err = file:seek('set', offset)
  if not seeked then file:close(); return nil, tostring(seek_err) end
  local chunk = offset == size and '' or file:read(limit)
  file:close()
  if chunk == nil then return nil, 'read' end
  if #chunk > limit then return nil, 'oversize' end
  return chunk
end

local function file_size(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local size = file:seek('end')
  file:close()
  return size
end

local function sha(opts, raw)
  local digest = opts.digest and opts.digest.sha256
  if type(digest) ~= 'function' then return nil, 'digest provider missing' end
  local ok, value, err = pcall(digest, raw)
  if not ok then return nil, tostring(value) end
  if type(value) ~= 'string' then return nil, tostring(err or 'digest failed') end
  return value
end

local function source_stamp(opts, raw)
  if type(opts.source_stamp) == 'string' and opts.source_stamp ~= '' then
    return opts.source_stamp
  end
  return sha(opts, raw)
end

-- Bounded startup step. One call performs at most ONE store action, so a caller
-- never drives a whole 9MB source or its verify loop inside a single turn.
-- `job` is the caller's durable ref record (plain fields only, never mailbox
-- content) and is updated in place. Stamps come from source-set metadata; this
-- path never hashes a whole source and never asks for a caller-supplied
-- exclusive_owner boolean.
local STEP_PHASES = { prepare = true, admit = true, ingest = true, batch = true,
  verify = true, activate = true, proof = true, done = true }

local function readable(path)
  local file = io.open(path, 'rb')
  if not file then return false end
  file:close()
  return true
end

local function step_sources(opts)
  local function add(list, path, stamp, id, role)
    if path == nil or path == '' then return true end
    if type(path) ~= 'string' then return nil, id .. '_path' end
    if type(stamp) ~= 'string' or stamp == '' then return nil, id .. '_stamp' end
    list[#list + 1] = { id = id, role = role, path = path, stamp = stamp,
      state = 'pending', optional = role ~= 'primary' }
    return true
  end
  local sources = {}
  local ok, why = add(sources, opts.since_path, opts.since_stamp, 'legacy-primary',
    'primary')
  if not ok then return nil, why end
  if not sources[1] then return nil, 'since_path' end
  ok, why = add(sources, opts.backup_path, opts.backup_stamp, 'legacy-backup',
    'backup_evidence')
  if not ok then return nil, why end
  ok, why = add(sources, opts.ack_path, opts.ack_stamp, 'legacy-acks', 'acks')
  if not ok then return nil, why end
  ok, why = add(sources, opts.drain_path, opts.drain_stamp, 'legacy-drain', 'drain')
  if not ok then return nil, why end
  -- The source set is fixed at prepare. A missing primary refuses; a missing
  -- optional sidecar is omitted (not invented as an empty row). Empty existing
  -- ack/drain files still enter the set as valid 0-byte artifacts.
  local primary_size = file_size(sources[1].path)
  if primary_size == nil then return nil, 'primary_missing' end
  sources[1].bytes = primary_size
  local present = { sources[1] }
  for index = 2, #sources do
    local size = file_size(sources[index].path)
    if size ~= nil then
      sources[index].bytes = size
      present[#present + 1] = sources[index]
    end
  end
  return present
end

local function first_in(job, state)
  for _, source in ipairs(job.sources or {}) do
    if source.state == state then return source end
  end
  return nil
end

local function step_result(job, action, detail)
  local result = { phase = job.phase, action = action, done = job.phase == 'done' }
  if detail then
    for key, value in pairs(detail) do
      if key ~= 'job' then result[key] = value end
    end
  end
  return result
end

-- step(store, job, opts) -> {phase,action,done,...} | nil, reason[, detail]
-- Opts: since_path/since_stamp (required), backup/ack/drain path+stamp pairs,
-- fs={read}, batch_limit<=64, verify={max_rows,...}.
function M.step(store, job, opts)
  if type(store) ~= 'table' or type(job) ~= 'table' then return nil, 'options' end
  opts = type(opts) == 'table' and opts or {}
  if job.phase ~= nil and not STEP_PHASES[job.phase] then return nil, 'job_phase' end
  if job.phase == nil then
    local sources, source_why = step_sources(opts)
    if not sources then return nil, source_why end
    local limit = tonumber(opts.batch_limit) or 64
    if limit < 1 or limit > 64 or limit % 1 ~= 0 then return nil, 'batch_limit' end
    local manifest = { sources = {}, legacy_owners_quiescent = true,
      external_fence_verified = true }
    for _, source in ipairs(sources) do
      -- Sidecar ack/drain rows are captured and verified through relay_sidecar
      -- and are not manifest sources; only the primary and backup evidence are.
      if source.role == 'primary' or source.role == 'backup_evidence' then
        manifest.sources[#manifest.sources + 1] = { id = source.id,
          role = source.role, stamp = source.stamp }
      end
    end
    manifest.source_stamp = sources[1].stamp
    local prepared, prepare_why = store:import_prepare(manifest)
    if not prepared then return nil, prepare_why end
    job.sources, job.batch_limit, job.phase = sources, limit, 'admit'
    return step_result(job, 'prepare')
  end
  if job.phase == 'admit' then
    local source
    for _, item in ipairs(job.sources or {}) do
      if item.state == 'pending' or item.state == 'streaming'
          or item.state == 'stream_finish' then
        source = item
        break
      end
    end
    if not source then job.phase = 'ingest'; return step_result(job, 'admit_skip') end
    local kind = (source.role == 'acks' or source.role == 'drain')
      and 'sidecar' or 'source'
    if source.state == 'pending' then
      local receipt, begin_why, detail = store:import_stream_begin(source.id,
        kind, source.bytes, { stamp = source.stamp })
      if not receipt then return nil, begin_why, detail end
      source.ingest_id = receipt.ingest_id
      source.offset, source.part, source.state = 0, 0, 'streaming'
      return step_result(job, 'admit_begin', { source_id = source.id,
        ingest_id = receipt.ingest_id, bytes = source.bytes })
    end
    if source.state == 'streaming' then
      if source.offset >= source.bytes then
        source.state = 'stream_finish'
        return step_result(job, 'stream_done', { source_id = source.id,
          bytes = source.bytes, parts = source.part })
      end
      local remaining = math.min(65536, source.bytes - source.offset)
      local chunk, read_why = read_chunk(opts, source.path, source.offset, remaining)
      if chunk == nil then return nil, source.id .. '_read', { reason = read_why } end
      if #chunk == 0 then
        source.state = 'stream_finish'
        return step_result(job, 'stream_done', { source_id = source.id,
          bytes = source.bytes, parts = source.part })
      end
      source.part = source.part + 1
      local receipt, chunk_why, detail = store:import_stream_chunk(
        source.ingest_id, source.part, chunk)
      if not receipt then return nil, chunk_why, detail end
      source.offset = source.offset + #chunk
      return step_result(job, 'admit_chunk', { source_id = source.id,
        ingest_id = source.ingest_id, part = source.part, part_bytes = #chunk,
        offset = source.offset })
    end
    local receipt, finish_why, detail = store:import_stream_finish(source.ingest_id)
    if not receipt then return nil, finish_why, detail end
    source.state = 'admitted'
    return step_result(job, 'admit_finish', { source_id = source.id,
      ingest_id = source.ingest_id, phase_name = receipt.phase })
  end
  if job.phase == 'ingest' then
    local source = first_in(job, 'admitted')
    if not source then job.phase = 'batch'; return step_result(job, 'ingest_skip') end
    local receipt, ingest_why, detail = store:ingest_step(source.ingest_id)
    if not receipt then return nil, ingest_why, detail end
    if receipt.done or receipt.phase == 'READY' then source.state = 'ready' end
    source.revision = receipt.revision
    return step_result(job, 'ingest', { source_id = source.id,
      ingest_id = source.ingest_id, revision = receipt.revision,
      state = receipt.state, phase_name = receipt.phase,
      count = receipt.count, bytes = receipt.bytes, nodes = receipt.nodes })
  end
  if job.phase == 'batch' then
    local page, batch_why, detail = store:import_batch('legacy-primary', job.batch_limit)
    if not page then return nil, batch_why, detail end
    if page.done then job.phase = 'verify' end
    return step_result(job, 'batch', { count = page.count, done = page.done == true,
      state = page.state, phase_name = page.phase, ingest_id = page.ingest_id,
      revision = page.revision, rows = page.rows })
  end
  if job.phase == 'verify' then
    local page, verify_why, detail = store:verify_import(opts.verify)
    if not page then return nil, verify_why, detail end
    if page.verified == true then
      job.certificate_id, job.verification_id = page.certificate_id, page.verification_id
      job.phase = 'activate'
    elseif page.state ~= 'backlog' then
      return nil, 'verify_state', { state = page.state, phase = page.phase }
    end
    return step_result(job, 'verify', { verified = page.verified == true,
      state = page.state, phase_name = page.phase, revision = page.revision,
      processed_rows = page.processed_rows, bytes = page.bytes, nodes = page.nodes,
      certificate_id = page.certificate_id, verification_id = page.verification_id })
  end
  if job.phase == 'activate' then
    local writer, activate_why = store:activate()
    if not writer then return nil, activate_why end
    job.writer = true
    job.phase = 'proof'
    return step_result(job, 'activate')
  end
  if job.phase == 'proof' then
    if type(job.certificate_id) ~= 'string' or job.certificate_id == '' then
      return nil, 'certificate_missing'
    end
    local proof, proof_why = store:proof(job.certificate_id)
    if not proof then return nil, proof_why end
    job.proof_store_id, job.proof_revision = proof.store_id, proof.revision
    job.proof_data_revision = proof.data_revision
    job.phase = 'done'
    return step_result(job, 'proof', { certificate_id = job.certificate_id,
      store_id = proof.store_id, revision = proof.revision,
      data_revision = proof.data_revision })
  end
  return step_result(job, 'done')
end

-- Advance one admitted artifact (backup evidence or ack sidecar) to READY.
-- The primary JSON source is driven by import_batch instead.
local function drive_ingest(store, receipt)
  local current = receipt
  for _ = 1, 1000000 do
    if type(current) ~= 'table' or current.done then return current end
    local next_receipt, why = store:ingest_step(current.ingest_id)
    if not next_receipt then return nil, why end
    current = next_receipt
  end
  return nil, 'ingest_call_limit'
end

-- opts = {
--   store, exclusive_owner (must come from the owner provider, not a caller
--   boolean), since_path, ack_path, drain_path (optional), backup_path
--   (optional), fs={read}, digest={sha256}, checkpoint=function(stats)->bool,
--   activate=true|false, batch_limit<=64
-- }
function M.run(opts)
  if type(opts) ~= 'table' or type(opts.store) ~= 'table' then
    return nil, 'options'
  end
  if opts.exclusive_owner ~= true then return nil, 'owner_not_exclusive' end
  local store = opts.store
  local status = store.status and store:status()
  if type(status) == 'table' and status.phase == 'active' then
    return { status = 'active', writer = store:writer() }
  end
  if type(status) == 'table' and (status.phase == 'blocked' or status.blocked) then
    return nil, 'blocked'
  end
  if type(opts.since_path) ~= 'string' or opts.since_path == '' then
    return nil, 'since_path'
  end
  local raw, read_err = read_provider(opts, opts.since_path)
  if raw == nil then
    -- A missing primary is not permission to restore .bak. Backup evidence may
    -- be retained, but no authority is created from it.
    if opts.backup_path then
      local backup = read_provider(opts, opts.backup_path)
      if backup ~= nil then return nil, 'primary_missing_backup_present' end
    end
    return nil, 'primary_missing'
  end
  local stamp, stamp_err = source_stamp(opts, raw)
  if not stamp then return nil, stamp_err end
  local sources = { { id = 'legacy-primary', role = 'primary', stamp = stamp } }
  local backup
  if type(opts.backup_path) == 'string' and opts.backup_path ~= '' then
    backup = read_provider(opts, opts.backup_path)
    if backup ~= nil then
      local backup_stamp = sha(opts, backup)
      if not backup_stamp then return nil, 'backup_digest' end
      sources[#sources + 1] = { id = 'legacy-backup', role = 'backup_evidence',
        stamp = backup_stamp }
    end
  end
  local prepared, prepare_err = store:import_prepare({
    source_id = 'legacy-primary', source_stamp = stamp, sources = sources,
    legacy_owners_quiescent = true, external_fence_verified = true,
  })
  if not prepared then return nil, prepare_err end
  local imported, import_err = store:import_source('legacy-primary', raw)
  if not imported then return nil, import_err end
  if backup ~= nil then
    local backup_receipt, backup_err = store:import_source('legacy-backup', backup)
    if not backup_receipt then return nil, backup_err end
    if type(backup_receipt) == 'table' and backup_receipt.ingest_id then
      local driven, drive_err = drive_ingest(store, backup_receipt)
      if not driven then return nil, drive_err end
    end
  end
  local limit = tonumber(opts.batch_limit) or 64
  if limit < 1 or limit > 64 or limit % 1 ~= 0 then return nil, 'batch_limit' end
  local batches, rows = 0, 0
  while true do
    local page, page_err = store:import_batch('legacy-primary', limit)
    if not page then return nil, page_err end
    batches = batches + 1
    rows = rows + (tonumber(page.count) or 0)
    if opts.checkpoint and opts.checkpoint({ batches = batches, rows = rows }) == false then
      return { status = 'paused', batches = batches, rows = rows }
    end
    if page.done then break end
    if (tonumber(page.count) or 0) == 0
        and not (page.phase or page.state or page.ingest_id) then
      return nil, 'import_stalled'
    end
  end
  -- Sidecar acknowledgements are evidence about already staged events, so they
  -- are applied only after the primary source records exist.
  local ack_sources = {
    { id = 'legacy-acks', path = opts.ack_path, stamp = 'acks' },
    { id = 'legacy-drain', path = opts.drain_path, stamp = 'drain' },
  }
  for _, ack in ipairs(ack_sources) do
    if type(ack.path) == 'string' and ack.path ~= '' then
      local ack_raw = read_provider(opts, ack.path)
      if ack_raw ~= nil then
        local ack_stamp = sha(opts, ack_raw)
        if not ack_stamp then return nil, ack.id .. '_digest' end
        local ack_receipt, ack_err = store:import_acks(ack.id, ack_raw, ack_stamp)
        if not ack_receipt then return nil, ack_err end
        if type(ack_receipt) == 'table' and ack_receipt.ingest_id then
          local driven, drive_err = drive_ingest(store, ack_receipt)
          if not driven then return nil, drive_err end
        end
      end
    end
  end
  -- Verification is bounded per call (default 64 records). Loop until the
  -- store returns a ready certificate; an ambiguous COMMIT is returned to the
  -- caller for an explicit reopen/recovery, never guessed here.
  local verify_calls, verified = 0, nil
  while true do
    local page, verify_err, detail = store:verify_import(opts.verify)
    if not page then
      if verify_err == 'unknown_commit' then return nil, 'unknown_commit', detail end
      return nil, verify_err
    end
    verify_calls = verify_calls + 1
    if verify_calls > 1000000 then return nil, 'verify_call_limit' end
    if opts.checkpoint and opts.checkpoint({ batches = batches, rows = rows,
        verify_calls = verify_calls, verified = page.verified == true }) == false then
      return { status = 'paused', batches = batches, rows = rows, verify_calls = verify_calls }
    end
    if page.verified == true then verified = page; break end
    if page.state ~= 'backlog' then return nil, 'verify_state' end
  end
  if opts.activate == false then
    return { status = 'verified', batches = batches, rows = rows,
      verify_calls = verify_calls, certificate_id = verified.certificate_id }
  end
  local writer, activate_err = store:activate()
  if not writer then return nil, activate_err end
  return { status = 'active', writer = writer, batches = batches, rows = rows,
    verify_calls = verify_calls, certificate_id = verified.certificate_id }
end

return M
