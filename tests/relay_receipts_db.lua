-- Relay receipt shadow: fake SQLite handle, no daemon.
local events = {}
local function report(subsystem, outcome, reason)
  events[#events + 1] = { subsystem = subsystem, outcome = outcome, reason = reason }
end

remuda = {
  json = {
    encode = function(value)
      local ok, text = pcall(function()
        local parts = {}
        for key, item in pairs(value) do
          parts[#parts + 1] = '"' .. key .. '":"' .. tostring(item) .. '"'
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ",") .. "}"
      end)
      if not ok then error(text) end
      return text
    end,
  },
}

local function fake_db(options)
  options = options or {}
  local db = { rows = {}, meta = { receipt_authority = options.authority or "shadow" },
    calls = {}, fail = options.fail }
  function db:exec(sql, params)
    db.calls[#db.calls + 1] = { sql = sql, params = params }
    if db.fail and db.fail(sql, params) then return nil, "synthetic failure" end
    if sql == "BEGIN IMMEDIATE" or sql == "COMMIT" or sql == "ROLLBACK" then return 1 end
    if sql:find("INSERT INTO reply_receipts", 1, true) then
      db.rows[params[1]] = { txn_id = params[2], source_mail_id = params[3],
        event_id = params[4], status = params[5], completed_at = params[6],
        result_json = params[7] }
      return 1
    end
    if sql:find("INSERT OR REPLACE INTO receipt_meta", 1, true) then
      local key = sql:match("VALUES%s*%('([^']+)'%s*,%s*%?%)") or params[1]
      local value = sql:match("%?%)") and params[1] or params[2]
      db.meta[key] = value
      return 1
    end
    return 1
  end
  function db:query(sql, params)
    params = params or {}
    db.calls[#db.calls + 1] = { sql = sql, params = params }
    if db.fail and db.fail(sql, params) then return nil, "synthetic failure" end
    if sql:find("FROM receipt_meta", 1, true) then
      local key = sql:match("key%s*=%s*'([^']+)'") or params[1]
      local value = db.meta[key]
      if value then return { { value = value } } end
      return {}
    end
    if sql:find("FROM reply_receipts", 1, true) then
      local row = db.rows[params[1]]
      if row then return { row } end
      return {}
    end
    return {}
  end
  function db:close() db.closed = true end
  return db
end

local function load(open)
  remuda._butler_relay_receipts_config = { open = open }
  remuda._butler_diagnostics = { record = report }
  dofile("packages/butler/relay_receipts.lua")
  return remuda._butler_relay_receipts
end

-- No core database: the shadow is unavailable, never an error in the reply path.
local unavailable = load(function() return nil, "remuda.db.open is missing" end)
assert(unavailable.status().available == false)
assert(unavailable.record("r0", "t0", { source_mail_id = "m0", completed_at = "now" }) == nil)

-- A non-shadow authority is refused before any write.
local wrong = load(function() return fake_db({ authority = "db-v1" }) end)
assert(wrong.status().available == false, "only shadow authority is accepted")
assert(tostring(wrong.status().error):find("shadow", 1, true))
assert(wrong.authority_state() == "mismatch", "a future authority is explicit")

local db = fake_db()
local shadow = load(function() return db end)
local receipt = { source_mail_id = "m1", event_id = "e1", completed_at = "2026-11-06T00:00:00Z" }
local first, first_why = shadow.record("r1", "butler_r1", receipt)
assert(first == true, "first shadow write: " .. tostring(first_why))
assert(db.rows.r1.txn_id == "butler_r1")
assert(db.rows.r1.status == "sent")
local again, why = shadow.record("r1", "butler_r1", receipt)
assert(again == true, "identical retry is idempotent: " .. tostring(why))

-- A different value is degraded and never overwrites the existing row.
events = {}
local changed = { source_mail_id = "m1", event_id = "e2", completed_at = "2026-11-06T00:00:00Z" }
assert(shadow.record("r1", "butler_r1", changed) == nil)
assert(db.rows.r1.event_id == "e1", "conflict must not overwrite")
assert(#events == 1 and events[1].reason == "receipt_conflict", "conflict is diagnosed")

-- Import is bounded and idempotent; legacy txns stay distinct.
events = {}
local import_db = fake_db()
local importer = load(function() return import_db end)
local results = {
  r2 = { source_mail_id = "m2", event_id = "e2", completed_at = "then" },
  r3 = { source_mail_id = "m3", event_id = "", error = "boom", completed_at = "then" },
}
local ok, err, stats = importer.import_all(results)
assert(ok == true, tostring(err))
assert(stats.imported == 2 and stats.skipped == 0)
assert(import_db.rows.r2.txn_id == "legacy_r2", "legacy import has a stable txn")
assert(import_db.rows.r3.status == "error", "a failed receipt keeps its status")
assert(importer.import_all(results) == true, "a second import is safe")
assert(import_db.meta.import_committed == "2", "committed import count is recorded")

-- A JSON result that already carries its txn id imports without conflict.
local exact_db = fake_db()
local exact = load(function() return exact_db end)
assert(exact.import_all({ r9 = { source_mail_id = "m9", event_id = "e9",
  txn_id = "butler_r9", completed_at = "now" } }) == true)
assert(exact_db.rows.r9.txn_id == "butler_r9", "exact live txn is preserved")

-- A failed rollback disposes the handle instead of reusing a dirty transaction.
local rollback_db = fake_db({ fail = function(sql)
  return sql:find("INSERT INTO reply_receipts", 1, true) ~= nil or sql == "ROLLBACK"
end })
local dirty = load(function() return rollback_db end)
events = {}
assert(dirty.record("r5", "butler_r5", { source_mail_id = "m5", completed_at = "now" }) == nil)
assert(dirty.status().available == false, "a failed rollback disposes the handle")

-- A malformed receipt is skipped visibly, not guessed.
events = {}
assert(importer.import_all({ bad = { event_id = "x" } }) == true)
assert(#events >= 1 and events[1].reason == "receipt_shape")

-- A failure after the JSON save is degraded and never raised.
local broken_db = fake_db({ fail = function(sql) return sql:find("INSERT INTO reply_receipts", 1, true) ~= nil end })
local broken = load(function() return broken_db end)
events = {}
assert(broken.record("r4", "butler_r4", { source_mail_id = "m4", completed_at = "now" }) == nil)
assert(#events >= 1 and events[1].subsystem == "relay_db")

print("ok")
