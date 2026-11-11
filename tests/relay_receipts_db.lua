-- Relay receipt shadow: fake SQLite handle, no daemon.
local events = {}
local function report(subsystem, outcome, reason)
  events[#events + 1] = { subsystem = subsystem, outcome = outcome, reason = reason }
end

local ARRAY_MT, OBJECT_MT = {}, {}
local JSON_NULL = {}
local encoded_values = {}

local function repr(value)
  if value == nil or value == JSON_NULL then return "null" end
  local kind = type(value)
  if kind == "string" then return "s" .. #value .. ":" .. value end
  if kind == "number" then
    if value == 0 then return "n0" end
    if value == math.floor(value) then return "n" .. string.format("%.0f", value) end
    return "n" .. string.format("%.17g", value)
  end
  if kind == "boolean" then return value and "b1" or "b0" end
  if kind ~= "table" then return "?" .. kind end
  local mt = getmetatable(value)
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  if mt == ARRAY_MT then
    local parts = {}
    for index = 1, #value do parts[#parts + 1] = repr(value[index]) end
    return "a[" .. table.concat(parts, ",") .. "]"
  end
  if mt == OBJECT_MT then
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = repr(key) .. "=" .. repr(value[key]) end
    return "o{" .. table.concat(parts, ",") .. "}"
  end
  if #keys == 0 then return "e{}" end
  local dense = true
  for index = 1, #keys do if value[index] == nil then dense = false break end end
  if dense and #value == #keys then
    local parts = {}
    for index = 1, #value do parts[#parts + 1] = repr(value[index]) end
    return "a[" .. table.concat(parts, ",") .. "]"
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = repr(key) .. "=" .. repr(value[key]) end
  return "o{" .. table.concat(parts, ",") .. "}"
end

remuda = {
  json = {
    null = JSON_NULL,
    array = function(value)
      return setmetatable(value or {}, ARRAY_MT)
    end,
    object = function(value)
      return setmetatable(value or {}, OBJECT_MT)
    end,
    encode = function(value)
      local text = repr(value)
      encoded_values[text] = value
      return text
    end,
    decode = function(text)
      local value = encoded_values[text]
      if value == nil then return nil, "not in the test codec" end
      return value
    end,
  },
}

local function fake_db(options)
  options = options or {}
  local db = { rows = {}, conflicts = {},
    meta = { receipt_authority = options.authority or "shadow" },
    calls = {}, fail = options.fail }
  function db:exec(sql, params)
    db.calls[#db.calls + 1] = { sql = sql, params = params }
    if db.fail and db.fail(sql, params) then return nil, "synthetic failure" end
    if sql == "BEGIN IMMEDIATE" or sql == "COMMIT" or sql == "ROLLBACK" then return 1 end
    if sql:find("INSERT INTO reply_receipts", 1, true) then
      for _, row in pairs(db.rows) do
        if row.txn_id == params[2] then return nil, "UNIQUE constraint failed: reply_receipts.txn_id" end
      end
      db.rows[params[1]] = { txn_id = params[2], source_mail_id = params[3],
        event_id = params[4], status = params[5], completed_at = params[6],
        result_json = params[7], txn_origin = params[8], receipt_canonical = params[9] }
      return 1
    end
    if sql:find("INSERT INTO receipt_conflicts", 1, true) then
      db.conflicts[#db.conflicts + 1] = {
        reply_id = params[1], other_reply_id = params[2], txn_id = params[3],
        class = params[4], detail = params[5], detected_at = params[6] }
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
      if sql:find("WHERE txn_id", 1, true) then
        for reply_id, row in pairs(db.rows) do
          if row.txn_id == params[1] then
            return { { reply_id = reply_id, txn_id = row.txn_id } }
          end
        end
        return {}
      end
      local row = db.rows[params[1]]
      if row then return { row } end
      return {}
    end
    if sql:find("FROM receipt_conflicts", 1, true) then
      local counts = {}
      for _, row in ipairs(db.conflicts) do
        counts[row.class] = (counts[row.class] or 0) + 1
      end
      local rows = {}
      for class, n in pairs(counts) do rows[#rows + 1] = { class = class, n = n } end
      return rows
    end
    return {}
  end
  function db:close() db.closed = true end
  return db
end

local function conflict(db, reply_id, class)
  for _, row in ipairs(db.conflicts) do
    if row.reply_id == reply_id and row.class == class then return row end
  end
end

local function load(open)
  remuda._butler_relay_receipts_config = { open = open }
  remuda._butler_diagnostics = { record = report }
  dofile("packages/butler/relay_receipts.lua")
  return remuda._butler_relay_receipts
end

local open_count = 0
local not_opened = load(function() open_count = open_count + 1; return fake_db() end)
assert(not not_opened.peek_status().available and open_count == 0,
  "doctor snapshot must not open or migrate the database")

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
shadow.status()
db.fail = function(sql) return sql:find("FROM receipt_conflicts GROUP BY", 1, true) ~= nil end
assert(shadow.peek_status().error, "failed conflict query must not look healthy")
db.fail = nil
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

-- A live record followed by a reload import of the same JSON result is
-- idempotent, not a txn-provenance conflict.
local reload_db = fake_db()
local live = load(function() return reload_db end)
local live_receipt = { source_mail_id = "m8", event_id = "e8", txn_id = "butler_r8",
  completed_at = "now" }
assert(live.record("r8", "butler_r8", live_receipt) == true)
assert(live.import_all({ r8 = live_receipt }) == true)
assert(reload_db.rows.r8.txn_id == "butler_r8")

-- A slow injected clock stops the import inside its row budget.
local slow_db = fake_db()
local calls = 0
local slow_clock = function()
  calls = calls + 1
  return calls > 1 and 3000 or 0
end
remuda.clock = slow_clock
local slow = load(function() return slow_db end)
local many = {}
for index = 1, 20 do
  many["r" .. index] = { source_mail_id = "m" .. index, event_id = "e", completed_at = "now" }
end
assert(slow.import_all(many) == true)
assert(slow.status().partial == true, "time budget marks partial")
assert(tostring(slow.status().error):find("time budget", 1, true))
remuda.clock = nil

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

-- Shadow hardening: canonical result equality ignores object key order.
local canon_db = fake_db()
local canon = load(function() return canon_db end)
local base = { source_mail_id = "m", event_id = "e", completed_at = "now",
  extra = { b = 2, a = 1 } }
assert(canon.record("rc1", "butler_rc1", base) == true)
local reordered = { source_mail_id = "m", event_id = "e", completed_at = "now",
  extra = { a = 1, b = 2 } }
assert(canon.record("rc1", "butler_rc1", reordered) == true,
  "key order alone must not be a conflict")
assert(canon_db.rows.rc1.txn_origin == "live", "derived live txn")

-- Array order is data: reordered event_ids is a value conflict.
local first_array = { source_mail_id = "m", event_id = "e", completed_at = "now",
  event_ids = remuda.json.array({ "a", "b" }) }
assert(canon.record("rc2", "butler_rc2", first_array) == true)
local second_array = { source_mail_id = "m", event_id = "e", completed_at = "now",
  event_ids = remuda.json.array({ "b", "a" }) }
assert(canon.record("rc2", "butler_rc2", second_array) == nil)
assert(conflict(canon_db, "rc2", "value_conflict"), "array order conflict is logged")
assert(canon_db.rows.rc2.receipt_canonical ~= nil, "canonical digest is stored")

-- Provenance: import cannot claim a live attempt, and a missing txn is legacy.
local prov_db = fake_db()
local prov = load(function() return prov_db end)
assert(prov.import_all({
  p1 = { source_mail_id = "m1", txn_id = "caller-1", completed_at = "now" },
  p2 = { source_mail_id = "m2", completed_at = "now" },
}) == true)
assert(prov_db.rows.p1.txn_origin == "historical", "custom txn is historical")
assert(prov_db.rows.p2.txn_origin == "legacy", "missing txn is legacy")

-- A txn id owned by another reply is a logged conflict, never re-keyed.
local txn_db = fake_db()
local txn = load(function() return txn_db end)
assert(txn.record("ta", "same-txn", { source_mail_id = "ma", completed_at = "now" }) == true)
assert(txn.record("tb", "same-txn", { source_mail_id = "mb", completed_at = "now" }) == nil)
assert(txn_db.rows.tb == nil, "conflicting reply is not inserted")
assert(conflict(txn_db, "tb", "txn_conflict"), "txn conflict is logged")
assert(conflict(txn_db, "tb", "txn_conflict").other_reply_id == "ta")

-- Oversized or non-object results are blocking conflict classes, never truncated.
local big = {}
for index = 1, 65 do big["k" .. index] = index end
local shape_db = fake_db()
local shape = load(function() return shape_db end)
assert(shape.record("big", "butler_big",
  { source_mail_id = "m", completed_at = "now", big = big }) == nil)
assert(conflict(shape_db, "big", "result_oversize"), "oversize result is logged")
assert(shape.record("weird", "butler_weird",
  { source_mail_id = "m", completed_at = "now", weird = { [1] = "x", a = "b" } }) == nil)
assert(conflict(shape_db, "weird", "result_shape"), "non-string key is a shape conflict")
local summary = shape.status()
assert(summary.conflicts.result_oversize == 1 and summary.conflicts.result_shape == 1,
  "status exposes conflict classes")

-- A changed stored result_json must be detected even when the witness is stale.
local tamper_db = fake_db()
local tamper = load(function() return tamper_db end)
local tamper_receipt = { source_mail_id = "m", event_id = "e", completed_at = "now" }
assert(tamper.record("rt", "butler_rt", tamper_receipt) == true)
local witness = tamper_db.rows.rt.receipt_canonical
tamper_db.rows.rt.result_json = remuda.json.encode(
  { source_mail_id = "m", event_id = "different", completed_at = "now" })
assert(tamper.record("rt", "butler_rt", tamper_receipt) == nil)
assert(conflict(tamper_db, "rt", "digest_mismatch"), "stale witness is detected")
assert(tamper_db.rows.rt.receipt_canonical == witness, "conflict does not rewrite")

-- Core encoder semantics: an untagged dense array is an array.
local array_db = fake_db()
local array_receipts = load(function() return array_db end)
local untagged = { source_mail_id = "m", event_id = "e", completed_at = "now",
  event_ids = { "a", "b" } }
assert(array_receipts.record("ua", "butler_ua", untagged) == true)
local untagged_reordered = { source_mail_id = "m", event_id = "e",
  completed_at = "now", event_ids = { "b", "a" } }
assert(array_receipts.record("ua", "butler_ua", untagged_reordered) == nil)
assert(conflict(array_db, "ua", "value_conflict"), "untagged array order is data")

-- Ambiguous empty table and sparse array are shape conflicts, not objects.
assert(array_receipts.record("ue", "butler_ue",
  { source_mail_id = "m", completed_at = "now", empty = {} }) == nil)
assert(conflict(array_db, "ue", "result_shape"))
assert(array_receipts.record("us", "butler_us",
  { source_mail_id = "m", completed_at = "now", sparse = { [1] = "a", [3] = "c" } }) == nil)
assert(conflict(array_db, "us", "result_shape"))

-- The canonical budget is charged during traversal, including arrays.
local huge = {}
for index = 1, 5000 do huge[index] = "x" end
assert(array_receipts.record("uh", "butler_uh",
  { source_mail_id = "m", completed_at = "now", event_ids = huge }) == nil)
assert(conflict(array_db, "uh", "result_oversize"))

-- Signed zero is one numeric value; distinct numbers are not equal.
local number_db = fake_db()
local numbers = load(function() return number_db end)
assert(numbers.record("n0", "butler_n0",
  { source_mail_id = "m", completed_at = "now", n = -0.0 }) == true)
assert(numbers.record("n0", "butler_n0",
  { source_mail_id = "m", completed_at = "now", n = 0 }) == true)
assert(numbers.record("n1", "butler_n1",
  { source_mail_id = "m", completed_at = "now", n = 1 }) == true)
assert(numbers.record("n1", "butler_n1",
  { source_mail_id = "m", completed_at = "now", n = 1.5 }) == nil)

-- Root arrays (tagged or untagged dense) are not receipt objects.
assert(shape._canonical_result(remuda.json.array({ "a" })) == nil)
assert(shape._canonical_result({ "a", "b" }) == nil)
assert(shape._canonical_result(remuda.json.object({})) == "{}")

-- Provenance policy is the same as the SQL backfill: printable ASCII only.
assert(shape._classify_txn("r", "butler_r", false) == "live")
assert(shape._classify_txn("r", "caller", false) == "historical")
assert(shape._classify_txn("r", "caller-\1", false) == "unclassified")
assert(shape._classify_txn("r", "caller-\195\169", false) == "unclassified")

-- A migrated phase-1 row has no canonical witness; comparison must decode it.
local legacy_db = fake_db()
local legacy = load(function() return legacy_db end)
local legacy_receipt = { source_mail_id = "m", event_id = "e", completed_at = "now" }
legacy_db.rows.old = { txn_id = "butler_old", source_mail_id = "m", event_id = "e",
  status = "sent", completed_at = "now",
  result_json = remuda.json.encode(legacy_receipt), receipt_canonical = nil }
assert(legacy.record("old", "butler_old", legacy_receipt) == true,
  "a migrated row without a witness still compares canonically")
legacy_db.rows.old.result_json = remuda.json.encode(
  { source_mail_id = "m", event_id = "different", completed_at = "now" })
assert(legacy.record("old", "butler_old", legacy_receipt) == nil)
assert(conflict(legacy_db, "old", "value_conflict"))
