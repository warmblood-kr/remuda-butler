-- QA owner for the relay 0003 migration test.
--
-- The shell wrapper copies this file over packages/butler/init.lua in a
-- disposable tree. It opens the relay database from mod code (the only place
-- remuda.db.open is allowed) and runs one phase selected by RELAY3_PHASE.
local host = getmetatable(_G).__index.remuda
local phase = assert(os.getenv("RELAY3_PHASE"), "RELAY3_PHASE is required")

local function rows(db, sql, args)
  local result, err = db:query(sql, args or {})
  assert(result, err)
  return result
end

local function exec(db, sql, args)
  local changes, err = db:exec(sql, args or {})
  assert(changes, err)
  return changes
end

local function number(db, sql, args)
  return tonumber(rows(db, sql, args)[1].n)
end

local function version(db)
  return tonumber(rows(db, "PRAGMA user_version")[1].user_version)
end

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return {} end,
  start = function()
    local db = assert(host.db.open("relay", { migrations = true }))

    if phase == "old" then
      assert(version(db) == 2, "the fixture must start at 0002")
      exec(db, "INSERT INTO reply_receipts (reply_id, txn_id, " ..
        "source_mail_id, event_id, status, completed_at) VALUES (?, ?, ?, ?, ?, ?)",
        { "r-old", "t-old", "m-old", "ev-old", "sent", "2026-11-14" })
      print("relay 0003 old: populated 0002")
      pcall(db.close, db)
      return
    end

    assert(version(db) == 3, "expected 0003")
    local authority = rows(db, "SELECT value FROM relay_meta WHERE key = ?",
      { "authority" })
    assert(#authority == 1 and authority[1].value == "shadow")

    if phase == "upgrade" then
      assert(number(db, "SELECT COUNT(*) AS n FROM reply_receipts " ..
        "WHERE reply_id = ?", { "r-old" }) == 1)
      print("relay 0003 upgrade: receipt preserved")
    elseif phase == "unresolved" then
      exec(db, "INSERT INTO relay_inbound (event_id, room_id, received_at, " ..
        "payload_json, state) VALUES (?, ?, ?, ?, ?)",
        { "e-unresolved", "room", 100, "{}", "unhanded" })
      exec(db, "INSERT INTO relay_outbox (reply_id, txn_id, source_mail_id, " ..
        "room_id, event_id, payload_json, state, created_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        { "r-unresolved", "t-unresolved", "m-1", "room", "ev-1", "{}",
          "in_flight", 100 })
      exec(db, "INSERT INTO relay_dedupe (kind, key, first_seen, state) " ..
        "VALUES ('reply_txn', ?, ?, 'open')", { "t-unresolved", 100 })
      print("relay 0003 unresolved: seeded")
    elseif phase == "resolve" then
      exec(db, "UPDATE relay_inbound SET state = 'handed' WHERE event_id = ?",
        { "e-unresolved" })
      exec(db, "UPDATE relay_outbox SET state = 'sent' WHERE reply_id = ?",
        { "r-unresolved" })
      exec(db, "UPDATE relay_dedupe SET state = 'resolved' " ..
        "WHERE kind = 'reply_txn' AND key = ?", { "t-unresolved" })
      print("relay 0003 resolve: ok")
    elseif phase == "reup" then
      assert(number(db, "SELECT COUNT(*) AS n FROM relay_inbound_v3_archive " ..
        "WHERE event_id = ?", { "e-unresolved" }) == 1)
      assert(number(db, "SELECT COUNT(*) AS n FROM reply_receipts " ..
        "WHERE reply_id = ?", { "r-old" }) == 1)
      exec(db, "INSERT INTO relay_inbound (event_id, room_id, received_at, " ..
        "payload_json, state) VALUES (?, ?, ?, ?, ?)",
        { "e-live", "room", 200, "{}", "handed" })
      exec(db, "INSERT INTO relay_outbox (reply_id, txn_id, source_mail_id, " ..
        "room_id, event_id, payload_json, state, created_at) " ..
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        { "r-live", "t-live", "m-2", "room", "ev-2", "{}", "sent", 200 })
      exec(db, "INSERT INTO relay_dedupe (kind, key, first_seen, state) " ..
        "VALUES ('reply_txn', ?, ?, 'resolved')", { "t-live", 200 })
      exec(db, "INSERT INTO relay_cursor (id, since, updated_at, generation) " ..
        "VALUES (1, 's-live', 200, 'g-live')")
      exec(db, "INSERT INTO relay_meta (key, value) VALUES ('live-check', '1')")
      print("relay 0003 reup: live rows seeded")
    else
      error("unknown phase: " .. tostring(phase), 0)
    end
    pcall(db.close, db)
  end,
}
