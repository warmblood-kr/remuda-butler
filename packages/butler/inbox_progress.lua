-- Actual SQLite staging backend for the inbox source (stage 2 factory).
--
-- This module is the injectable transaction backend for the #585-extended
-- staging rows. It opens no database, imports nothing and promotes nothing: the
-- caller owns the existing inbox handle and serializes importer/progress use on
-- the daemon Lua loop. Rows are bounded records; a mailbox is never stored as
-- one JSON blob.
local M = { contract_version = 1 }

local function fail(code, field, reason)
  return nil, { code = code, field = field, reason = reason }
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

local function is_integer(value)
  return type(value) == "number" and value % 1 == 0
end

local function is_hex(value)
  return type(value) == "string" and #value > 0 and #value % 2 == 0
    and value:match("^[0-9a-f]+$") ~= nil
end

local function is_canonical_root(value)
  if type(value) ~= "string" or value == "" or value:sub(1, 1) ~= "/" then return false end
  if value == "/" or value:sub(-1) == "/" then return false end
  if value:find("//", 1, true) then return false end
  if value:find("/./", 1, true) or value:sub(-2) == "/." then return false end
  if value:find("/../", 1, true) or value:sub(-3) == "/.." then return false end
  return true
end

local function safe_id(value)
  return nonempty(value) and not value:find("[/\\]") and not value:find("..", 1, true)
end

local function dense_length(values)
  local count, maximum = 0, 0
  for key in pairs(values) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return nil end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if count ~= maximum then return nil end
  return count
end

local PHASES = { logs1 = true, files1 = true, logs2 = true, files2 = true, ready = true, invalid = true }
local KINDS = { deliveries = true, reads = true, dependencies = true,
  fileproofs = true, chunkproofs = true }
-- `get` uses singular keys; `scan` uses the collection names.
local GET_KINDS = { delivery = true, read = true, dependency = true,
  fileproof = true, chunkproof = true }

local CURSOR_KEYS = { generation = true, phase = true, log = true, offset = true,
  parse_offset = true, line_tail = true, after_key = true, chain = true,
  first_chain = true, next_seq = true, complete = true, witness = true }
local CURSOR_LOGS = { inbox = true, read = true }

local function valid_cursor(cursor, max_line_bytes)
  if type(cursor) ~= "table" then return false end
  for key in pairs(cursor) do
    if not CURSOR_KEYS[key] then return false end
  end
  if not nonempty(cursor.generation) then return false end
  if cursor.phase ~= nil and not PHASES[cursor.phase] then return false end
  if cursor.log ~= nil and not CURSOR_LOGS[cursor.log] then return false end
  for _, key in ipairs({ "offset", "parse_offset", "next_seq" }) do
    if cursor[key] ~= nil and (not is_integer(cursor[key]) or cursor[key] < 0) then
      return false
    end
  end
  if cursor.after_key ~= nil and type(cursor.after_key) ~= "string" then return false end
  if cursor.witness ~= nil and type(cursor.witness) ~= "string" then return false end
  if cursor.complete ~= nil and type(cursor.complete) ~= "boolean" then return false end
  if cursor.line_tail ~= nil then
    if type(cursor.line_tail) ~= "string" or #cursor.line_tail > max_line_bytes then
      return false
    end
  end
  for _, key in ipairs({ "chain", "first_chain" }) do
    if cursor[key] ~= nil and not is_hex(cursor[key]) then return false end
    if cursor[key] ~= nil and #cursor[key] ~= 64 then return false end
  end
  return true
end

