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

-- plan(input) -> durable per-file plan | nil, reason
-- input = { job_id, cfg, relay_proof, inbox_proof, deps, archive_root }
function M.plan(input)
  if type(input) ~= 'table' then return nil, 'proof_missing' end
  local proven, proof_why = prove(input)
  if not proven then return nil, proof_why end
  if not identifier(input.job_id) then return nil, 'job_id' end
  local files, inv_why = inventory(input)
  if not files then return nil, inv_why end
  local archive_root = input.archive_root or
    ((input.cfg and input.cfg.archive_root) or
      ((input.cfg and input.cfg.config_path or input.base_path) .. '.archive'))
  local plan = { job_id = input.job_id, phase = 'planned',
    archive_root = archive_root, files = files,
    relay_certificate_id = input.relay_proof.certificate_id,
    relay_verification_id = input.relay_proof.verification_id,
    inbox_hash = input.inbox_proof.hash, copied = 0, retired = 0,
    blocked = nil }
  plans[input.job_id] = plan
  return plan
end

local function destination(plan, file)
  local relative = file.relative:gsub('^/+', ''):gsub('%.%./', '')
  return plan.archive_root .. '/' .. relative
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
  local verified = dest .. '.verified'
  local original = dest .. '.original'
  plan.phase = 'archiving'
  if file.state == 'planned' then
    if type(deps.copy_chunk) ~= 'function' or type(deps.digest_file) ~= 'function'
        or type(deps.stat) ~= 'function' then
      plan.blocked = 'copy_provider_missing'
      return nil, 'blocked:' .. plan.blocked
    end
    local existing, existing_why = deps.stat(verified)
    if existing ~= nil then
      local same, same_why = deps.digest_file(verified)
      if not same then plan.blocked = 'collision:' .. tostring(same_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      if same ~= file.digest then
        plan.blocked = 'collision:' .. file.role
        return nil, 'blocked:' .. plan.blocked
      end
      file.state, file.digest = 'copied_verified', same
    else
      file.state = 'copying'
    end
    return { job_id = job_id, phase = plan.phase, file = file.relative,
      state = file.state, bytes = file.bytes, offset = file.offset }
  end
  if file.state == 'copying' then
    if file.offset >= file.bytes then
      -- Empty ack/drain sidecars are valid zero-byte artifacts.
      local copy_done, copy_why = deps.close_copy(original)
      if copy_done ~= true then plan.blocked = 'copy:' .. tostring(copy_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      local digest, digest_why = deps.digest_file(original)
      if not digest then plan.blocked = 'digest:' .. tostring(digest_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      local moved, move_why = deps.publish_verified(original, verified)
      if moved ~= true then plan.blocked = 'publish:' .. tostring(move_why or file.role)
        return nil, 'blocked:' .. plan.blocked end
      file.digest, file.state = digest, 'copied_verified'
      plan.copied = plan.copied + 1
      return { job_id = job_id, phase = plan.phase, file = file.relative,
        state = file.state, digest = digest, bytes = file.bytes }
    end
    local copied, copy_why = deps.copy_chunk(file.relative, original,
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
    local retired, retire_why = deps.rename_once(file.relative, verified, original)
    if retired == 'cross_device' then
      -- Keep the original; no delete, no copy fallback.
      plan.blocked = 'cross_device:' .. file.role
      return nil, 'blocked:' .. plan.blocked
    end
    if retired ~= true then plan.blocked = 'retire:' .. tostring(retire_why or file.role)
      return nil, 'blocked:' .. plan.blocked end
    local synced, sync_why = deps.sync_user_parents(file.relative, original)
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
