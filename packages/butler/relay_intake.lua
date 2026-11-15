-- Shadow relay intake and cursor state.
--
-- The JSON relay state stays authoritative in this phase: this module only
-- mirrors admitted events and the cursor into the 0003 relay tables. It does
-- not hand off mail, send, prune or decide delivery, and no relay code calls
-- `admit` yet. A failure is reported as degraded and never changes a JSON
-- outcome.
--
-- One BEGIN IMMEDIATE binds the inbound rows and cursor. The batch must be a
-- dense array; a hole is rejected before the transaction. A duplicate with a
-- different room/payload aborts the batch; a cap or SQL failure rolls both
-- rows and cursor back. A failed rollback disposes the handle (fail closed).
-- The cap counts unresolved payload_json bytes only, not IDs, cursor, row/index
-- overhead or completed rows: it is not a total storage bound. `generation` is
-- a placeholder; no ownership fence is claimed.
local config = assert(remuda._butler_relay_intake_config or {})

local M = {}
local handle
local failure

local DEFAULTS = {
  unresolved_max_rows = 100,
  unresolved_max_payload_bytes = 1024 * 1024,
}

local MAX_ID_BYTES = 1024
local MAX_CURSOR_BYTES = 4096

local function report(outcome, reason, correlation)
  local diagnostics = remuda._butler_diagnostics
  if diagnostics and type(diagnostics.record) == "function" then
    pcall(diagnostics.record, "relay_intake", outcome, reason, correlation)
  end
end

local function checked(db, method, sql, args)
  local ok, result, why = pcall(db[method], db, sql, args or {})
  if not ok then return nil, tostring(result) end
  if result == nil then return nil, tostring(why or "database call failed") end
  return result
end

local function dispose(reason)
  if handle then pcall(handle.close, handle) end
  handle = nil
  failure = "degraded: " .. tostring(reason)
  report("error", "disposed", reason)
end

local function opened()
  if failure then return nil, failure end
  if handle then return handle end
  local opener = config.open
  if type(opener) ~= "function" then
    failure = "unavailable: remuda.db.open is missing"
    return nil, failure
  end
  local ok, db, why = pcall(opener, config.name or "relay",
    { migrations = true, timeout_ms = 200 })
  if not ok then
    failure = "open: " .. tostring(db)
    return nil, failure
  end
  if db == nil then
    failure = tostring(why or "open: unknown failure")
    return nil, failure
  end
  local rows, query_why = checked(db, "query",
    "SELECT value FROM relay_meta WHERE key = 'authority'")
  if rows == nil then
    failure = "authority: " .. tostring(query_why)
    pcall(db.close, db)
    return nil, failure
  end
  if not rows[1] or rows[1].value ~= "shadow" then
    failure = "authority: expected shadow, found "
      .. tostring(rows[1] and rows[1].value)
    pcall(db.close, db)
    return nil, failure
  end
  handle = db
  return handle
end

function M.config(overrides)
  local cfg = {}
  for key, value in pairs(DEFAULTS) do cfg[key] = value end
  for key, value in pairs(config.limits or {}) do cfg[key] = value end
  for key, value in pairs(overrides or {}) do cfg[key] = value end
  return cfg
end

local function count(db, sql, args)
  local rows, why = checked(db, "query", sql, args)
  if rows == nil then return nil, why end
  return tonumber(rows[1] and rows[1].n) or 0
end

local function unresolved(db)
  local rows, why = count(db,
    "SELECT (SELECT COUNT(*) FROM relay_inbound " ..
      "WHERE state IN ('unhanded','handoff_pending')) + " ..
      "(SELECT COUNT(*) FROM relay_outbox " ..
      "WHERE state IN ('pending','in_flight','uncertain')) AS n")
  return rows, why
end

local function unresolved_payload_bytes(db)
  local rows, why = count(db,
    "SELECT (SELECT COALESCE(SUM(length(CAST(payload_json AS BLOB))),0) " ..
      "FROM relay_inbound WHERE state IN ('unhanded','handoff_pending')) + " ..
      "(SELECT COALESCE(SUM(length(CAST(payload_json AS BLOB))),0) " ..
      "FROM relay_outbox WHERE state IN ('pending','in_flight','uncertain')) AS n")
  return rows, why
end

local function valid_event(event)
  return type(event) == "table"
    and type(event.event_id) == "string" and event.event_id ~= ""
    and #event.event_id <= MAX_ID_BYTES
    and type(event.room_id) == "string" and #event.room_id <= MAX_ID_BYTES
    and type(event.payload_json) == "string"
end

local function valid_batch(events)
  if type(events) ~= "table" then return false, "events must be a list" end
  local count = 0
  for key in pairs(events) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false, "events must be a list"
    end
    count = count + 1
  end
  for index = 1, count do
    if events[index] == nil then return false, "events must be a dense list" end
  end
  return true
end

local function rollback(db)
  local ok, why = checked(db, "exec", "ROLLBACK")
  if not ok then dispose("rollback: " .. tostring(why)) end
  return ok
end

