-- Retained relay archive coordinator.
--
-- Planning is bound to BOTH current proofs: the relay certificate reread under
-- the current owner and the real inbox producer proof. Nothing is archived
-- from a cached status, a boolean or a count. Bytes move in bounded 64KiB
-- chunks; each chunk is durably published with fs.write_atomic, then a small
-- manifest binds their exact digests. The source is retired by atomic rename
-- after every chunk is re-read and verified; no whole-file SHA/publish happens
-- inside one call.
--
-- The shell filesystem has write_atomic/mkdir_new/realpath/is_symlink/lock but
-- no generic read/fsync/durable_rename. This module uses only those proven
-- primitives and never invents fsync or deletes an original.
local M = {}

local plans = {}
local MAX_CHUNK = 64 * 1024
local MAX_PARTS = 1024

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
  if type(deps.current_owner) ~= 'function' then
    return nil, 'owner_provider_missing'
  end
  local owner_now, owner_why = deps.current_owner()
  if owner_now ~= true then
    return nil, 'owner_' .. tostring(owner_why or 'stale')
  end
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
        bytes = stat.size, state = 'planned', offset = 0, parts = {},
        verify_index = 1 }
    end
  end
  return plan_files
end

local function dirname(path)
  return path:match('^(.*)/[^/]*$') or '.'
end

local function destination(plan, file)
  local relative = file.relative:match('[^/]+$') or file.relative
  return plan.archive_root .. '/' .. plan.job_id .. '/' .. relative
end

local function part_path(dest, index)
  return string.format('%s.part.%04d', dest, index)
end

