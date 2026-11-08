-- Retained relay archive coordinator.
--
-- Planning is bound to BOTH current proofs: the relay certificate reread under
-- the current owner and the real inbox producer proof. Nothing is archived
-- from a cached status, a boolean or a count. Bytes are copied/verified through
-- injected providers; the proven shell filesystem has no generic fsync or
-- durable rename, so this module never invents one and never deletes a source.
--
-- The GO for this branch does not authorize a live archive. Until the caller
-- supplies the copy/rename/parent-sync providers, advance stays blocked and the
-- originals remain untouched.
local M = {}

local plans = {}

local function identifier(value) return type(value) == 'string' and value ~= '' end

local function hex64(value)
  return type(value) == 'string' and #value == 64 and value:match('^[0-9a-f]+$') ~= nil
end

local function relay_ok(proof)
  if type(proof) ~= 'table' then return nil, 'relay_proof_missing' end
  for _, name in ipairs({ 'store_id', 'verification_id', 'certificate_id',
      'witness_id' }) do
    if not identifier(proof[name]) then return nil, 'relay_proof_' .. name end
  end
  if type(proof.revision) ~= 'number' or type(proof.data_revision) ~= 'number' then
    return nil, 'relay_proof_revision'
  end
  if proof.proof_version ~= 5 then return nil, 'relay_proof_version' end
  return true
end

local function inbox_ok(proof)
  if type(proof) ~= 'table' then return nil, 'inbox_proof_missing' end
  if proof.contract ~= 'inbox-compatibility-v1' then return nil, 'inbox_proof_contract' end
  if proof.authority ~= 'sql' then return nil, 'inbox_proof_authority' end
  if proof.state ~= nil and proof.state ~= 'active' then
    return nil, 'inbox_proof_state'
  end
  if not hex64(proof.compatibility_hash) then return nil, 'inbox_proof_hash' end
  if type(proof.ready) ~= 'table' or proof.ready.complete ~= 1 then
    return nil, 'inbox_proof_ready'
  end
  return true
end

local function prove(input)
  local relay, relay_why = relay_ok(input.relay_proof)
  if not relay then return nil, relay_why end
  local inbox, inbox_why = inbox_ok(input.inbox_proof)
  if not inbox then return nil, inbox_why end
  local deps = input.deps
  if type(deps) ~= 'table' or type(deps.reread_proof) ~= 'function' then
    return nil, 'proof_reread_missing'
  end
  local relay_now, relay_err = deps.reread_proof('relay', input.relay_proof)
  if relay_now ~= true then return nil, 'relay_proof_' .. tostring(relay_err or 'stale') end
  local inbox_now, inbox_err = deps.reread_proof('inbox', input.inbox_proof)
  if inbox_now ~= true then return nil, 'inbox_proof_' .. tostring(inbox_err or 'stale') end
  return true
end

local function inventory(input)
  local deps, cfg = input.deps, input.cfg or {}
  if type(deps) ~= 'table' or type(deps.stat) ~= 'function' then
    return nil, 'stat_provider_missing'
  end
  local base = cfg.config_path or input.config_path
  if not identifier(base) and type(input.base_path) ~= 'string' then
    return nil, 'config_path'
  end
  base = base or input.base_path
  local files = {
    { path = cfg.since_path or (base .. '.since'), role = 'relay_state',
      required = true },
    { path = cfg.backup_path or (base .. '.since.bak'), role = 'backup_evidence' },
    { path = cfg.ack_path or (base .. '.acks'), role = 'ack_sidecar' },
    { path = cfg.drain_path or (base .. '.acks.drain'), role = 'drain_sidecar' },
  }
  local plan_files, seen = {}, {}
  for _, file in ipairs(files) do
    if seen[file.path] then return nil, 'duplicate_artifact' end
    seen[file.path] = true
    local stat, stat_why = deps.stat(file.path)
    if stat == nil then
      if file.required then return nil, 'missing:' .. file.role end
      -- A missing optional sidecar is not an empty one: leave it out.
    elseif type(stat) ~= 'table' or type(stat.size) ~= 'number'
        or stat.size < 0 or stat.size % 1 ~= 0 then
      return nil, 'stat:' .. tostring(stat_why or file.role)
    else
      plan_files[#plan_files + 1] = { relative = file.path, role = file.role,
        bytes = stat.size, state = 'planned', offset = 0 }
    end
  end
  return plan_files