local function valid_delta(delta)
  local length = dense_length(delta)
  if not length then return false, "delta" end
  for index = 1, length do
    local op = delta[index]
    if type(op) ~= "table" or not nonempty(op.op) then return false, "delta" end
    if op.op == "delivery" then
      if not safe_id(op.message_id) or not is_integer(op.seq) or op.seq < 1 then
        return false, "delivery"
      end
      if op.resent ~= nil and type(op.resent) ~= "string" then return false, "resent" end
    elseif op.op == "read" then
      if not safe_id(op.message_id) then return false, "read" end
    elseif op.op == "metadata" then
      if not safe_id(op.message_id) or type(op.envelope_ref) ~= "string"
        or type(op.object_ref) ~= "string" or type(op.metadata) ~= "string" then
        return false, "metadata"
      end
    elseif op.op == "dependency" then
      if not safe_id(op.owner) or (op.role ~= "envelope" and op.role ~= "body"
        and op.role ~= "note") or type(op.path) ~= "string" then
        return false, "dependency"
      end
    elseif op.op == "fileproof" then
      if (op.pass ~= 1 and op.pass ~= 2) or type(op.path) ~= "string"
        or type(op.present) ~= "boolean" or not is_integer(op.bytes) or op.bytes < 0
        or type(op.sha256) ~= "string" or #op.sha256 ~= 64 then
        return false, "fileproof"
      end
    elseif op.op == "chunkproof" then
      if (op.pass ~= 1 and op.pass ~= 2) or type(op.path) ~= "string"
        or not is_integer(op.offset) or op.offset < 0 or not is_integer(op.bytes)
        or op.bytes < 0 or type(op.sha256) ~= "string" or #op.sha256 ~= 64
        or type(op.eof) ~= "boolean" then
        return false, "chunkproof"
      end
    elseif op.op == "ready" then
      if type(op.witness) ~= "string" or type(op.first_chain) ~= "string"
        or type(op.second_chain) ~= "string" then
        return false, "ready"
      end
    elseif op.op == "invalid" then
      if not nonempty(op.reason) then return false, "invalid" end
    else
      return false, "delta"
    end
  end
  return true
end

local function checked_exec(db, sql, params)
  local ok, result, err = pcall(db.exec, db, sql, params)
  if not ok then return nil, tostring(result) end
  if not result then return nil, tostring(err or "statement failed") end
  return result
end

local function checked_query(db, sql, params)
  local ok, rows, err = pcall(db.query, db, sql, params)
  if not ok then return nil, tostring(rows) end
  if rows == nil then return nil, tostring(err or "query failed") end
  return rows
end

local function id_numbers(reason)
  if type(reason) == "table" then
    return reason.generation, reason.expected_revision, reason.next_revision
  end
  return nil, nil, nil
end

local function unknown(generation, expected, next_revision)
  return nil, { code = "unknown_commit", generation = generation,
    expected_revision = expected, next_revision = next_revision }
end

local Progress = {}
Progress.__index = Progress