-- Admit a batch and advance the cursor in one transaction. Returns
-- `stats, nil` or `nil, reason`.
function M.admit(events, since, now, overrides)
  local dense, batch_why = valid_batch(events)
  if not dense then return nil, batch_why end
  local cfg = M.config(overrides)
  if type(cfg.unresolved_max_rows) ~= "number" or cfg.unresolved_max_rows < 1
    or cfg.unresolved_max_rows % 1 ~= 0
    or type(cfg.unresolved_max_payload_bytes) ~= "number"
    or cfg.unresolved_max_payload_bytes < 1
    or cfg.unresolved_max_payload_bytes % 1 ~= 0 then
    return nil, "invalid limits"
  end
  local db, open_why = opened()
  if not db then return nil, open_why end
  now = tonumber(now) or 0
  local began, begin_why = checked(db, "exec", "BEGIN IMMEDIATE")
  if not began then
    report("error", "begin_failed", begin_why)
    return nil, "begin: " .. tostring(begin_why)
  end
  local ok, stats, reason = pcall(function()
    local inserted, duplicates = 0, 0
    for _, event in ipairs(events or {}) do
      if not valid_event(event) then return nil, "invalid event" end
      local prior, prior_why = checked(db, "query",
        "SELECT room_id, payload_json FROM relay_inbound WHERE event_id = ?",
        { event.event_id })
      if prior == nil then return nil, "query: " .. tostring(prior_why) end
      if prior[1] then
        if prior[1].room_id ~= event.room_id
          or prior[1].payload_json ~= event.payload_json then
          return nil, "identity conflict"
        end
        duplicates = duplicates + 1
      else
        local rows, rows_why = unresolved(db)
        if rows == nil then return nil, "count: " .. tostring(rows_why) end
        if rows >= cfg.unresolved_max_rows then
          return nil, "backpressure: unresolved"
        end
        local bytes, bytes_why = unresolved_payload_bytes(db)
        if bytes == nil then return nil, "count: " .. tostring(bytes_why) end
        if bytes + #event.payload_json > cfg.unresolved_max_payload_bytes then
          return nil, "backpressure: payload bytes"
        end
        local wrote, write_why = checked(db, "exec",
          "INSERT INTO relay_inbound (event_id, room_id, received_at, " ..
            "payload_json, state) VALUES (?, ?, ?, ?, 'unhanded')",
          { event.event_id, event.room_id, tonumber(event.received_at) or now,
            event.payload_json })
        if not wrote then return nil, "insert: " .. tostring(write_why) end
        inserted = inserted + 1
      end
    end
    if since ~= nil then
      if type(since) ~= "string" or #since > MAX_CURSOR_BYTES then
        return nil, "invalid cursor"
      end
      local row, cursor_why = checked(db, "query",
        "SELECT id FROM relay_cursor WHERE id = 1")
      if row == nil then return nil, "cursor: " .. tostring(cursor_why) end
      local wrote, write_why
      if row[1] then
        wrote, write_why = checked(db, "exec",
          "UPDATE relay_cursor SET since = ?, updated_at = ? WHERE id = 1",
          { since, now })
      else
        wrote, write_why = checked(db, "exec",
          "INSERT INTO relay_cursor (id, since, updated_at, generation) " ..
            "VALUES (1, ?, ?, 'shadow')", { since, now })
      end
      if not wrote then return nil, "cursor: " .. tostring(write_why) end
    end
    return { inserted = inserted, duplicates = duplicates }
  end)
  if not ok or stats == nil then
    local why = ok and reason or stats
    if not rollback(db) then
      report("error", "rollback_failed", why)
      return nil, "rollback: " .. tostring(why)
    end
    report("error", "admit_failed", why)
    return nil, tostring(why)
  end
  local committed, commit_why = checked(db, "exec", "COMMIT")
  if not committed then
    rollback(db)
    dispose("commit: " .. tostring(commit_why))
    return nil, "commit: " .. tostring(commit_why)
  end
  return stats
end

function M.cursor()
  local db, why = opened()
  if not db then return nil, why end
  local rows, query_why = checked(db, "query",
    "SELECT since FROM relay_cursor WHERE id = 1")
  if rows == nil then return nil, query_why end
  return rows[1] and rows[1].since or nil
end

function M.status()
  local db, why = opened()
  if not db then return { available = false, reason = why } end
  local rows, rows_why = unresolved(db)
  if rows == nil then return { available = false, reason = rows_why } end
  local bytes, bytes_why = unresolved_payload_bytes(db)
  if bytes == nil then return { available = false, reason = bytes_why } end
  local cfg = M.config()
  return {
    available = true,
    authority = "shadow",
    unresolved = rows,
    unresolved_payload_bytes = bytes,
    backpressure = {
      unresolved = rows >= cfg.unresolved_max_rows,
      payload_bytes = bytes >= cfg.unresolved_max_payload_bytes,
    },
    cursor = M.cursor(),
  }
end

function M.close()
  if handle then pcall(handle.close, handle) end
  handle = nil
  failure = nil
end

opened()
remuda._butler_relay_intake = M
return M