end

local function destination(plan, file)
  local relative = file.relative:match('[^/]+$') or file.relative
  return plan.archive_root .. '/' .. relative
end

local function dirname(path)
  return path:match('^(.*)/[^/]*$') or '.'
end

-- plan(input) -> durable per-file plan | nil, reason
-- input = { job_id, cfg, relay_proof, inbox_proof, deps, archive_root }
function M.plan(input)
  if type(input) ~= 'table' then return nil, 'proof_missing' end
  local proven, proof_why = prove(input)
  if not proven then return nil, proof_why end
  if not identifier(input.job_id) then return nil, 'job_id' end
  local deps = input.deps
  if deps == nil then
    deps = M.providers(input.fs or remuda.fs, input.digest or remuda.digest)
    if deps == nil then return nil, 'deps_missing' end
  end
  local files, inv_why = inventory({ deps = deps, cfg = input.cfg,
    config_path = input.config_path, base_path = input.base_path })
  if not files then return nil, inv_why end
  local archive_root = input.archive_root or
    ((input.cfg and input.cfg.archive_root) or
      (dirname(input.cfg and input.cfg.config_path or input.base_path) ..
        '/archive/' .. input.job_id))
  local plan = { job_id = input.job_id, phase = 'planned',
    archive_root = archive_root, files = files, deps = deps,
    relay_certificate_id = input.relay_proof.certificate_id,
    relay_verification_id = input.relay_proof.verification_id,
    inbox_hash = input.inbox_proof.compatibility_hash or input.inbox_proof.hash,
    copied = 0, retired = 0, blocked = nil }
  plans[input.job_id] = plan
  return plan
end