-- Actual providers using the proven shell capabilities only. Each call reads
-- and writes at most one 64KiB chunk; the manifest is small. Verification
-- re-reads one chunk per call. There is no generic fsync/durable_rename and
-- none is invented.
function M.providers(fs, digest)
  if type(fs) ~= 'table' or type(fs.write_atomic) ~= 'function'
      or type(fs.mkdir_new) ~= 'function' then
    return nil, 'fs'
  end
  if type(digest) ~= 'table' or type(digest.sha256) ~= 'function' then
    return nil, 'digest'
  end
  local function hash(bytes)
    local ok, value = pcall(digest.sha256, bytes)
    if not ok or type(value) ~= 'string' or #value ~= 64 then return nil, 'digest' end
    return value
  end
  local function read_chunk(path, offset, limit)
    local file, why = io.open(path, 'rb')
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
    end
    file:close()
    if chunk == nil then return nil, 'read' end
    if #chunk > limit then return nil, 'oversize' end
    return chunk
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
  local function copy_chunk(src, part, offset, limit)
    if limit < 1 or limit > MAX_CHUNK then return nil, 'budget' end
    local chunk, why = read_chunk(src, offset, limit)
    if not chunk then return nil, why end
    if #chunk == 0 then return { bytes = 0, digest = hash('') } end
    local digest_value, hash_why = hash(chunk)
    if not digest_value then return nil, hash_why end
    local ok, write_why = fs.write_atomic(part, chunk, { private = true })
    if not ok then return nil, tostring(write_why or 'part_write') end
    return { bytes = #chunk, digest = digest_value }
  end
  local function verify_part(part, expected, limit)
    if limit < 1 or limit > MAX_CHUNK then return nil, 'budget' end
    local chunk, why = read_chunk(part, 0, limit)
    if not chunk then return nil, why end
    local value, hash_why = hash(chunk)
    if not value then return nil, hash_why end
    if value ~= expected then return nil, 'digest' end
    return true
  end
  local function manifest_root(parts, bytes)
    local fields = { 'relay-archive-manifest-v1', tostring(bytes) }
    for _, part in ipairs(parts) do
      fields[#fields + 1] = part.index .. ':' .. part.bytes .. ':' .. part.digest
    end
    return hash(table.concat(fields, '\0'))
  end
  local function write_manifest(path, manifest)
    local json = remuda and remuda.json
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then
      return nil, 'json'
    end
    local encoded = { version = manifest.version, bytes = manifest.bytes,
      root = manifest.root }
    encoded.parts = json.array and json.array(manifest.parts or {})
      or (manifest.parts or {})
    local ok, text = pcall(json.encode, encoded)
    if not ok then return nil, 'manifest_encode:' .. tostring(text) end
    local wrote, why = fs.write_atomic(path, text, { private = true })
    if not wrote then return nil, tostring(why or 'manifest_write') end
    return true
  end
  local function read_manifest(path)
    local file = io.open(path, 'rb')
    if not file then return nil, 'missing' end
    local raw = file:read(262144)
    file:close()
    if type(raw) ~= 'string' or #raw > 262144 then return nil, 'manifest_read' end
    local json = remuda and remuda.json
    if type(json) ~= 'table' or type(json.decode) ~= 'function' then
      return nil, 'json'
    end
    local ok, value = pcall(json.decode, raw)
    if not ok or type(value) ~= 'table' then return nil, 'manifest_decode' end
    return value
  end
  local function rename_once(src, manifest_path, retained, retained_manifest,
      root, bytes)
    local manifest, manifest_why = read_manifest(manifest_path)
    if not manifest then return nil, manifest_why end
    if manifest.root ~= root or tonumber(manifest.bytes) ~= tonumber(bytes) then
      return nil, 'manifest_mismatch'
    end
    local existing = stat(retained)
    if existing then
      local prior, prior_why = read_manifest(retained_manifest)
      if not prior then return nil, 'collision:' .. tostring(prior_why) end
      if prior.root == root and tonumber(prior.bytes) == tonumber(bytes) then
        -- The live source and an identical retained copy both exist. This is a
        -- retire conflict, not completion: never claim the source was retired
        -- while it is still present.
        return nil, 'retire_conflict'
      end
      return nil, 'collision'
    end
    local ok, why = os.rename(src, retained)
    if not ok then
      if tostring(why):lower():find('cross', 1, true) then return 'cross_device' end
      return nil, tostring(why or 'rename')
    end
    local wrote, write_why = write_manifest(retained_manifest,
      { version = 1, root = root, bytes = bytes })
    if not wrote then return nil, tostring(write_why or 'retained_manifest') end
    return true
  end
  local function sync_user_parents(src, retained)
    local token, token_why = hash(tostring(os.time()) .. '\0' .. tostring(src))
    if not token then return nil, token_why end
    for _, path in ipairs({ dirname(src), dirname(retained) }) do
      local fence = path .. '/.relay-archive-fence'
      local ok, why = fs.write_atomic(fence, token, { private = true })
      if not ok then return nil, tostring(why or 'parent_fence') end
    end
    return true
  end
  local function write_plan(path, plan)
    local json = remuda and remuda.json
    if type(json) ~= 'table' or type(json.encode) ~= 'function' then
      return nil, 'json'
    end
    local files = {}
    for _, file in ipairs(plan.files or {}) do
      local parts = {}
      for _, part in ipairs(file.parts or {}) do
        parts[#parts + 1] = part
      end
      files[#files + 1] = { relative = file.relative, role = file.role,
        bytes = file.bytes, state = file.state, offset = file.offset,
        verify_index = file.verify_index, root = file.root,
        rename_attempted = file.rename_attempted == true,
        parts = json.array and json.array(parts) or parts }
    end
    local encoded = { version = 1, job_id = plan.job_id, phase = plan.phase,
      archive_root = plan.archive_root, copied = plan.copied,
      retired = plan.retired, blocked = plan.blocked,
      relay_certificate_id = plan.relay_certificate_id,
      relay_verification_id = plan.relay_verification_id,
      inbox_hash = plan.inbox_hash,
      files = json.array and json.array(files) or files }
    local ok, text = pcall(json.encode, encoded)
    if not ok then return nil, 'plan_encode' end
    local wrote, why = fs.write_atomic(path, text, { private = true })
    if not wrote then return nil, tostring(why or 'plan_write') end
    return true
  end
  local function read_plan(path)
    local file = io.open(path, 'rb')
    if not file then return nil, 'missing' end
    local raw = file:read(262144)
    file:close()
    if type(raw) ~= 'string' or #raw > 262144 then return nil, 'plan_read' end
    local json = remuda and remuda.json
    if type(json) ~= 'table' or type(json.decode) ~= 'function' then
      return nil, 'json'
    end
    local ok, value = pcall(json.decode, raw)
    if not ok or type(value) ~= 'table' or value.version ~= 1 then
      return nil, 'plan_decode'
    end
    return value
  end
  return { stat = stat, ensure_dir = ensure_dir, copy_chunk = copy_chunk,
    verify_part = verify_part, manifest_root = manifest_root,
    write_manifest = write_manifest, read_manifest = read_manifest,
    rename_once = rename_once, sync_user_parents = sync_user_parents,
    write_plan = write_plan, read_plan = read_plan,
    max_chunk = MAX_CHUNK, max_parts = MAX_PARTS }
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
    deps = M.providers(input.fs or (remuda and remuda.fs),
      input.digest or (remuda and remuda.digest))
    if deps == nil then return nil, 'deps_missing' end
  end
  local archive_root = input.archive_root or
    ((input.cfg and input.cfg.archive_root) or
      (dirname(input.cfg and input.cfg.config_path or input.base_path) .. '/archive'))
  local plan_path = input.plan_path or (archive_root .. '/' .. input.job_id .. '/plan.json')
  if input.resume ~= false and type(deps.read_plan) == 'function' then
    local saved, saved_why = deps.read_plan(plan_path)
    if saved then
      if saved.job_id ~= input.job_id
          or saved.relay_certificate_id ~= input.relay_proof.certificate_id
          or saved.relay_verification_id ~= input.relay_proof.verification_id
          or saved.inbox_hash ~= (input.inbox_proof.compatibility_hash
            or input.inbox_proof.hash) then
        return nil, 'plan_conflict'
      end
      local plan = { job_id = saved.job_id, phase = saved.phase,
        archive_root = saved.archive_root, files = saved.files or {}, deps = deps,
        relay_proof = input.relay_proof, inbox_proof = input.inbox_proof,
        plan_path = plan_path, relay_certificate_id = saved.relay_certificate_id,
        relay_verification_id = saved.relay_verification_id,
        inbox_hash = saved.inbox_hash, copied = tonumber(saved.copied) or 0,
        retired = tonumber(saved.retired) or 0, blocked = saved.blocked }
      for _, file in ipairs(plan.files) do
        file.parts = file.parts or {}
        file.offset = tonumber(file.offset) or 0
        file.verify_index = tonumber(file.verify_index) or 1
      end
      plans[input.job_id] = plan
      return plan
    elseif saved_why ~= 'missing' then
      return nil, 'plan_' .. tostring(saved_why)
    end
  end
  local files, inv_why = inventory({ deps = deps, cfg = input.cfg,
    config_path = input.config_path, base_path = input.base_path })
  if not files then return nil, inv_why end
  local plan = { job_id = input.job_id, phase = 'planned',
    archive_root = archive_root, files = files, deps = deps,
    relay_proof = input.relay_proof, inbox_proof = input.inbox_proof,
    plan_path = plan_path,
    relay_certificate_id = input.relay_proof.certificate_id,
    relay_verification_id = input.relay_proof.verification_id,
    inbox_hash = input.inbox_proof.compatibility_hash or input.inbox_proof.hash,
    copied = 0, retired = 0, blocked = nil }
  plans[input.job_id] = plan
  if type(deps.write_plan) == 'function' then
    if type(deps.ensure_dir) == 'function' then
      local made, make_why = deps.ensure_dir(archive_root .. '/' .. input.job_id)
      if not made then return nil, 'mkdir:' .. tostring(make_why) end
    end
    local persisted, persist_why = deps.write_plan(plan_path, plan)
    if persisted ~= true then return nil, 'plan_' .. tostring(persist_why) end
  end
  return plan
end

local function next_file(plan)
  for _, file in ipairs(plan.files) do
    if file.state ~= 'complete' then return file end
  end
  return nil
end

-- advance(job_id, budget) -> exactly one bounded per-file transition.
-- Copy/verify reads and writes at most `budget.max_bytes` (<=64KiB) per call.
local function advance_impl(job_id, budget)
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
  local limit = tonumber(budget and budget.max_bytes) or MAX_CHUNK
  if limit < 1 or limit > MAX_CHUNK then return nil, 'budget' end
  local dest = destination(plan, file)
  local manifest_path = dest .. '.manifest'
  local retained = dest .. '.original'
  local retained_manifest = retained .. '.manifest'
  plan.phase = 'archiving'
  if file.state == 'planned' then
    if type(deps.copy_chunk) ~= 'function' or type(deps.verify_part) ~= 'function'
        or type(deps.write_manifest) ~= 'function' or type(deps.stat) ~= 'function' then
      plan.blocked = 'copy_provider_missing'
      return nil, 'blocked:' .. plan.blocked
    end
    if type(deps.ensure_dir) == 'function' then
      local made, make_why = deps.ensure_dir(dirname(dest))
      if not made then plan.blocked = 'mkdir:' .. tostring(make_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
    end
    local existing = deps.stat(manifest_path)
    if existing ~= nil then
      local manifest, manifest_why = deps.read_manifest(manifest_path)
      if not manifest or tonumber(manifest.bytes) ~= file.bytes
          or type(manifest.root) ~= 'string' or type(manifest.parts) ~= 'table'
          or #manifest.parts > MAX_PARTS then
        plan.blocked = 'collision:' .. tostring(manifest_why or file.role)
        return nil, 'blocked:' .. plan.blocked
      end
      file.parts, file.root = manifest.parts, manifest.root
      file.offset, file.verify_index = file.bytes, 1
      file.state = 'verifying'
    else
      file.parts, file.offset, file.verify_index = {}, 0, 1
      file.state = 'copying'
    end
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, bytes = file.bytes, offset = file.offset }
  end
  if file.state == 'copying' then
    if file.offset < file.bytes then
      if #file.parts >= MAX_PARTS then
        plan.blocked = 'parts:' .. file.role
        return nil, 'blocked:' .. plan.blocked
      end
      local index = #file.parts + 1
      local copy, copy_why = deps.copy_chunk(file.relative,
        part_path(dest, index), file.offset, math.min(limit, file.bytes - file.offset))
      if copy == nil then plan.blocked = 'copy:' .. tostring(copy_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      local bytes = tonumber(copy.bytes) or 0
      if bytes < 0 or bytes > limit then plan.blocked = 'copy_budget:' .. file.role
        return nil, 'blocked:' .. plan.blocked end
      file.parts[#file.parts + 1] = { index = index, bytes = bytes,
        digest = copy.digest }
      file.offset = file.offset + bytes
      return { job_id = job_id, phase = plan.phase, file = file.relative,
        state = file.state, bytes = file.bytes, offset = file.offset,
        part = index, part_bytes = bytes }
    end
    local root, root_why = deps.manifest_root(file.parts, file.bytes)
    if not root then plan.blocked = 'manifest:' .. tostring(root_why or file.role)
      return nil, 'blocked:' .. plan.blocked end
    local wrote, write_why = deps.write_manifest(manifest_path,
      { version = 1, bytes = file.bytes, root = root, parts = file.parts })
    if wrote ~= true then plan.blocked = 'manifest:' .. tostring(write_why or file.role)
      return nil, 'blocked:' .. plan.blocked end
    file.root, file.verify_index = root, 1
    file.state = 'verifying'
    if #file.parts == 0 then
      file.state = 'copied_verified'
      plan.copied = plan.copied + 1
    end
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, bytes = file.bytes, root = root }
  end
  if file.state == 'verifying' then
    if file.verify_index > #file.parts then
      file.state = 'copied_verified'
      plan.copied = plan.copied + 1
      return { job_id = job_id, phase = plan.phase, file = file.relative,
        state = file.state, bytes = file.bytes, root = file.root }
    end
    local part = file.parts[file.verify_index]
    local ok, verify_why = deps.verify_part(part_path(dest, part.index),
      part.digest, limit)
    if ok ~= true then plan.blocked = 'verify:' .. tostring(verify_why or file.role)
      return nil, 'blocked:' .. plan.blocked end
    file.verify_index = file.verify_index + 1
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, part = part.index, verified = file.verify_index - 1 }
  end
  if file.state == 'copied_verified' then
    if type(deps.rename_once) ~= 'function' or type(deps.sync_user_parents) ~= 'function' then
      plan.blocked = 'retire_provider_missing'
      return nil, 'blocked:' .. plan.blocked
    end
    file.state = 'retirement_pending'
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, manifest = manifest_path }
  end
  if file.state == 'retirement_pending' then
    local source = deps.stat(file.relative)
    if source == nil then
      -- A previous rename may have succeeded and then failed at the retained
      -- manifest or a parent fence. Inspect the actual destination instead of
      -- retrying blind or planning from scratch.
      local prior = deps.read_manifest(retained_manifest)
      if not prior or prior.root ~= file.root
          or tonumber(prior.bytes) ~= file.bytes then
        return nil, 'retire_unknown'
      end
      local synced, sync_why = deps.sync_user_parents(file.relative, retained)
      if synced ~= true then return nil, 'fence_retry:' .. tostring(sync_why or file.role) end
      file.state = 'complete'
      plan.retired = plan.retired + 1
      if next_file(plan) == nil then plan.phase = 'complete' end
      return { job_id = job_id, phase = plan.phase, file = file.relative,
        state = file.state, done = plan.phase == 'complete',
        copied = plan.copied, retired = plan.retired }
    end
    file.rename_attempted = true
    local retired, retire_why = deps.rename_once(file.relative, manifest_path,
      retained, retained_manifest, file.root, file.bytes)
    if retired == 'cross_device' then
      -- Keep the original; no delete, no copy fallback.
      plan.blocked = 'cross_device:' .. file.role
      return nil, 'blocked:' .. plan.blocked
    end
    if retired ~= true then
      if retire_why == 'retire_conflict' then
        plan.blocked = 'retire_conflict:' .. file.role
        return nil, 'blocked:' .. plan.blocked
      end
      return nil, 'retire_unknown:' .. tostring(retire_why or file.role)
    end
    local synced, sync_why = deps.sync_user_parents(file.relative, retained)
    if synced ~= true then return nil, 'fence_retry:' .. tostring(sync_why or file.role) end
    file.state = 'complete'
    plan.retired = plan.retired + 1
    if next_file(plan) == nil then plan.phase = 'complete' end
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, done = plan.phase == 'complete',
      copied = plan.copied, retired = plan.retired }
  end
  return nil, 'file_state:' .. tostring(file.state)
