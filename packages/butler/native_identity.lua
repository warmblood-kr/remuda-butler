-- Canonical core row id for a live session.
-- New cores expose row.id directly. The old Lua projection drops it, but the
-- daemon's List wire still carries the stable id. This module asks the
-- official `remuda ls --json` (plain SessionSummary array) once, and only
-- trusts its ids after proving that it described the SAME daemon: the JSON set
-- must equal the in-image listing exactly on name + instance_id + alive, and a
-- full Lua re-listing after the CLI yield must still equal the pre snapshot.
-- A wrong daemon, fleet drift, a duplicate or any malformed answer fails
-- closed. Never an alias and never the instance id. Nothing is cached: every
-- launch/adopt proves the id again, so agent/module/decision fences stay
-- authoritative.
local M = {}

local MAX_ID = 128
local DEFAULT_TIMEOUT = 5
local MAX_OUTPUT = 64 * 1024

function M.valid_id(value)
  return type(value) == "string" and #value >= 1 and #value <= MAX_ID
    and value:match("^[%w_%-]+$") ~= nil
end

local function row_key(row)
  return tostring(row.name) .. "\0" .. tostring(row.instance_id)
end

-- Same-daemon proof: identical length and identical (name, instance_id,
-- alive) for every row, in any order. Unique names and non-empty instances,
-- strict booleans and a non-empty set are required. This corroborates the
-- current fleet on the same account; it is not socket attestation (a cloned
-- or replayed identical roster is outside this proof).
local function same_listing(rows, listed)
  if type(rows) ~= "table" or type(listed) ~= "table" then return false end
  if #rows ~= #listed or #rows == 0 then return false end
  local seen, names = {}, {}
  for _, row in ipairs(rows) do
    if type(row.instance_id) ~= "string" or row.instance_id == "" then return false end
    if type(row.alive) ~= "boolean" then return false end
    if type(row.name) ~= "string" or row.name == "" or names[row.name] then return false end
    names[row.name] = true
    local key = row_key(row)
    if seen[key] ~= nil then return false end
    seen[key] = row.alive
  end
  for _, row in ipairs(listed) do
    if type(row.alive) ~= "boolean" then return false end
    local key = row_key(row)
    if seen[key] == nil or seen[key] ~= row.alive then return false end
    seen[key] = nil
  end
  return next(seen) == nil
end

-- Resolve one live row. `options.rows` is the authoritative pre-yield listing
-- (remuda.ls()); `options.list` returns a fresh full listing after the CLI
-- yield. Both must be identical. Returns id, nil or nil, typed reason.
function M.resolve(row, options)
  options = options or {}
  if type(row) ~= "table" or type(row.name) ~= "string" or row.name == "" then
    return nil, "missing_row_identity"
  end
  if M.valid_id(row.id) then return row.id end
  if type(row.instance_id) ~= "string" or row.instance_id == "" then
    return nil, "missing_row_identity"
  end
  local rows = options.rows
  local list = options.list
  if type(rows) ~= "table" or type(list) ~= "function" then
    return nil, "identity_unavailable"
  end
  local runner = options.runner
  local codec = options.json or (remuda and remuda.json)
  if type(runner) ~= "function" or type(codec) ~= "table"
      or type(codec.decode) ~= "function" then
    return nil, "identity_unavailable"
  end
  local ok, result = pcall(runner, { argv = { options.remuda or "remuda", "ls", "--json" },
    timeout = options.timeout or DEFAULT_TIMEOUT })
  if not ok or type(result) ~= "table" or result.timed_out then
    return nil, "identity_unavailable"
  end
  if result.code ~= 0 then return nil, "identity_unavailable" end
  local stdout = result.stdout
  if type(stdout) ~= "string" or #stdout > (options.max_output or MAX_OUTPUT) then
    return nil, "identity_invalid"
  end
  local decoded, listed = pcall(codec.decode, stdout)
  if not decoded or type(listed) ~= "table" then return nil, "identity_invalid" end
  if not same_listing(rows, listed) then return nil, "identity_unverified" end
  -- The full live fleet must still be the same after the client yield, not
  -- just the target: a replaced/died/new sibling invalidates the proof.
  local rechecked, after = pcall(list)
  if not rechecked or type(after) ~= "table" or not same_listing(rows, after) then
    return nil, "identity_unverified"
  end
  local found
  for _, candidate in ipairs(listed) do
    if candidate.name == row.name and candidate.instance_id == row.instance_id then
      if found then return nil, "identity_ambiguous" end
      found = candidate
    end
  end
  if not found or found.alive ~= true then return nil, "identity_unverified" end
  if not M.valid_id(found.id) then return nil, "missing_row_id" end
  return found.id
end

M.same_listing = same_listing
remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_identity = M
return M