local function schema_ready(self)
  local rows, err = checked_query(self.db,
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'progress_state'", {})
  if not rows then return nil, "schema_unavailable" end
  if #rows == 0 then return nil, "schema_unavailable" end
  local versions = checked_query(self.db,
    "SELECT MAX(version) AS version FROM _remuda_migrations", {})
  if not versions then return nil, "schema_unavailable" end
  local version = versions[1] and tonumber(versions[1].version) or 0
  if version > 3 then return nil, "schema_too_new" end
  return true
end

local function add_delta(self, root, recipient, generation, op)
  if op.op == "delivery" then
    local statement, params
    if op.resent ~= nil then
      statement = "INSERT OR IGNORE INTO progress_deliveries "
        .. "(recipient, generation, message_id, seq, resent_json) VALUES (?, ?, ?, ?, ?)"
      params = { recipient, generation, op.message_id, op.seq, op.resent }
    else
      statement = "INSERT OR IGNORE INTO progress_deliveries "
        .. "(recipient, generation, message_id, seq) VALUES (?, ?, ?, ?)"
      params = { recipient, generation, op.message_id, op.seq }
    end
    local inserted, why = checked_exec(self.db, statement, params)
    if not inserted then return nil, "sql: " .. tostring(why) end
    local owner = checked_query(self.db,
      "SELECT message_id FROM progress_deliveries "
        .. "WHERE recipient = ? AND generation = ? AND seq = ?",
      { recipient, generation, op.seq })
    if not owner or #owner == 0 or owner[1].message_id ~= op.message_id then
      return nil, "staging_conflict"
    end
    if op.resent ~= nil then
      local updated, update_why = checked_exec(self.db,
        "UPDATE progress_deliveries SET resent_json = ? "
          .. "WHERE recipient = ? AND generation = ? AND message_id = ?",
        { op.resent, recipient, generation, op.message_id })
      if not updated then return nil, "sql: " .. tostring(update_why) end
    end
    return true
  end
  if op.op == "read" then
    local inserted, why = checked_exec(self.db,
      "INSERT OR IGNORE INTO progress_reads (recipient, generation, message_id) "
        .. "VALUES (?, ?, ?)", { recipient, generation, op.message_id })
    if not inserted then return nil, "sql: " .. tostring(why) end
    return true
  end
  if op.op == "metadata" then
    local delivery = checked_query(self.db,
      "SELECT 1 AS present FROM progress_deliveries "
        .. "WHERE recipient = ? AND generation = ? AND message_id = ?",
      { recipient, generation, op.message_id })
    if not delivery then return nil, "unavailable" end
    if #delivery == 0 then return nil, "not_committed" end
    local inserted, why = checked_exec(self.db,
      "INSERT OR REPLACE INTO progress_metadata "
        .. "(recipient, generation, message_id, envelope_ref, object_ref, metadata) "
        .. "VALUES (?, ?, ?, ?, ?, ?)",
      { recipient, generation, op.message_id, op.envelope_ref, op.object_ref, op.metadata })
    if not inserted then return nil, "sql: " .. tostring(why) end
    return true
  end
  if op.op == "dependency" then
    local inserted, why = checked_exec(self.db,
      "INSERT OR REPLACE INTO progress_dependencies "
        .. "(recipient, generation, owner, role, path) VALUES (?, ?, ?, ?, ?)",
      { recipient, generation, op.owner, op.role, op.path })
    if not inserted then return nil, "sql: " .. tostring(why) end
    return true
  end
  if op.op == "fileproof" then
    local rows = checked_query(self.db,
      "SELECT present, bytes, sha256 FROM progress_fileproofs "
        .. "WHERE recipient = ? AND generation = ? AND pass = ? AND path = ?",
      { recipient, generation, op.pass, op.path })
    if not rows then return nil, "unavailable" end
    if #rows > 0 then
      local row = rows[1]
      local same = (row.present == (op.present and 1 or 0))
        and (tonumber(row.bytes) == op.bytes) and row.sha256 == op.sha256
      if not same then return nil, "stale_generation" end
      return true
    end
    local inserted, why = checked_exec(self.db,
      "INSERT INTO progress_fileproofs "
        .. "(recipient, generation, pass, path, present, bytes, sha256) "
        .. "VALUES (?, ?, ?, ?, ?, ?, ?)",
      { recipient, generation, op.pass, op.path, op.present and 1 or 0, op.bytes, op.sha256 })
    if not inserted then return nil, "sql: " .. tostring(why) end
    return true
  end
  if op.op == "chunkproof" then
    local rows = checked_query(self.db,
      "SELECT bytes, sha256, eof FROM progress_chunkproofs "
        .. "WHERE recipient = ? AND generation = ? AND pass = ? AND path = ? AND offset = ?",
      { recipient, generation, op.pass, op.path, op.offset })
    if not rows then return nil, "unavailable" end
    if #rows > 0 then
      local row = rows[1]
      local same = (tonumber(row.bytes) == op.bytes) and row.sha256 == op.sha256
        and (tonumber(row.eof) == (op.eof and 1 or 0))
      if not same then return nil, "stale_generation" end
      return true
    end
    local inserted, why = checked_exec(self.db,
      "INSERT INTO progress_chunkproofs "
        .. "(recipient, generation, pass, path, offset, bytes, sha256, eof) "
        .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      { recipient, generation, op.pass, op.path, op.offset, op.bytes, op.sha256,
        op.eof and 1 or 0 })
    if not inserted then return nil, "sql: " .. tostring(why) end
    return true
  end
  if op.op == "ready" then
    return self:ready(self.root, recipient, generation, op)
  end
  if op.op == "invalid" then
    -- The generation is marked unusable by the cursor phase that is committed
    -- with this delta; no staging row is written or deleted.
    return true
  end
  return nil, "invalid_snapshot"
end

function Progress:ready(root, recipient, generation, op)
  local function count(sql, params)
    local rows, err = checked_query(self.db, sql, params)
    if not rows then return nil, err end
    return tonumber(rows[1] and rows[1].n) or 0
  end
  local deliveries, why = count(
    "SELECT COUNT(*) AS n FROM progress_deliveries WHERE recipient = ? AND generation = ?",
    { recipient, generation })
  if not deliveries then return nil, "unavailable" end
  local missing_metadata = count(
    "SELECT COUNT(*) AS n FROM progress_deliveries d "
      .. "LEFT JOIN progress_metadata m ON m.recipient = d.recipient "
      .. "AND m.generation = d.generation AND m.message_id = d.message_id "
      .. "WHERE d.recipient = ? AND d.generation = ? AND m.message_id IS NULL",
    { recipient, generation })
  if not missing_metadata then return nil, "unavailable" end
  if missing_metadata > 0 then return nil, "not_committed" end
  if op.first_chain ~= op.second_chain then return nil, "stale_generation" end
  local proofs1, proofs2
  proofs1, why = count("SELECT COUNT(*) AS n FROM progress_fileproofs "
    .. "WHERE recipient = ? AND generation = ? AND pass = 1", { recipient, generation })
  if not proofs1 then return nil, "unavailable" end
  proofs2, why = count("SELECT COUNT(*) AS n FROM progress_fileproofs "
    .. "WHERE recipient = ? AND generation = ? AND pass = 2", { recipient, generation })
  if not proofs2 then return nil, "unavailable" end
  if proofs1 == 0 or proofs1 ~= proofs2 then return nil, "not_committed" end
  -- Both passes must describe the same exact path set and bytes, not just the
  -- same number of rows.
  local mismatched = count(
    "SELECT COUNT(*) AS n FROM progress_fileproofs a "
      .. "LEFT JOIN progress_fileproofs b ON b.recipient = a.recipient "
      .. "AND b.generation = a.generation AND b.path = a.path AND b.pass = 2 "
      .. "WHERE a.recipient = ? AND a.generation = ? AND a.pass = 1 "
      .. "AND (b.path IS NULL OR b.present <> a.present OR b.bytes <> a.bytes "
      .. "OR b.sha256 <> a.sha256)", { recipient, generation })
  if not mismatched then return nil, "unavailable" end
  if mismatched > 0 then return nil, "stale_generation" end
  local second_only = count(
    "SELECT COUNT(*) AS n FROM progress_fileproofs a "
      .. "LEFT JOIN progress_fileproofs b ON b.recipient = a.recipient "
      .. "AND b.generation = a.generation AND b.path = a.path AND b.pass = 1 "
      .. "WHERE a.recipient = ? AND a.generation = ? AND a.pass = 2 "
      .. "AND b.path IS NULL", { recipient, generation })
  if not second_only then return nil, "unavailable" end
  if second_only > 0 then return nil, "stale_generation" end
  for pass = 1, 2 do
    local missing = count(
      "SELECT COUNT(*) AS n FROM progress_dependencies d "
        .. "LEFT JOIN progress_fileproofs f ON f.recipient = d.recipient "
        .. "AND f.generation = d.generation AND f.path = d.path AND f.pass = ? "
        .. "WHERE d.recipient = ? AND d.generation = ? AND f.path IS NULL",
      { pass, recipient, generation })
    if not missing then return nil, "unavailable" end
    if missing > 0 then return nil, "not_committed" end
  end
  return true
end

local function load(self, root, recipient)
  if root ~= self.root then return fail("invalid_snapshot", "root") end
  if not is_hex(recipient) then return fail("invalid_snapshot", "recipient") end
  local rows, err = checked_query(self.db,
    "SELECT generation, revision, cursor_json FROM progress_state "
      .. "WHERE root = ? AND recipient = ?", { root, recipient })
  if not rows then return fail("unavailable", nil, err) end
  if #rows == 0 then return fail("not_found") end
  local ok, cursor = pcall(self.json.decode, rows[1].cursor_json)
  if not ok or type(cursor) ~= "table" then return fail("corrupt", "cursor") end
  return { revision = tonumber(rows[1].revision), generation = rows[1].generation,
    cursor = cursor }
end

local function commit(self, root, recipient, expected_revision, next_state, delta)
  if root ~= self.root then return fail("invalid_snapshot", "root") end
  if not is_hex(recipient) then return fail("invalid_snapshot", "recipient") end
  if not is_integer(expected_revision) or expected_revision < 0 then
    return fail("invalid_snapshot", "expected_revision")
  end
  if not valid_cursor(next_state, self.max_line_bytes) then
    return fail("invalid_snapshot", "cursor")
  end
  local ok, field = valid_delta(delta)
  if not ok then return fail("invalid_snapshot", field) end
  local length = dense_length(delta)
  if length > self.max_stage_records then return fail("invalid_snapshot", "delta") end
  local ready_ops = 0
  for index = 1, length do
    if delta[index].op == "ready" then ready_ops = ready_ops + 1 end
  end
  if ready_ops > 1 then return fail("invalid_snapshot", "ready") end
  if ready_ops == 1 then
    if next_state.phase ~= "ready" or next_state.complete ~= true then
      return fail("invalid_snapshot", "ready")
    end
  elseif next_state.complete == true then
    return fail("invalid_snapshot", "complete")
  end
  local encoded_ok, encoded = pcall(self.json.encode, next_state)
  if not encoded_ok or type(encoded) ~= "string" then
    return fail("invalid_snapshot", "cursor")
  end
  local generation = next_state.generation
  local began, begin_why = checked_exec(self.db, "BEGIN IMMEDIATE")
  if not began then return fail("unavailable", nil, begin_why) end
  local function rollback()
    local rolled = checked_exec(self.db, "ROLLBACK")
    if rolled then return nil end
    return { code = "unknown_commit", generation = generation,
      expected_revision = expected_revision, next_revision = expected_revision + 1 }
  end
  local state_rows, state_err = checked_query(self.db,
    "SELECT generation, revision FROM progress_state WHERE root = ? AND recipient = ?",
    { root, recipient })
  if not state_rows then
    local uncertain = rollback()
    if uncertain then return nil, uncertain end
    return fail("unavailable", nil, state_err)
  end
  local exists = #state_rows > 0
  if exists then
    local current = state_rows[1]
    if tonumber(current.revision) ~= expected_revision or current.generation ~= generation then
      local uncertain = rollback()
      if uncertain then return nil, uncertain end
      return fail("stale_generation")
    end
  elseif expected_revision ~= 0 then
    local uncertain = rollback()
    if uncertain then return nil, uncertain end
    return fail("stale_generation")
  end
  for index = 1, length do
    local applied, why = add_delta(self, root, recipient, generation, delta[index])
    if not applied then
      local uncertain = rollback()
      if uncertain then return nil, uncertain end
      if why == "stale_generation" or why == "staging_conflict" then
        return fail(why)
      end
      return fail("not_committed", nil, why)
    end
  end
  if exists then
    local updated, update_why = checked_exec(self.db,
      "UPDATE progress_state SET revision = revision + 1, cursor_json = ? "
        .. "WHERE root = ? AND recipient = ?", { encoded, root, recipient })
    if not updated then
      local uncertain = rollback()
      if uncertain then return nil, uncertain end
      return fail("not_committed", nil, update_why)
    end
  else
    local inserted, insert_why = checked_exec(self.db,
      "INSERT INTO progress_state (root, recipient, generation, revision, cursor_json) "
        .. "VALUES (?, ?, ?, 1, ?)", { root, recipient, generation, encoded })
    if not inserted then
      local uncertain = rollback()
      if uncertain then return nil, uncertain end
      return fail("not_committed", nil, insert_why)
    end
  end
  local committed, commit_why = checked_exec(self.db, "COMMIT")
  if not committed then
    pcall(checked_exec, self.db, "ROLLBACK")
    return unknown(generation, expected_revision, expected_revision + 1)
  end
  return { revision = expected_revision + 1 }
end

local function generation_known(self, root, recipient, generation)
  local rows, err = checked_query(self.db,
    "SELECT 1 AS present FROM progress_state "
      .. "WHERE root = ? AND recipient = ? AND generation = ?",
    { root, recipient, generation })
  if not rows then return nil, err end
  return #rows > 0
end

local function scan(self, root, recipient, generation, kind, after_key, limit)
  if root ~= self.root then return fail("invalid_snapshot", "root") end
  if not is_hex(recipient) or not nonempty(generation) then
    return fail("invalid_snapshot", "recipient")
  end
  if not KINDS[kind] then return fail("invalid_snapshot", "kind") end
  if not is_integer(limit) or limit < 1 or limit > 256 then
    return fail("invalid_snapshot", "limit")
  end
  local known, known_err = generation_known(self, root, recipient, generation)
  if known == nil then return fail("unavailable", "generation", known_err) end
  if not known then return fail("source_unreadable", "generation") end
  local fetch = limit + 1
  local rows, err
  if kind == "deliveries" then
    local after = tonumber(after_key) or 0
    rows, err = checked_query(self.db,
      "SELECT d.message_id, d.seq, d.resent_json, m.envelope_ref, m.object_ref, m.metadata "
        .. "FROM progress_deliveries d LEFT JOIN progress_metadata m "
        .. "ON m.recipient = d.recipient AND m.generation = d.generation "
        .. "AND m.message_id = d.message_id "
        .. "WHERE d.recipient = ? AND d.generation = ? AND d.seq > ? "
        .. "ORDER BY d.seq LIMIT ?", { recipient, generation, after, fetch })
  elseif kind == "reads" then
    local after = type(after_key) == "string" and after_key or ""
    rows, err = checked_query(self.db,
      "SELECT message_id FROM progress_reads "
        .. "WHERE recipient = ? AND generation = ? AND message_id > ? "
        .. "ORDER BY message_id LIMIT ?", { recipient, generation, after, fetch })
  elseif kind == "dependencies" then
    local after = type(after_key) == "string" and after_key or ""
    rows, err = checked_query(self.db,
      "SELECT DISTINCT path FROM progress_dependencies "
        .. "WHERE recipient = ? AND generation = ? AND path > ? ORDER BY path LIMIT ?",
      { recipient, generation, after, fetch })
  elseif kind == "fileproofs" then
    local after_path, after_pass = "", 0
    if type(after_key) == "string" then
      local path, pass = after_key:match("^(.*)\t(%d+)$")
      if path then after_path, after_pass = path, tonumber(pass) end
    end
    rows, err = checked_query(self.db,
      "SELECT pass, path, present, bytes, sha256 FROM progress_fileproofs "
        .. "WHERE recipient = ? AND generation = ? "
        .. "AND (path > ? OR (path = ? AND pass > ?)) "
        .. "ORDER BY path, pass LIMIT ?",
      { recipient, generation, after_path, after_path, after_pass, fetch })
  elseif kind == "chunkproofs" then
    local after_path, after_pass, after_offset = "", 0, 0
    if type(after_key) == "string" then
      local path, pass, offset = after_key:match("^(.*)\t(%d+)\t(%d+)$")
      if path then after_path, after_pass, after_offset = path, tonumber(pass), tonumber(offset) end
    end
    rows, err = checked_query(self.db,
      "SELECT pass, path, offset, bytes, sha256, eof FROM progress_chunkproofs "
        .. "WHERE recipient = ? AND generation = ? "
        .. "AND (path > ? OR (path = ? AND (pass > ? OR (pass = ? AND offset > ?)))) "
        .. "ORDER BY path, pass, offset LIMIT ?",
      { recipient, generation, after_path, after_path, after_pass, after_pass,
        after_offset, fetch })
  end
  if not rows then return fail("unavailable", kind, err) end
  local complete = #rows <= limit
  local out = {}
  for index = 1, math.min(#rows, limit) do
    local row = rows[index]
    if row.present ~= nil then row.present = tonumber(row.present) == 1 end
    if row.eof ~= nil then row.eof = tonumber(row.eof) == 1 end
    if row.pass ~= nil then row.pass = tonumber(row.pass) end
    if row.seq ~= nil then row.seq = tonumber(row.seq) end
    row.message_id = row.message_id
    row.resent = row.resent_json
    row.resent_json = nil
    out[index] = row
  end
  local next_key
  if #out > 0 and not complete then
    local last = out[#out]
    if kind == "deliveries" then next_key = tostring(last.seq)
    elseif kind == "reads" then next_key = last.message_id
    elseif kind == "dependencies" then next_key = last.path
    elseif kind == "fileproofs" then next_key = last.path .. "\t" .. tostring(last.pass)
    elseif kind == "chunkproofs" then
      next_key = last.path .. "\t" .. tostring(last.pass) .. "\t" .. tostring(last.offset)
    end
  end
  return { rows = out, next_key = next_key, complete = complete }
end

local function get(self, root, recipient, generation, kind, key)
  if root ~= self.root then return fail("invalid_snapshot", "root") end
  if not is_hex(recipient) or not nonempty(generation) then
    return fail("invalid_snapshot", "recipient")
  end
  if not GET_KINDS[kind] then return fail("invalid_snapshot", "kind") end
  local known, known_err = generation_known(self, root, recipient, generation)
  if known == nil then return fail("unavailable", "generation", known_err) end
  if not known then return fail("source_unreadable", "generation") end
  local rows, err
  if kind == "delivery" then
    rows, err = checked_query(self.db,
      "SELECT d.message_id, d.seq, d.resent_json, m.envelope_ref, m.object_ref, m.metadata "
        .. "FROM progress_deliveries d LEFT JOIN progress_metadata m "
        .. "ON m.recipient = d.recipient AND m.generation = d.generation "
        .. "AND m.message_id = d.message_id "
        .. "WHERE d.recipient = ? AND d.generation = ? AND d.message_id = ?",
      { recipient, generation, tostring(key) })
  elseif kind == "read" then
    rows, err = checked_query(self.db,
      "SELECT message_id FROM progress_reads "
        .. "WHERE recipient = ? AND generation = ? AND message_id = ?",
      { recipient, generation, tostring(key) })
  elseif kind == "dependency" then
    rows, err = checked_query(self.db,
      "SELECT owner, role, path FROM progress_dependencies "
        .. "WHERE recipient = ? AND generation = ? AND owner = ? AND role = ?",
      { recipient, generation, tostring(key.owner), tostring(key.role) })
  elseif kind == "fileproof" then
    rows, err = checked_query(self.db,
      "SELECT present, bytes, sha256 FROM progress_fileproofs "
        .. "WHERE recipient = ? AND generation = ? AND pass = ? AND path = ?",
      { recipient, generation, key.pass, tostring(key.path) })
  elseif kind == "chunkproof" then
    rows, err = checked_query(self.db,
      "SELECT bytes, sha256, eof FROM progress_chunkproofs "
        .. "WHERE recipient = ? AND generation = ? AND pass = ? AND path = ? AND offset = ?",
      { recipient, generation, key.pass, tostring(key.path), key.offset })
  end
  if not rows then return fail("unavailable", kind, err) end
  if #rows == 0 then return { state = "absent" } end
  local row = rows[1]
  if row.present ~= nil then row.present = tonumber(row.present) == 1 end
  if row.eof ~= nil then row.eof = tonumber(row.eof) == 1 end
  if row.pass ~= nil then row.pass = tonumber(row.pass) end
  if row.seq ~= nil then row.seq = tonumber(row.seq) end
  row.resent = row.resent_json
  row.resent_json = nil
  return row
end

function M.open(config)
  if type(config) ~= "table" then return fail("invalid_snapshot", "config") end
  if not is_canonical_root(config.root) then return fail("invalid_snapshot", "root") end
  local db = config.db
  if type(db) ~= "table" or type(db.exec) ~= "function" or type(db.query) ~= "function" then
    return fail("unavailable", "db")
  end
  local json = config.json
  if type(json) ~= "table" or type(json.encode) ~= "function"
    or type(json.decode) ~= "function" then
    return fail("unavailable", "json")
  end
  local max_records = 256
  if config.max_stage_records ~= nil then
    if not is_integer(config.max_stage_records) or config.max_stage_records < 1 then
      return fail("invalid_snapshot", "max_stage_records")
    end
    max_records = config.max_stage_records
  end
  local max_line_bytes = 1024 * 1024
  if config.max_line_bytes ~= nil then
    if not is_integer(config.max_line_bytes) or config.max_line_bytes < 1 then
      return fail("invalid_snapshot", "max_line_bytes")
    end
    max_line_bytes = config.max_line_bytes
  end
  local self = setmetatable({ db = db, root = config.root, json = json,
    max_stage_records = max_records, max_line_bytes = max_line_bytes }, Progress)
  local ready, why = schema_ready(self)
  if not ready then return fail(why) end
  return { load = function(root, recipient) return load(self, root, recipient) end,
    commit = function(root, recipient, expected, next_state, delta)
      return commit(self, root, recipient, expected, next_state, delta)
    end,
    scan = function(root, recipient, generation, kind, after_key, limit)
      return scan(self, root, recipient, generation, kind, after_key, limit)
    end,
    get = function(root, recipient, generation, kind, key)
      return get(self, root, recipient, generation, kind, key)
    end }
end

M.Progress = Progress

if type(remuda) == "table" then remuda._butler_inbox_progress = M end
return M