end

-- Public advance: re-check BOTH proofs and the current owner before every
-- side effect, then persist the per-file plan so a reload resumes the same
-- chunk/verify/retire cursors instead of resetting.
function M.advance(job_id, budget)
  local plan = plans[job_id]
  if not plan then return nil, 'plan_missing' end
  if plan.relay_proof and plan.inbox_proof then
    local proven, proof_why = prove(plan)
    if not proven then return nil, proof_why end
  end
  local result, why, detail = advance_impl(job_id, budget)
  local active = plans[job_id]
  if active and type(active.deps.write_plan) == 'function' then
    local wrote, write_why = active.deps.write_plan(active.plan_path, active)
    if wrote ~= true then return nil, 'plan_' .. tostring(write_why) end
  end
  return result, why, detail
end

-- status(job_id) -> manifest refs, never mailbox content.
function M.status(job_id, options)
  local plan = plans[job_id]
  if not plan and type(options) == 'table' and options.plan_path then
    local deps = options.deps
    if type(deps) == 'table' and type(deps.read_plan) == 'function' then
      local saved, _ = deps.read_plan(options.plan_path)
      if type(saved) == 'table' then
        saved.deps = deps
        saved.plan_path = options.plan_path
        for _, file in ipairs(saved.files or {}) do
          file.parts = file.parts or {}
          file.offset = tonumber(file.offset) or 0
          file.verify_index = tonumber(file.verify_index) or 1
        end
        plan = saved
      end
    end
  end
  if not plan then return nil, 'plan_missing' end
  local files = {}
  for _, file in ipairs(plan.files) do
    files[#files + 1] = { relative = file.relative, role = file.role,
      bytes = file.bytes, state = file.state, root = file.root,
      parts = #(file.parts or {}) }
  end
  return { job_id = job_id, phase = plan.phase, blocked = plan.blocked,
    relay_certificate_id = plan.relay_certificate_id,
    relay_verification_id = plan.relay_verification_id,
    inbox_hash = plan.inbox_hash, copied = plan.copied, retired = plan.retired,
    archive_root = plan.archive_root, files = files }
end

return M
