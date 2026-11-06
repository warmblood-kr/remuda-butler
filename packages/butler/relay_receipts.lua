-- Exact Matrix reply receipts in the mod's private SQLite database.
--
-- Phase 1 is a shadow: the JSON relay state stays authoritative for dedupe,
-- caps and replay, and every write here happens only after a successful JSON
-- save. A broken or full database is reported as degraded and never changes a
-- reply outcome. There is no read authority and no reduction of the JSON
-- `matrix_reply_results` map in this phase.
--
-- This file also carries the shadow-hardening slice of the phase-2 design:
-- canonical result comparison, txn provenance, and a conflict log. None of
-- these change send behavior or promote the DB to authority.
local config = assert(remuda._butler_relay_receipts_config or {})
local json = assert(remuda.json, "relay receipts require core remuda.json")

local M = {}
local handle
local failure
local stats = { imported = 0, skipped = 0, partial = false, error = nil }
local authority_state = "unavailable"
local MAX_IMPORT_ROWS = 5000
local MAX_IMPORT_MS = 2000
local MAX_CANON_DEPTH = 8
local MAX_CANON_KEYS = 64
local MAX_CANON_ITEMS = 1024
local MAX_CANON_BYTES = 4096
local ARRAY_MT = getmetatable(json.array and json.array({}) or {})
local OBJECT_MT = getmetatable(json.object and json.object({}) or {})

local function report(outcome, reason, correlation)
  local diagnostics = remuda._butler_diagnostics
  if diagnostics and type(diagnostics.record) == "function" then
    pcall(diagnostics.record, "relay_db", outcome, reason, correlation)
  end
end

-- Native SQL failures answer `nil, reason`, so both forms are failure.
local function checked(call, ...)
  local ok, value, why = pcall(call, ...)
  if not ok then return nil, tostring(value) end
  if value == nil then return nil, tostring(why or "database call failed") end
  return value
end

local function opened()
  if failure then return nil, failure end
  if handle then return handle end
  local opener = config.open
  if type(opener) ~= "function" then
    failure = "unavailable: remuda.db.open is missing"
    return nil, failure
  end
  local ok, db, why = pcall(opener, "relay", { migrations = true, timeout_ms = 200 })
  if not ok then
    failure = "open: " .. tostring(db)
  elseif db == nil then
    failure = tostring(why or "open: unknown failure")
  else
    local rows, query_err = checked(db.query, db,
      "SELECT value FROM receipt_meta WHERE key = 'receipt_authority'")
    if rows == nil then
      failure = "authority: " .. tostring(query_err)
      pcall(db.close, db)
    elseif not rows[1] or rows[1].value ~= "shadow" then
      authority_state = "mismatch"
      failure = "authority: expected shadow, found " .. tostring(rows[1] and rows[1].value)
      pcall(db.close, db)
    else
      authority_state = "shadow"
      handle = db
    end
  end
  if not handle then report("error", "open_failed", nil) end
  return handle, failure
end

local function dispose(reason)
  if handle then pcall(handle.close, handle) end
  handle = nil
  failure = "degraded: " .. reason
  report("error", "disposed", reason)
end

local function rollback(db)
  local ok, why = checked(db.exec, db, "ROLLBACK")
  if not ok then dispose("rollback: " .. tostring(why)) end
  return ok
end

local function commit_or_dispose(db)
  local ok, why = checked(db.exec, db, "COMMIT")
  if ok then return true end
  rollback(db)
  dispose("commit: " .. tostring(why))
  return nil
end

local function existing(db, reply_id)
  local rows, why = checked(db.query, db,
    "SELECT txn_id, source_mail_id, event_id, status, completed_at, result_json, " ..
      "txn_origin, receipt_canonical FROM reply_receipts WHERE reply_id = ?", { reply_id })
  if rows == nil then return nil, why end
  return rows[1]
end

