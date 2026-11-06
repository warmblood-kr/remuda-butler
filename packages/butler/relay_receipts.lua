-- Exact Matrix reply receipts in the mod's private SQLite database.
--
-- Phase 1 is a shadow: the JSON relay state stays authoritative for dedupe,
-- caps and replay, and every write here happens only after a successful JSON
-- save. A broken or full database is reported as degraded and never changes a
-- reply outcome. There is no read authority and no reduction of the JSON
-- `matrix_reply_results` map in this phase.
local config = assert(remuda._butler_relay_receipts_config or {})
local json = assert(remuda.json, "relay receipts require core remuda.json")

local M = {}
local handle
local failure
local stats = { imported = 0, skipped = 0, partial = false, error = nil }
local MAX_IMPORT_ROWS = 5000

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
      failure = "authority: expected shadow"
      pcall(db.close, db)
    else
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

local function commit_or_dispose(db)
  local ok, why = checked(db.exec, db, "COMMIT")
  if ok then return true end
  checked(db.exec, db, "ROLLBACK")
  dispose("commit: " .. tostring(why))
  return nil
end

local function existing(db, reply_id)
  local rows, why = checked(db.query, db,
    "SELECT txn_id, source_mail_id, event_id, status, completed_at, result_json " ..
      "FROM reply_receipts WHERE reply_id = ?", { reply_id })
  if rows == nil then return nil, why end
  return rows[1]
end

local function same(row, receipt)
  return row
    and row.txn_id == receipt.txn_id
    and row.source_mail_id == receipt.source_mail_id
    and (row.event_id or "") == (receipt.event_id or "")
    and row.status == receipt.status
    and row.completed_at == receipt.completed_at
    and (row.result_json or "") == (receipt.result_json or "")
end

-- One idempotent insert. A conflicting existing row is degraded, never
-- overwritten: JSON remains the authority and a silent overwrite would lose
-- the disagreement.
local function write(reply_id, txn_id, source_mail_id, event_id, status, completed_at, result)
  if type(reply_id) ~= "string" or reply_id == "" or type(txn_id) ~= "string"
      or txn_id == "" or type(source_mail_id) ~= "string" or type(completed_at) ~= "string" then
    return nil, "incomplete receipt"
  end
  local db, why = opened()
  if not db then return nil, why end
  local encoded
  if result ~= nil then
    local ok, text = pcall(json.encode, result)
    if not ok then return nil, "result encode: " .. tostring(text) end
    encoded = text
  end
  local receipt = { txn_id = txn_id, source_mail_id = source_mail_id,
    event_id = event_id or "", status = status or "sent",
    completed_at = completed_at, result_json = encoded }
  local began, begin_err = checked(db.exec, db, "BEGIN IMMEDIATE")
  if not began then
    report("degraded", "begin", tostring(begin_err))
    return nil, "begin: " .. tostring(begin_err)
  end
  local row, row_err = existing(db, reply_id)
  if row == nil and row_err ~= nil then
    checked(db.exec, db, "ROLLBACK")
    report("degraded", "receipt_query", tostring(row_err))
    return nil, "query: " .. tostring(row_err)
  end
  if row then
    checked(db.exec, db, "ROLLBACK")
    if same(row, receipt) then return true end
    report("degraded", "receipt_conflict", reply_id)
    return nil, "conflict"
  end
  local inserted, insert_err = checked(db.exec, db,
    "INSERT INTO reply_receipts " ..
      "(reply_id, txn_id, source_mail_id, event_id, status, completed_at, result_json) " ..
      "VALUES (?, ?, ?, ?, ?, ?, ?)",
    { reply_id, txn_id, source_mail_id, event_id or "", status or "sent",
      completed_at, encoded })
  if not inserted then
    checked(db.exec, db, "ROLLBACK")
    report("degraded", "receipt_write", tostring(insert_err))
    return nil, "insert: " .. tostring(insert_err)
  end
  if not commit_or_dispose(db) then return nil, "commit" end
  return true
end

-- Import historical completed results in bounded batches. The JSON map is
-- unchanged; a row that already exists with a different value is skipped and
-- reported instead of overwritten.
function M.import_all(results)
  local db, why = opened()
  if not db then return nil, why end
  if type(results) ~= "table" then return true, nil, stats end
  local ids = {}
  for id in pairs(results) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  stats.imported, stats.skipped, stats.partial = 0, 0, false
  for index, id in ipairs(ids) do
    if index > MAX_IMPORT_ROWS then
      stats.partial = true
      break
    end
    local item = results[id]
    if type(id) == "string" and type(item) == "table"
        and type(item.source_mail_id) == "string" and type(item.completed_at) == "string" then
      local status = item.error and "error" or "sent"
      local ok, write_err = write(id, "legacy_" .. id, item.source_mail_id,
        item.event_id or "", status, item.completed_at, item)
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
    status, receipt.completed_at, receipt)
  if not ok and why ~= "conflict" then report("degraded", "receipt_write", tostring(why)) end
  return ok, why
end

-- Read one shadow row for diagnostics/tests; phase 1 has no read authority.
function M.get(reply_id)
  local db, why = opened()
  if not db then return nil, why end
  local rows, err = checked(db.query, db,
    "SELECT reply_id, txn_id, status FROM reply_receipts WHERE reply_id = ?", { reply_id })
  if rows == nil then return nil, err end
  return rows[1]
end

function M.status()
  opened()
  return {
    available = handle ~= nil and failure == nil,
    imported = stats.imported,
    skipped = stats.skipped,
    partial = stats.partial,
    error = failure or stats.error,
    authority = "shadow",
  }
end

remuda._butler_relay_receipts = M
