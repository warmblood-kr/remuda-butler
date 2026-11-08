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
    local backup_ok, backup_err = store:import_source('legacy-backup', backup)
    if not backup_ok then return nil, backup_err end
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
    if (tonumber(page.count) or 0) == 0 then return nil, 'import_stalled' end
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
        local ack_ok, ack_err = store:import_acks(ack.id, ack_raw, ack_stamp)
        if not ack_ok then return nil, ack_err end
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