-- Actual archive providers using the proven shell capabilities only:
-- fs.write_atomic/mkdir_new/realpath/lock. Bytes are read in bounded chunks and
-- staged locally; the publish step rewrites the staged bytes through
-- write_atomic (durable), verifies the exact digest, then retires the source by
-- rename. Both parents receive a durable write_atomic fence after the rename.
-- There is no generic fsync/durable_rename and none is invented.
function M.providers(fs, digest)
  if type(fs) ~= 'table' or type(fs.write_atomic) ~= 'function'
      or type(fs.mkdir_new) ~= 'function' then
    return nil, 'fs'
  end
  if type(digest) ~= 'table' or type(digest.sha256) ~= 'function' then
    return nil, 'digest'
  end
  local max_file = 32 * 1024 * 1024
  local function read_all(path, limit)
    local file, why = io.open(path, 'rb')
    if not file then return nil, tostring(why or 'open') end
    local raw = file:read('*a')
    file:close()
    if type(raw) ~= 'string' then return nil, 'read' end
    if #raw > (limit or max_file) then return nil, 'oversize' end
    return raw
  end
  local function ensure_dir(path)
    local current = path
    local missing = {}
    while current and current ~= '' and current ~= '/' and current ~= '.' do
      missing[#missing + 1] = current
      current = dirname(current)
    end
    for index = #missing, 1, -1 do
      local dir = missing[index]
      local exists = type(fs.realpath) == 'function' and fs.realpath(dir) ~= nil
      if not exists then
        local made, make_why = fs.mkdir_new(dir, { private = true })
        if not made and not tostring(make_why or ''):lower():find('exist', 1, true) then
          return nil, tostring(make_why or 'mkdir')
        end
      end
    end
    return true
  end
  local function stat(path)
    local file = io.open(path, 'rb')
    if not file then return nil, 'missing' end
    local size = file:seek('end')
    file:close()
    return { size = size }
  end
  local function digest_file(path)
    local raw, why = read_all(path)
    if not raw then return nil, why end
    local ok, value = pcall(digest.sha256, raw)
    if not ok or type(value) ~= 'string' or #value ~= 64 then return nil, 'digest' end
    return value
  end
  local function copy_chunk(src, staging, offset, limit)
    local file, why = io.open(src, 'rb')
    if not file then return nil, tostring(why or 'open') end
    local size = file:seek('end')
    if offset > size then file:close(); return nil, 'offset' end
    local ok, seek_why = file:seek('set', offset)
    if not ok then file:close(); return nil, tostring(seek_why or 'seek') end
    local chunk
    if offset == size then
      chunk = ''
    else
      chunk = file:read(limit)
      if chunk == nil then file:close(); return nil, 'read' end
    end
    file:close()
    local target
    if offset == 0 then
      target = io.open(staging, 'wb')
    else
      local size = stat(staging)
      if not size or size.size ~= offset then return nil, 'staging_mismatch' end
      target = io.open(staging, 'ab')
    end
    if not target then return nil, 'staging_open' end
    local wrote, write_why = target:write(chunk)
    target:close()
    if not wrote then return nil, tostring(write_why or 'stage_write') end
    return #chunk
  end
  local function close_copy(staging)
    local size = stat(staging)
    if not size then return nil, 'staging_missing' end
    return true
  end
  local function publish_verified(staging, verified)
    local raw, why = read_all(staging)
    if not raw then return nil, why end
    local ok, write_why = fs.write_atomic(verified, raw, { private = true })
    if not ok then return nil, tostring(write_why or 'publish') end
    return true
  end
  local function rename_once(src, verified, retained)
    local src_digest, src_why = digest_file(src)
    if not src_digest then return nil, src_why end
    local verified_digest, verified_why = digest_file(verified)
    if not verified_digest then return nil, verified_why end
    if src_digest ~= verified_digest then return nil, 'verified_mismatch' end
    local existing = stat(retained)
    if existing then
      local same, same_why = digest_file(retained)
      if not same then return nil, same_why end
      if same ~= src_digest then return nil, 'collision' end
      -- Exact retained destination is reusable. The source path already has a
      -- durable identical retained artifact, so it is retired without deleting
      -- or overwriting either copy.
      return true
    end
    local ok, why = os.rename(src, retained)
    if not ok then
      if tostring(why):lower():find('cross', 1, true) then return 'cross_device' end
      return nil, tostring(why or 'rename')
    end
    return true
  end
  local function sync_user_parents(src, retained)
    local token = digest.sha256(tostring(os.time()) .. '\0' .. tostring(src))
    for _, path in ipairs({ dirname(src), dirname(retained) }) do
      local fence = path .. '/.relay-archive-fence'
      local ok, why = fs.write_atomic(fence, tostring(token), { private = true })
      if not ok then return nil, tostring(why or 'parent_fence') end
    end
    return true
  end
  return { stat = stat, ensure_dir = ensure_dir, copy_chunk = copy_chunk,
    close_copy = close_copy, digest_file = digest_file,
    publish_verified = publish_verified, rename_once = rename_once,
    sync_user_parents = sync_user_parents, max_file = max_file }
end

local function next_file(plan)
  for _, file in ipairs(plan.files) do
    if file.state ~= 'complete' then return file end
  end
  return nil
end

-- advance(job_id, budget) -> exactly one per-file transition.
-- The source is never unlinked. A verified destination is never overwritten by
-- an unverified original: a collision blocks unless the exact digest matches.
function M.advance(job_id, budget)
  local plan = plans[job_id]
  if not plan then return nil, 'plan_missing' end
  if plan.blocked then return nil, 'blocked:' .. tostring(plan.blocked) end
  local file = next_file(plan)
  if not file then
    plan.phase = 'complete'
    return { job_id = job_id, phase = 'complete', done = true,
      copied = plan.copied, retired = plan.retired }
  end
  local deps = plan.deps
  if type(deps) ~= 'table' then return nil, 'deps_missing' end
  local limit = tonumber(budget and budget.max_bytes) or 65536
  if limit < 1 or limit > 65536 then return nil, 'budget' end
  local dest = destination(plan, file)
  local staging = dest .. '.part'
  local verified = dest .. '.verified'
  local retained = dest .. '.original'
  plan.phase = 'archiving'
  if file.state == 'planned' then
    if type(deps.copy_chunk) ~= 'function' or type(deps.digest_file) ~= 'function'
        or type(deps.stat) ~= 'function' then
      plan.blocked = 'copy_provider_missing'
      return nil, 'blocked:' .. plan.blocked
    end
    if type(deps.ensure_dir) == 'function' then
      local made, make_why = deps.ensure_dir(dirname(dest))
      if not made then plan.blocked = 'mkdir:' .. tostring(make_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
    end
    local digest, digest_why = deps.digest_file(file.relative)
    if not digest then plan.blocked = 'digest:' .. tostring(digest_why or file.role)
      return nil, 'blocked:' .. plan.blocked end
    file.digest = digest
    local existing, existing_why = deps.stat(verified)
    if existing ~= nil then
      local same, same_why = deps.digest_file(verified)
      if not same then plan.blocked = 'collision:' .. tostring(same_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      if same ~= digest then
        plan.blocked = 'collision:' .. file.role
        return nil, 'blocked:' .. plan.blocked
      end
      file.state = 'copied_verified'
    else
      file.state = 'copying'
      if file.bytes == 0 then
        -- Create the empty staging artifact once; the next action publishes it.
        local empty, empty_why = deps.copy_chunk(file.relative, staging, 0, 1)
        if empty == nil then plan.blocked = 'copy:' .. tostring(empty_why or file.role)
          return nil, 'blocked:' .. plan.blocked end
        if empty ~= 0 then plan.blocked = 'source_changed:' .. file.role
          return nil, 'blocked:' .. plan.blocked end
      end
    end
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, bytes = file.bytes, offset = file.offset }
  end
  if file.state == 'copying' then
    if file.offset >= file.bytes then
      -- Empty ack/drain sidecars are valid zero-byte artifacts.
      local copy_done, copy_why = deps.close_copy(staging)
      if copy_done ~= true then plan.blocked = 'copy:' .. tostring(copy_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      local digest, digest_why = deps.digest_file(staging)
      if not digest then plan.blocked = 'digest:' .. tostring(digest_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      if digest ~= file.digest then plan.blocked = 'source_changed:' .. file.role
        return nil, 'blocked:' .. plan.blocked end
      local published, publish_why = deps.publish_verified(staging, verified)
      if published ~= true then plan.blocked = 'publish:' .. tostring(publish_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      file.state = 'copied_verified'
      plan.copied = plan.copied + 1
      return { job_id = job_id, phase = plan.phase, file = file.relative,
        state = file.state, digest = digest, bytes = file.bytes }
    end
    local copied, copy_why = deps.copy_chunk(file.relative, staging,
      file.offset, math.min(limit, file.bytes - file.offset))
    if copied == nil then plan.blocked = 'copy:' .. tostring(copy_why or file.role)
      return nil, 'blocked:' .. plan.blocked end
    file.offset = file.offset + (tonumber(copied) or 0)
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, bytes = file.bytes, offset = file.offset }
  end
  if file.state == 'copied_verified' then
    if type(deps.rename_once) ~= 'function' or type(deps.sync_user_parents) ~= 'function' then
      plan.blocked = 'retire_provider_missing'
      return nil, 'blocked:' .. plan.blocked
    end
    file.state = 'retirement_pending'
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, verified = verified }
  end
  if file.state == 'retirement_pending' then
    local retired, retire_why = deps.rename_once(file.relative, verified, retained)
    if retired == 'cross_device' then
      -- Keep the original; no delete, no copy fallback.
      plan.blocked = 'cross_device:' .. file.role
      return nil, 'blocked:' .. plan.blocked
    end
    if retired ~= true then plan.blocked = 'retire:' .. tostring(retire_why or file.role)
      return nil, 'blocked:' .. plan.blocked end
    local synced, sync_why = deps.sync_user_parents(file.relative, retained)
    if synced ~= true then plan.blocked = 'parent_sync:' .. tostring(sync_why or file.role)
      return nil, 'blocked:' .. plan.blocked end
    file.state = 'complete'
    plan.retired = plan.retired + 1
    if next_file(plan) == nil then plan.phase = 'complete' end
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, done = plan.phase == 'complete',
      copied = plan.copied, retired = plan.retired }
  end
  return nil, 'file_state:' .. tostring(file.state)
end

-- status(job_id) -> manifest refs, never mailbox content.
function M.status(job_id)
  local plan = plans[job_id]
  if not plan then return nil, 'plan_missing' end
  local files = {}
  for _, file in ipairs(plan.files) do
    files[#files + 1] = { relative = file.relative, role = file.role,
      bytes = file.bytes, state = file.state, digest = file.digest }
  end
  return { job_id = job_id, phase = plan.phase, blocked = plan.blocked,
    relay_certificate_id = plan.relay_certificate_id,
    relay_verification_id = plan.relay_verification_id,
    inbox_hash = plan.inbox_hash, copied = plan.copied, retired = plan.retired,
    archive_root = plan.archive_root, files = files }
end

return M
