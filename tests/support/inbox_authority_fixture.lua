-- Writer-owned real-SQL bootstrap fixture for Phase A QA.
--
-- This creates the SQL prerequisites C will use (authority epoch row, a
-- committed transition receipt and an SQL_ACTIVE marker) on a temp EMPTY root.
-- It never fabricates mail rows and is NOT evidence of a valid B/C promotion.
-- Tests must inspect actual persisted rows through native SQL/reopen.
local M = {}

local function fail(code, field)
  return nil, { code = code, field = field }
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

local function empty_dir(path)
  local names, err = remuda.list_dir(path)
  if names == nil then
    local text = tostring(err or "")
    if text:find("No such file", 1, true) or text:find("ENOENT", 1, true) then return true end
    return nil
  end
  if type(names) ~= "table" then return nil end
  return #names == 0
end

local function transaction(db, statements)
  local ok, err = db:exec("BEGIN IMMEDIATE")
  if not ok then return nil, err end
  for _, statement in ipairs(statements) do
    local done, why = db:exec(statement.sql, statement.params)
    if not done then
      pcall(db.exec, db, "ROLLBACK")
      return nil, why
    end
  end
  local committed, commit_err = db:exec("COMMIT")
  if not committed then
    pcall(db.exec, db, "ROLLBACK")
    return nil, commit_err
  end
  return true
end

local function publish_marker(marker, root, next)
  if type(marker) ~= "table" then return fail("unavailable", "marker") end
  if type(marker.publish) == "function" then
    local ok, result, err = pcall(marker.publish, next)
    if not ok or result == nil then return fail("unavailable", "marker") end
    return true
  end
  if type(marker.write) == "function" then
    local ok, result, err = pcall(marker.write, next)
    if not ok or result == nil then return fail("unavailable", "marker") end
    return true
  end
  if type(marker.prepare) == "function" and type(marker.finalize) == "function" then
    local ok, current = pcall(marker.read, root)
    if not ok then return fail("recovery_required", "marker") end
    local prepared, prep_err = marker.prepare(current, next)
    if not prepared then return fail("unavailable", "marker") end
    local finalized = marker.finalize(prepared, next)
    if not finalized then return fail("unavailable", "marker") end
    return true
  end
  return fail("unavailable", "marker")
end

function M.create(options)
  if type(options) ~= "table" then return fail("invalid_snapshot", "config") end
  local db, root, json = options.db, options.root, options.json
  local epoch, generation = options.epoch, options.generation
  local operation_id, proof_hash = options.operation_id, options.proof_hash
  local watermark = options.tail_watermark == nil and 0 or options.tail_watermark
  if db == nil then return fail("unavailable", "db") end
  local has_exec = pcall(function() return db.exec end)
  local has_query = pcall(function() return db.query end)
  if not has_exec or not has_query then return fail("unavailable", "db") end
  if not nonempty(root) then return fail("invalid_snapshot", "root") end
  if type(json) ~= "table" or type(json.decode) ~= "function"
    or type(json.encode) ~= "function" or type(json.canonical) ~= "function" then
    return fail("unavailable", "json")
  end
  if type(epoch) ~= "number" or epoch % 1 ~= 0 or epoch < 1 then
    return fail("invalid_snapshot", "epoch")
  end
  if not nonempty(generation) or not nonempty(operation_id)
    or type(proof_hash) ~= "string" or #proof_hash ~= 64 then
    return fail("invalid_snapshot", "identity")
  end
  if type(watermark) ~= "number" or watermark % 1 ~= 0 or watermark < 0 then
    return fail("invalid_snapshot", "tail_watermark")
  end
  for _, name in ipairs({ "inboxes", "read", "messages", "objects", "authority.json" }) do
    if name == "authority.json" then
      local handle = io.open(root .. "/authority.json", "rb")
      if handle then handle:close(); return fail("invalid_snapshot", "not_empty") end
    else
      local empty = empty_dir(root .. "/" .. name)
      if empty == nil then return fail("unavailable", name) end
      if not empty then return fail("invalid_snapshot", "not_empty") end
    end
  end
  local tables = db:query("SELECT name FROM sqlite_master WHERE type='table' AND name='auth_authority'", {})
  if not tables or #tables == 0 then return fail("schema_unavailable", "auth") end
  local existing = db:query("SELECT id FROM auth_authority WHERE id = 1", {})
  if not existing then return fail("unavailable", "auth") end
  if #existing > 0 then return fail("invalid_snapshot", "authority_exists") end
  local result = assert(json.canonical({
    state = "committed", operation_id = operation_id,
    result = { authority = "sql", epoch = epoch, generation = generation },
  }))
  local ok, err = transaction(db, {
    { sql = "INSERT INTO auth_authority (id, format_version, root, epoch, generation, "
        .. "operation_id, proof_hash, tail_watermark) VALUES (1, 1, ?, ?, ?, ?, ?, ?)",
      params = { root, epoch, generation, operation_id, proof_hash, watermark } },
    { sql = "INSERT INTO auth_operations (operation_id, kind, payload_hash, state, "
        .. "message_id, result_json, epoch) VALUES (?, 'transition', ?, 'committed', "
        .. "NULL, ?, ?)",
      params = { operation_id, proof_hash, result, epoch } },
  })
  if not ok then return fail("unavailable", "sql") end
  local marker = options.marker
  local next_marker = {
    format_version = 1, state = "SQL_ACTIVE", root = root, epoch = epoch,
    protocol = "sql-inbox-v1", generation = generation,
    operation_id = operation_id, proof_hash = proof_hash,
    tail_watermark = watermark,
  }
  local published, publish_err = publish_marker(marker, root, next_marker)
  if not published then return nil, publish_err end
  return { root = root, db = db, epoch = epoch, generation = generation,
    operation_id = operation_id, bootstrap = "fixture",
    promotion_proof = false }
end

return M