-- Canonical JSON is for equality only. It never replaces the stored bytes and
-- never truncates: a value outside the bounds is a blocking conflict class.
-- The traversal mirrors the core encoder: tagged arrays/objects, untagged
-- dense arrays, untagged empty tables are ambiguous, sparse arrays are errors.
local function encode_string(value, state)
  local ok, text = pcall(json.encode, value)
  if not ok or type(text) ~= "string" then return nil, "result_shape" end
  state.bytes = state.bytes + #text
  if state.bytes > MAX_CANON_BYTES then return nil, "result_oversize" end
  return text
end

local canonical_value

local function table_entries(value)
  local entries = {}
  for key, item in pairs(value) do entries[#entries + 1] = { key = key, value = item } end
  return entries
end

local function dense_array(entries)
  local indexes = {}
  local by_index = {}
  for _, entry in ipairs(entries) do
    if type(entry.key) ~= "number" or entry.key < 1
        or entry.key ~= math.floor(entry.key) then
      return nil, false, nil
    end
    indexes[#indexes + 1] = entry.key
    by_index[entry.key] = entry
  end
  table.sort(indexes)
  for index, value in ipairs(indexes) do
    if value ~= index then return nil, true, by_index end
  end
  return indexes, true, by_index
end

local function canonical_table(value, depth, state)
  if depth > MAX_CANON_DEPTH then return nil, "result_oversize" end
  -- Charge the item budget before copying/sorting entries. This bounds arrays
  -- as well as object keys and avoids a huge temporary copy on rejection.
  local count = 0
  for _ in pairs(value) do
    count = count + 1
    if state.items + count > MAX_CANON_ITEMS then return nil, "result_oversize" end
  end
  state.items = state.items + count
  local mt = getmetatable(value)
  local tagged_array = mt == ARRAY_MT
  local tagged_object = mt == OBJECT_MT
  local entries = table_entries(value)
  local indexes, all_positive, by_index = dense_array(entries)

  local as_array
  if tagged_array then
    as_array = true
    if #entries > 0 and (not all_positive or indexes == nil) then
      return nil, "result_shape"
    end
  elseif tagged_object then
    as_array = false
  elseif #entries == 0 then
    -- The core encoder refuses an untagged empty table: it could be {} or [].
    return nil, "result_shape"
  elseif all_positive then
    as_array = true
    if indexes == nil then return nil, "result_shape" end
  else
    as_array = false
  end

  if as_array then
    local parts = {}
    state.bytes = state.bytes + 2
    for _, index in ipairs(indexes or {}) do
      local entry = by_index[index]
      local item, why = canonical_value(entry.value, depth + 1, state)
      if item == nil then return nil, why end
      parts[#parts + 1] = item
    end
    state.bytes = state.bytes + math.max(0, #parts - 1)
    if state.bytes > MAX_CANON_BYTES then return nil, "result_oversize" end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for _, entry in ipairs(entries) do
    if type(entry.key) ~= "string" then return nil, "result_shape" end
    keys[#keys + 1] = entry.key
  end
  state.keys = state.keys + #keys
  if state.keys > MAX_CANON_KEYS then return nil, "result_oversize" end
  table.sort(keys)
  local by_key = {}
  for _, entry in ipairs(entries) do by_key[entry.key] = entry.value end
  local parts = {}
  state.bytes = state.bytes + 2 + #keys + math.max(0, #keys - 1)
  for _, key in ipairs(keys) do
    local item, why = canonical_value(by_key[key], depth + 1, state)
    if item == nil then return nil, why end
    local quoted, key_why = encode_string(key, state)
    if quoted == nil then return nil, key_why end
    parts[#parts + 1] = quoted .. ":" .. item
  end
  if state.bytes > MAX_CANON_BYTES then return nil, "result_oversize" end
  return "{" .. table.concat(parts, ",") .. "}"
end

canonical_value = function(value, depth, state)
  if depth > MAX_CANON_DEPTH then return nil, "result_oversize" end
  local kind = type(value)
  if value == nil or value == json.null then
    state.bytes = state.bytes + 4
    if state.bytes > MAX_CANON_BYTES then return nil, "result_oversize" end
    return "null"
  end
  if kind == "string" then return encode_string(value, state) end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, "result_shape"
    end
    local text
    if value == 0 then
      text = "0"
    elseif math.type and math.type(value) == "integer" then
      text = string.format("%d", value)
    elseif value == math.floor(value) and math.abs(value) <= 9007199254740992 then
      text = string.format("%.0f", value)
    else
      text = string.format("%.17g", value)
    end
    state.bytes = state.bytes + #text
    if state.bytes > MAX_CANON_BYTES then return nil, "result_oversize" end
    return text
  end
  if kind == "boolean" then
    local text = value and "true" or "false"
    state.bytes = state.bytes + #text
    return text
  end
  if kind ~= "table" then return nil, "result_shape" end
  return canonical_table(value, depth, state)
end

-- A receipt result is either absent (null) or an object. A non-object root is a
-- shape conflict; an absent result is not an empty object.
local function canonical_result(result)
  local state = { bytes = 0, keys = 0, items = 0 }
  if result == nil or result == json.null then return "null" end
  if type(result) ~= "table" then return nil, "result_shape" end
  local mt = getmetatable(result)
  if mt == ARRAY_MT then return nil, "result_shape" end
  if mt ~= OBJECT_MT then
    local indexes, all_positive = dense_array(table_entries(result))
    if all_positive and indexes ~= nil then return nil, "result_shape" end
  end
  local text, why = canonical_table(result, 1, state)
  if text == nil then return nil, why end
  return text
end

local function canonical_encoded(encoded)
  if encoded == nil or encoded == "" then return "null" end
  local ok, decoded, why = pcall(json.decode, encoded)
  if not ok or decoded == nil then return nil, "result_shape" end
  local text, shape = canonical_result(decoded)
  if text == nil then return nil, shape or "result_shape" end
  return text
end

local function canonical_witness(canonical)
  return "c1:" .. canonical
end

-- Provenance is descriptive in the shadow. It never decides whether to send.
-- `imported` rows cannot prove which attempt produced them, so a derived id is
-- historical during import; only a live `record` call can say `live`.
local function classify_txn(reply_id, txn_id, imported)
  if type(txn_id) ~= "string" or txn_id == "" then return "unclassified" end
  if txn_id:find("[^ -~]") or txn_id:match("^%s*$") then return "unclassified" end
  if txn_id == "legacy_" .. reply_id then return "legacy" end
  if imported then return "historical" end
  if txn_id == "butler_" .. reply_id then return "live" end
  return "historical"
end

local function now_utc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function record_conflict(db, reply_id, class, other_reply_id, txn_id, detail)
  local bounded = detail and tostring(detail):sub(1, 200) or nil
  local ok = checked(db.exec, db,
    "INSERT INTO receipt_conflicts " ..
      "(reply_id, other_reply_id, txn_id, class, detail, detected_at) " ..
      "VALUES (?, ?, ?, ?, ?, ?)",
    { reply_id, other_reply_id, txn_id, class, bounded, now_utc() })
  if not ok then
    report("degraded", "receipt_conflict_log", tostring(class))
  end
  return ok
end

local function same(row, receipt, expected_canonical)
  if not row then return false, "value_conflict" end
  if row.txn_id ~= receipt.txn_id
      or row.source_mail_id ~= receipt.source_mail_id
      or (row.event_id or "") ~= (receipt.event_id or "")
      or row.status ~= receipt.status
      or row.completed_at ~= receipt.completed_at then
    return false, "value_conflict"
  end
  -- Always re-derive the stored result. A cached witness alone could hide a
  -- changed result_json, which is the exact phase-1 bug this slice fixes.
  local row_canonical, row_why = canonical_encoded(row.result_json)
  if row_canonical == nil then return false, row_why end
  if row.receipt_canonical
      and row.receipt_canonical ~= canonical_witness(row_canonical) then
    return false, "digest_mismatch"
  end
  if expected_canonical == nil then return false, "result_shape" end
  if row_canonical ~= expected_canonical then return false, "value_conflict" end
  return true
end

-- One idempotent insert. A conflicting existing row is logged and degraded,
-- never overwritten: JSON remains the authority and a silent overwrite would
-- lose the disagreement.
local function write(reply_id, txn_id, source_mail_id, event_id, status,
    completed_at, result, imported)
  if type(reply_id) ~= "string" or reply_id == "" or type(txn_id) ~= "string"
      or txn_id == "" or type(source_mail_id) ~= "string"
      or type(completed_at) ~= "string" then
    return nil, "incomplete receipt"
  end
  local db, why = opened()
  if not db then return nil, why end
  local encoded
  if result ~= nil then
    local ok, text = pcall(json.encode, result)
    if not ok then return nil, "result_shape" end
    encoded = text
  end
  local canonical, canonical_why = canonical_result(result)
  if canonical == nil then
    local began = checked(db.exec, db, "BEGIN IMMEDIATE")
    if began then
      record_conflict(db, reply_id, canonical_why, nil, txn_id, canonical_why)
      commit_or_dispose(db)
    end
    report("degraded", canonical_why, reply_id)
    return nil, "conflict"
  end
  local origin = classify_txn(reply_id, txn_id, imported)
  local receipt = { txn_id = txn_id, source_mail_id = source_mail_id,
    event_id = event_id or "", status = status or "sent",
    completed_at = completed_at, result_json = encoded,
    txn_origin = origin, receipt_canonical = canonical_witness(canonical) }
  local began, begin_err = checked(db.exec, db, "BEGIN IMMEDIATE")
  if not began then
    report("degraded", "begin", tostring(begin_err))
    return nil, "begin: " .. tostring(begin_err)
  end
  local row, row_err = existing(db, reply_id)
  if row == nil and row_err ~= nil then
    rollback(db)
    report("degraded", "receipt_query", tostring(row_err))
    return nil, "query: " .. tostring(row_err)
  end
  if row then
    local equal, conflict_class = same(row, receipt, canonical)
    if equal then
      if not rollback(db) then return nil, "rollback" end
      return true
    end
    record_conflict(db, reply_id, conflict_class or "value_conflict",
      nil, txn_id, conflict_class)
    if not commit_or_dispose(db) then return nil, "conflict" end
    report("degraded", "receipt_conflict", reply_id)
    return nil, "conflict"
  end
  local inserted, insert_err = checked(db.exec, db,
    "INSERT INTO reply_receipts " ..
      "(reply_id, txn_id, source_mail_id, event_id, status, completed_at, " ..
      "result_json, txn_origin, receipt_canonical) " ..
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    { reply_id, txn_id, source_mail_id, event_id or "", status or "sent",
      completed_at, encoded, origin, receipt.receipt_canonical })
  if not inserted then
    -- A txn id owned by another reply is a conflict to log, never a reason to
    -- re-key, merge, or pick a winner.
    local owner = checked(db.query, db,
      "SELECT reply_id FROM reply_receipts WHERE txn_id = ?", { txn_id })
    if owner and owner[1] and owner[1].reply_id ~= reply_id then
      record_conflict(db, reply_id, "txn_conflict", owner[1].reply_id,
        txn_id, "txn already owned")
      commit_or_dispose(db)
      report("degraded", "txn_conflict", tostring(txn_id))
      return nil, "conflict"
    end
    rollback(db)
    report("degraded", "receipt_write", tostring(insert_err))
    return nil, "insert: " .. tostring(insert_err)
  end
  if not commit_or_dispose(db) then return nil, "commit" end
  return true
end

-- Import historical completed results in bounded batches. The JSON map is
-- unchanged; a row that already exists with a different value is logged and
-- skipped instead of overwritten.
function M.import_all(results)
  local db, why = opened()
  if not db then return nil, why end
  if type(results) ~= "table" then return true, nil, stats end
  local ids = {}
  for id in pairs(results) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  stats.imported, stats.skipped, stats.partial, stats.error = 0, 0, false, nil
  local clock
  if type(config.now) == "function" then
    clock = config.now
  elseif type(remuda.clock) == "function" then
    clock = remuda.clock
  end
  local started
  if clock then
    local ok, value = pcall(clock)
    if ok and type(value) == "number" then started = value end
  end
  for index, id in ipairs(ids) do
    if index > MAX_IMPORT_ROWS then
      stats.partial = true
      stats.error = "partial: row budget"
      break
    end
    if started then
      local ok, now = pcall(clock)
      if ok and type(now) == "number" and now - started > MAX_IMPORT_MS then
        stats.partial = true
        stats.error = "partial: time budget"
        break
      end
    end
    local item = results[id]
    if type(id) == "string" and type(item) == "table"
        and type(item.source_mail_id) == "string" and type(item.completed_at) == "string" then
      local status = item.error and "error" or "sent"
      local txn = type(item.txn_id) == "string" and item.txn_id ~= "" and item.txn_id
        or ("legacy_" .. id)
      local ok, write_err = write(id, txn, item.source_mail_id,
        item.event_id or "", status, item.completed_at, item, true)
      if ok then
        stats.imported = stats.imported + 1
      elseif write_err == "conflict" then
        stats.skipped = stats.skipped + 1
      else
        stats.error = tostring(write_err)
        return nil, stats.error
      end
    else
      stats.skipped = stats.skipped + 1
      report("degraded", "receipt_shape", tostring(id))
    end
  end
  if stats.skipped > 0 and not stats.error then
    stats.error = "degraded: " .. tostring(stats.skipped) .. " conflicting receipts"
  end
  local saved, save_err = checked(db.exec, db,
    "INSERT OR REPLACE INTO receipt_meta (key, value) VALUES ('import_committed', ?)",
    { tostring(stats.imported) })
  if not saved then
    stats.error = "meta: " .. tostring(save_err)
    report("degraded", "import_meta", stats.error)
    return nil, stats.error
  end
  return true, nil, stats
end

-- The author is the relay after a successful JSON persist. Failure never
-- raises into the reply path; it only marks this shadow degraded.
function M.record(reply_id, txn_id, receipt)
  if type(receipt) ~= "table" then return nil, "missing receipt" end
  local status = receipt.error and "error" or "sent"
  local ok, why = write(reply_id, txn_id, receipt.source_mail_id, receipt.event_id or "",
    status, receipt.completed_at, receipt, false)
  if not ok and why ~= "conflict" then report("degraded", "receipt_write", tostring(why)) end
  return ok, why
end

-- The persisted authority marker; `mismatch` must stop relay sends in phase 1.
function M.authority_state()
  opened()
  return authority_state
end

-- Read one shadow row for diagnostics/tests; phase 1 has no read authority.
function M.get(reply_id)
  local db, why = opened()
  if not db then return nil, why end
  local rows, err = checked(db.query, db,
    "SELECT reply_id, txn_id, status, txn_origin, receipt_canonical " ..
      "FROM reply_receipts WHERE reply_id = ?", { reply_id })
  if rows == nil then return nil, err end
  return rows[1]
end

local function counts_by(db, sql, column)
  local result = {}
  local rows = checked(db.query, db, sql)
  if rows then
    for _, row in ipairs(rows) do
      if row[column] ~= nil then result[tostring(row[column])] = tonumber(row.n) or 0 end
    end
  end
  return result
end

function M.status()
  opened()
  local status = {
    available = handle ~= nil and failure == nil,
    imported = stats.imported,
    skipped = stats.skipped,
    partial = stats.partial,
    error = failure or stats.error,
    authority = authority_state,
  }
  if handle then
    status.conflicts = counts_by(handle,
      "SELECT class, COUNT(*) AS n FROM receipt_conflicts GROUP BY class", "class")
    status.origins = counts_by(handle,
      "SELECT txn_origin, COUNT(*) AS n FROM reply_receipts GROUP BY txn_origin",
      "txn_origin")
  end
  return status
end

-- Internal seams for the shadow tests. They do not grant authority.
M._canonical_result = canonical_result
M._canonical_encoded = canonical_encoded
M._classify_txn = classify_txn

remuda._butler_relay_receipts = M
