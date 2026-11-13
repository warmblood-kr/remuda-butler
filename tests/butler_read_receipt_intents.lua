-- Focused durable read-receipt intent tests: the real mail.lua read path and
-- the real inbox_sqlite_simple store, driven through an in-memory fake with the
-- same transaction and statement semantics. No daemon, no live database.
--
-- The fake is deliberately strict about the pieces this slice depends on:
-- an INSERT ... SELECT only sees unread rows, the primary key is unique, and
-- BEGIN/COMMIT/ROLLBACK decide whether the read and its intent survive.
local function run(command)
  local ok = os.execute(command)
  return ok == true or ok == 0
end

local function mkdir(path)
  assert(run("mkdir -p '" .. path .. "'"))
  return true
end

local function put(path, text)
  local file = assert(io.open(path, "w"))
  assert(file:write(text))
  assert(file:close())
end

local function component(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

-- A small SQLite-shaped fake. Rows are keyed exactly like the real schema.
local function fake_db()
  local db = { rows = {}, intents = {}, calls = {}, in_tx = false, snapshot = nil, fail = nil }
  local function key(recipient, id) return recipient .. "\0" .. id end
  local function copy_rows()
    local out = {}
    for index, row in ipairs(db.rows) do
      out[index] = { recipient = row.recipient, message_id = row.message_id,
        is_read = row.is_read, seq = row.seq }
    end
    return out
  end
  local function copy_intents()
    local out = {}
    for name, intent in pairs(db.intents) do
      out[name] = { recipient = intent.recipient, message_id = intent.message_id,
        read_at = intent.read_at, status = intent.status }
    end
    return out
  end
  local function save()
    return { rows = copy_rows(), intents = copy_intents() }
  end

  function db:add(recipient, id, is_read)
    db.rows[#db.rows + 1] = { recipient = recipient, message_id = id,
      is_read = is_read, seq = #db.rows + 1 }
  end

  function db:exec(sql, params)
    db.calls[#db.calls + 1] = { sql = sql, params = params }
    if db.fail and db.fail(sql, params) then return nil, "synthetic failure" end
    if sql == "BEGIN IMMEDIATE" then
      if db.in_tx then return nil, "already in a transaction" end
      db.in_tx, db.snapshot = true, save()
      return 1
    end
    if sql == "COMMIT" then
      if not db.in_tx then return nil, "no transaction" end
      db.in_tx, db.snapshot = false, nil
      return 1
    end
    if sql == "ROLLBACK" then
      if db.snapshot then
        db.rows, db.intents = db.snapshot.rows, db.snapshot.intents
      end
      db.in_tx, db.snapshot = false, nil
      return 1
    end
    if sql:find("INSERT OR IGNORE INTO read_receipt_intents", 1, true) then
      local receipt_id, recipient, id = params[1], params[2], params[3]
      for _, row in ipairs(db.rows) do
        if row.recipient == recipient and row.message_id == id and row.is_read == 0
            and not db.intents[key(recipient, id)] then
          db.intents[key(recipient, id)] = { recipient = recipient, message_id = id,
            read_at = "2026-11-13T04:00:00Z", status = "pending",
            receipt_id = receipt_id or "" }
        end
      end
      return 1
    end
    if sql:find("UPDATE simple_inbox SET is_read = 1", 1, true) then
      local recipient, id = params[1], params[2]
      for _, row in ipairs(db.rows) do
        if row.recipient == recipient and row.message_id == id and row.is_read == 0 then
          row.is_read = 1
        end
      end
      return 1
    end
    return 1
  end

  function db:query(sql, params)
    db.calls[#db.calls + 1] = { sql = sql, params = params }
    if db.fail and db.fail(sql, params) then return nil, "synthetic failure" end
    if sql:find("FROM read_receipt_intents", 1, true) then
      local recipient = params[1]
      local out = {}
      for _, intent in pairs(db.intents) do
        if intent.recipient == recipient and intent.status == "pending" then
          out[#out + 1] = intent
        end
      end
      table.sort(out, function(a, b)
        if a.read_at ~= b.read_at then return a.read_at < b.read_at end
        return a.message_id < b.message_id
      end)
      return out
    end
    if sql:find("FROM simple_inbox", 1, true) then
      local recipient = params[1]
      local out = {}
      for _, row in ipairs(db.rows) do
        if row.recipient == recipient then
          out[#out + 1] = { message_id = row.message_id, delivery = "{}",
            note = "", is_read = row.is_read, seq = row.seq }
        end
      end
      table.sort(out, function(a, b) return a.seq < b.seq end)
      return out
    end
    return {}
  end

  function db:row(id)
    for _, row in ipairs(db.rows) do
      if row.message_id == id then return row end
    end
  end

  function db:call_index(needle)
    for index, call in ipairs(db.calls) do
      if call.sql:find(needle, 1, true) then return index end
    end
  end

  return db
end

local root = os.tmpname()
os.remove(root)
assert(mkdir(root))
for _, dir in ipairs({ "inboxes", "read", "messages", "objects" }) do
  assert(mkdir(root .. "/" .. dir))
end

local function message(id, body)
  put(root .. "/messages/" .. id .. ".json",
    '{"id":"' .. id .. '","from":{"host":"local","id":"sender","alias":"sender",'
      .. '"session":"sender"},"to":[{"host":"local","id":"aa","alias":"aa",'
      .. '"session":"aa"}],"subject":"Task","created_at":"2026-11-13T04:00:00Z",'
      .. '"content_type":"text/plain","body":{"object_id":"object-' .. id .. '"}}')
  put(root .. "/objects/object-" .. id, body)
end

remuda = {
  json = { decode = function() return nil end },
  _butler_diagnostics = { record = function() end },
  _butler_new_ulid = function() return "SYNTHETIC-ULID" end,
  mkdir = mkdir,
}

local db = fake_db()
local recipient = "aa"
local mailbox = component(recipient)
local store = dofile("packages/butler/inbox_sqlite_simple.lua")

-- A reload can hand this module a database that an older build opened. The
-- schema check gates the store swap, so it must refuse an older version and an
-- unreadable one instead of letting new queries run on an old shape.
assert(store.SCHEMA_VERSION == 5, "schema constant drifted from the newest migration")
local function version_db(value)
  return { query = function(_, sql)
    assert(sql == "PRAGMA user_version", "unexpected schema query: " .. tostring(sql))
    if value == nil then return nil, "no such connection" end
    return { { user_version = value } }
  end }
end
assert(store.ready(version_db(5)) == true, "current schema was refused")
assert(store.ready(version_db(6)) == true, "newer schema was refused")
local older, older_why = store.ready(version_db(4))
assert(older == false and tostring(older_why):find("v4", 1, true) ~= nil,
  "older schema was accepted")
local broken, broken_why = store.ready(version_db(nil))
assert(broken == false and broken_why ~= nil, "unreadable schema version was accepted")

local bus = { agents = {}, inboxes = {}, messages = {}, objects = {} }
remuda._butler_mail_config = {
  bus = bus,
  root = root,
  json_quote = function(value) return '"' .. tostring(value) .. '"' end,
  simple = { db = db, store = store },
}
dofile("packages/butler/mail.lua")
local mail = assert(remuda._butler_mail)

local function reset_bus()
  bus.mail_loaded, bus.mail_read, bus.mail_unreadable = {}, {}, {}
  bus.inboxes, bus.mail_delivered, bus.mail_resent = {}, {}, {}
  bus.messages, bus.objects = {}, {}
end

local function pending(recipient)
  return store.pending_intents(db, recipient or mailbox)
end

-- A legacy read row is already read before the intent table exists. Reading
-- the mailbox must not backfill it, while the new unread row gets one intent.
db:add(mailbox, "old", 1)
db:add(mailbox, "new", 0)
message("new", "new body")
local text = assert(mail.inbox(recipient))
assert(text:find("new body", 1, true), "new message was not displayed")
assert(not text:find("old body", 1, true), "already-read message came back")
assert(db:row("new").is_read == 1, "new message was not marked read")
assert(db:row("old").is_read == 1, "legacy read row changed")
local intents = pending()
assert(#intents == 1 and intents[1].message_id == "new", "no-backfill intent")
assert(pending()[1].read_at == "2026-11-13T04:00:00Z", "intent timestamp")

-- The intent insert must run while the row is still unread; the update follows.
local insert_at = db:call_index("INSERT OR IGNORE INTO read_receipt_intents")
local update_at = db:call_index("UPDATE simple_inbox SET is_read = 1")
assert(insert_at and update_at and insert_at < update_at, "intent insert must precede the read update")

-- A duplicate read is empty and must not add a second intent.
reset_bus()
assert(mail.inbox(recipient) == "inbox empty", "duplicate read returned mail")
assert(#pending() == 1, "duplicate read added an intent")

-- The same read after a fresh process-level load still does not duplicate.
reset_bus()
assert(mail.inbox(recipient) == "inbox empty", "restart read returned mail")
assert(#pending() == 1, "restart read added an intent")

-- A failed commit rolls both the read and its intent back.
db:add(mailbox, "commitfail", 0)
message("commitfail", "commit failure body")
reset_bus()
db.fail = function(sql) return sql == "COMMIT" end
local failed = assert(mail.inbox(recipient))
assert(failed:find("mail read-state was not saved", 1, true), "failed commit was not reported")
db.fail = nil
assert(db:row("commitfail").is_read == 0, "failed commit kept the read")
assert(#pending() == 1, "failed commit kept its intent")

-- The same message succeeds on retry and then has exactly one intent.
assert(mail.inbox(recipient):find("commit failure body", 1, true), "retry did not show the message")
assert(db:row("commitfail").is_read == 1, "retry did not mark the read")
assert(#pending() == 2, "retry did not add exactly one intent")

-- A failed intent insert rolls the read back too: no read without an intent.
db:add(mailbox, "intentfail", 0)
message("intentfail", "intent failure body")
reset_bus()
db.fail = function(sql)
  return sql:find("INSERT OR IGNORE INTO read_receipt_intents", 1, true) ~= nil
end
local intent_failed = assert(mail.inbox(recipient))
assert(intent_failed:find("mail read-state was not saved", 1, true), "failed intent was not reported")
db.fail = nil
assert(db:row("intentfail").is_read == 0, "failed intent kept the read")
assert(#pending() == 2, "failed intent added a row")

-- Retrying the same message creates one intent, never two.
assert(mail.inbox(recipient):find("intent failure body", 1, true), "intent retry did not show the message")
assert(#pending() == 3, "intent retry did not add exactly one intent")

-- Calling the store directly on an already-read message is idempotent.
assert(db:exec("BEGIN IMMEDIATE", {}))
assert(store.mark_read(db, mailbox, "new"))
assert(db:exec("COMMIT", {}))
assert(#pending() == 3, "direct duplicate read added an intent")

-- Caller provenance: an agent reading its own mailbox gets one intent; an
-- operator read saves read state but creates none; a different member's read
-- also creates none. The row is not shared across recipients.
db:add("6262", "own", 0)
message("own", "own body")
reset_bus()
assert(mail.inbox("bb", { reader_id = "bb" }):find("own body", 1, true), "agent own inbox missing")
assert(db:row("own").is_read == 1, "agent own read was not saved")
assert(#pending("6262") == 1, "agent own read did not create exactly one intent")

db:add("6363", "op", 0)
message("op", "operator body")
reset_bus()
assert(mail.inbox("cc", { reader_id = nil }):find("operator body", 1, true), "operator inbox missing")
assert(db:row("op").is_read == 1, "operator read state was not saved")
assert(#pending("6363") == 0, "operator read created an agent intent")

db:add("6464", "cross", 0)
message("cross", "cross body")
reset_bus()
assert(mail.inbox("dd", { reader_id = "bb" }):find("cross body", 1, true), "cross-member inbox missing")
assert(db:row("cross").is_read == 1, "cross-member read state was not saved")
assert(#pending("6464") == 0, "cross-member read created an agent intent")

assert(run("rm -rf '" .. root .. "'"))
print("ok")
