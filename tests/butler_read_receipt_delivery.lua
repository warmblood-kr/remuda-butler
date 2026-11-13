-- Focused local read-receipt delivery tests: the real mail.lua, the real
-- inbox_sqlite_simple store and the real read_receipts module, driven through
-- an in-memory SQLite-shaped fake. No daemon, no live database, no Matrix I/O.
--
-- The fake enforces the pieces this slice relies on: the read+intent
-- transaction, the pending-intent join, the deterministic receipt ID and the
-- status completion mark. The JSON decoder is a narrow envelope reader for the
-- test, not a general JSON implementation.
local function run(command)
  local ok = os.execute(command)
  return ok == true or ok == 0
end

local function mkdir(path)
  assert(run("mkdir -p '" .. path .. "'"))
  return true
end

local function component(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

local function json_quote(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function put(path, text)
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  assert(file:close())
end

-- Narrow envelope decoder: enough of the stored envelope for delivery.
local function field(text, key)
  return text:match('"' .. key .. '":"(.-)"')
end

local function decode_envelope(text)
  if type(text) ~= "string" then return nil end
  local from = text:match('"from":(%b{})')
  local to = text:match('"to":%[(%b{})%]')
  local matrix = text:match('"matrix":(%b{})')
  return {
    from = from and { host = field(from, "host"), id = field(from, "id") or "",
      alias = field(from, "alias"), session = field(from, "session"),
      kind = field(from, "kind"), leader = field(from, "leader") } or nil,
    to = to and { { host = field(to, "host"), id = field(to, "id") or "",
      alias = field(to, "alias"), session = field(to, "session"),
      kind = field(to, "kind"), leader = field(to, "leader") } } or {},
    receipt_of = field(text, "receipt_of"),
    matrix = matrix and { event_id = field(matrix, "event_id"),
      room_id = field(matrix, "room_id") } or nil,
  }
end

local function fake_db()
  local db = { rows = {}, intents = {}, calls = {}, in_tx = false, snapshot = nil, fail = nil }
  local function key(recipient, id) return recipient .. "\0" .. id end
  local function copy_rows()
    local out = {}
    for index, row in ipairs(db.rows) do
      out[index] = {}
      for name, value in pairs(row) do out[index][name] = value end
    end
    return out
  end
  local function copy_intents()
    local out = {}
    for name, intent in pairs(db.intents) do
      out[name] = {}
      for field_name, value in pairs(intent) do out[name][field_name] = value end
    end
    return out
  end
  local function save() return { rows = copy_rows(), intents = copy_intents() } end

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
      if db.snapshot then db.rows, db.intents = db.snapshot.rows, db.snapshot.intents end
      db.in_tx, db.snapshot = false, nil
      return 1
    end
    if sql:find("INSERT OR IGNORE INTO read_receipt_intents", 1, true) then
      local receipt_id, recipient, id = params[1], params[2], params[3]
      for _, row in ipairs(db.rows) do
        if row.recipient == recipient and row.message_id == id and row.is_read == 0
            and not db.intents[key(recipient, id)] then
          db.intents[key(recipient, id)] = { recipient = recipient, message_id = id,
            read_at = "2026-11-13T05:00:00Z", status = "pending",
            receipt_id = receipt_id or "" }
        end
      end
      return 1
    end
    if sql:find("INSERT INTO simple_inbox", 1, true) then
      local recipient, id = params[1], params[2]
      if db.intents[key(recipient, id)] and db.rows[key(recipient, id)] then
        return nil, "UNIQUE constraint failed"
      end
      for _, row in ipairs(db.rows) do
        if row.recipient == recipient and row.message_id == id then
          return nil, "UNIQUE constraint failed"
        end
      end
      db.rows[#db.rows + 1] = { recipient = recipient, message_id = id,
        envelope = params[3], body = params[4], delivery = params[5],
        note = params[6] or "", is_read = 0, seq = #db.rows + 1 }
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
    if sql:find("SET status = 'failed'", 1, true) then
      local recipient, id = params[1], params[2]
      local intent = db.intents[key(recipient, id)]
      if intent and intent.status == "pending" then
        intent.status = "failed"
        return 1
      end
      return 0
    end
    if sql:find("UPDATE read_receipt_intents SET status", 1, true) then
      local status, recipient, id = params[1], params[2], params[3]
      local intent = db.intents[key(recipient, id)]
      if intent and intent.status == "pending" then
        intent.status = status
        return 1
      end
      return 0
    end
    if sql:find("receipt_id = CASE", 1, true) then
      local receipt_id, receipt_body, recipient, id = params[1], params[2], params[3], params[4]
      local intent = db.intents[key(recipient, id)]
      if intent and intent.status == "pending" then
        if intent.receipt_id == nil or intent.receipt_id == "" then intent.receipt_id = receipt_id end
        if intent.receipt_body == nil or intent.receipt_body == "" then intent.receipt_body = receipt_body end
        return 1
      end
      return 0
    end
    if sql:find("UPDATE receipt_attempt_seq", 1, true) then
      db.attempt_seq = (db.attempt_seq or 0) + 1
      return 1
    end
    if sql:find("SET attempt_seq", 1, true) then
      local recipient, id = params[1], params[2]
      local intent = db.intents[key(recipient, id)]
      if intent and intent.status == "pending" then
        intent.attempt_seq = db.attempt_seq
        return 1
      end
      return 0
    end
    if sql:find("UPDATE read_receipt_intents", 1, true) and sql:find("deferred_at", 1, true) then
      local recipient, id = params[1], params[2]
      local intent = db.intents[key(recipient, id)]
      if intent and intent.status == "pending" and intent.deferred_at == nil then
        intent.deferred_at = "2026-11-13T05:10:00Z"
        return 1
      end
      return 0
    end
    return 1
  end

  function db:query(sql, params)
    db.calls[#db.calls + 1] = { sql = sql, params = params }
    if db.fail and db.fail(sql, params) then return nil, "synthetic failure" end
    if sql:find("GROUP BY recipient", 1, true) then
      local state = {}
      for _, intent in pairs(db.intents) do
        if intent.status == "pending" then
          local item = state[intent.recipient]
            or { recipient = intent.recipient, live = false, seq = -1 }
          if intent.deferred_at == nil then
            item.live = true
          else
            local seq = intent.attempt_seq or -1
            if seq < item.seq then item.seq = seq end
          end
          state[intent.recipient] = item
        end
      end
      local out = {}
      for _, item in pairs(state) do out[#out + 1] = item end
      table.sort(out, function(a, b)
        if a.live ~= b.live then return a.live end
        if not a.live and a.seq ~= b.seq then return a.seq < b.seq end
        return a.recipient < b.recipient
      end)
      for index, item in ipairs(out) do out[index] = { recipient = item.recipient } end
      return out
    end
    if sql:find("FROM read_receipt_intents i", 1, true) then
      local recipient = params[1]
      local out = {}
      for _, intent in pairs(db.intents) do
        if intent.recipient == recipient and intent.status == "pending" then
          local envelope
          for _, row in ipairs(db.rows) do
            if row.recipient == recipient and row.message_id == intent.message_id then
              envelope = row.envelope
            end
          end
          out[#out + 1] = { recipient = intent.recipient, message_id = intent.message_id,
            read_at = intent.read_at, receipt_id = intent.receipt_id,
            receipt_body = intent.receipt_body, envelope = envelope,
            deferred = intent.deferred_at and 1 or 0, attempt_seq = intent.attempt_seq }
        end
      end
      table.sort(out, function(a, b)
        if a.deferred ~= b.deferred then return a.deferred < b.deferred end
        if (a.attempt_seq or -1) ~= (b.attempt_seq or -1) then
          return (a.attempt_seq or -1) < (b.attempt_seq or -1)
        end
        if a.read_at ~= b.read_at then return a.read_at < b.read_at end
        return a.message_id < b.message_id
      end)
      return out
    end
    if sql:find("SELECT receipt_id, receipt_body FROM read_receipt_intents", 1, true) then
      local recipient, id = params[1], params[2]
      local intent = db.intents[key(recipient, id)]
      if intent then return { { receipt_id = intent.receipt_id, receipt_body = intent.receipt_body } } end
      return {}
    end
    if sql:find("FROM read_receipt_intents", 1, true) then
      local recipient = params[1]
      local out = {}
      for _, intent in pairs(db.intents) do
        if intent.recipient == recipient and intent.status == "pending" then out[#out + 1] = intent end
      end
      table.sort(out, function(a, b) return a.message_id < b.message_id end)
      return out
    end
    if sql:find("SELECT message_id FROM simple_inbox", 1, true) then
      local recipient, id = params[1], params[2]
      for _, row in ipairs(db.rows) do
        if row.recipient == recipient and row.message_id == id then
          return { { message_id = id } }
        end
      end
      return {}
    end
    if sql:find("FROM simple_inbox", 1, true) then
      local recipient = params[1]
      local out = {}
      for _, row in ipairs(db.rows) do
        if row.recipient == recipient then
          out[#out + 1] = { message_id = row.message_id, envelope = row.envelope,
            body = row.body, delivery = row.delivery, note = row.note,
            is_read = row.is_read, seq = row.seq }
        end
      end
      table.sort(out, function(a, b) return a.seq < b.seq end)
      return out
    end
    return {}
  end

  function db:add(recipient, id, envelope, is_read)
    db.rows[#db.rows + 1] = { recipient = recipient, message_id = id, envelope = envelope,
      body = "", delivery = "{}", note = "", is_read = is_read or 0, seq = #db.rows + 1 }
  end

  function db:intent(recipient, id) return db.intents[key(recipient, id)] end

  function db:rows_for(recipient)
    local out = {}
    for _, row in ipairs(db.rows) do
      if row.recipient == recipient then out[#out + 1] = row end
    end
    return out
  end

  function db:receipts_for(recipient)
    local out = {}
    for _, row in ipairs(db:rows_for(recipient)) do
      if row.envelope:find('"receipt_of"', 1, true) then out[#out + 1] = row end
    end
    return out
  end

  return db
end

local root = os.tmpname()
os.remove(root)
assert(mkdir(root))
for _, dir in ipairs({ "inboxes", "read", "messages", "objects" }) do
  assert(mkdir(root .. "/" .. dir))
end

local counter = 0
remuda = {
  json = { decode = decode_envelope },
  mkdir = mkdir,
  _butler_new_ulid = function() counter = counter + 1; return string.format("%026d", counter) end,
  _butler_diagnostics = { record = function() end },
}
remuda.json.encode = function(value)
  if type(value) ~= "table" then return json_quote(value) end
  local parts = {}
  for key, item in pairs(value) do parts[#parts + 1] = json_quote(key) .. ":" .. json_quote(item) end
  return "{" .. table.concat(parts, ",") .. "}"
end
remuda.butler = { matrix = {
  utf8_prefix = function(text, limit) return text:sub(1, limit) end,
  shown_event_id = function(id) return id end,
  shell_quote = function(text) return text end,
} }

local db = fake_db()
local store = dofile("packages/butler/inbox_sqlite_simple.lua")
local bus = { agents = {}, inboxes = {}, messages = {}, objects = {}, mail_delivered = {} }
remuda._butler_mail_config = { bus = bus, root = root, json_quote = json_quote,
  simple = { db = db, store = store } }
dofile("packages/butler/mail.lua")
local mail = assert(remuda._butler_mail)
local notices = {}
local notice_seen = {}
local notice_attempts = 0
remuda._butler_read_receipts_config = { simple = { db = db, store = store }, mail = mail,
  json = remuda.json,
  notify = function(message, recipient)
    -- Model the real notice policy's per-message-ID dedupe.
    notice_attempts = notice_attempts + 1
    if notice_seen[message.id] then return end
    notice_seen[message.id] = true
    notices[#notices + 1] = { id = message.id, to = recipient.id,
      receipt_of = message.receipt_of }
  end }
dofile("packages/butler/read_receipts.lua")
local receipts = assert(remuda._butler_read_receipts)

local A = { host = "local", id = "aa", alias = "aa", session = "aa", kind = "agent", leader = "" }
local B = { host = "local", id = "bb", alias = "bb", session = "bb", kind = "agent", leader = "aa" }
local C = { host = "local", id = "cc", alias = "cc", session = "cc", kind = "agent", leader = "aa" }
local D = { host = "local", id = "dd", alias = "dd", session = "dd", kind = "agent", leader = "aa" }
local E = { host = "local", id = "ee", alias = "ee", session = "ee", kind = "agent", leader = "aa" }
local F = { host = "local", id = "ff", alias = "ff", session = "ff", kind = "agent", leader = "aa" }
local G = { host = "local", id = "gg", alias = "gg", session = "gg", kind = "agent", leader = "aa" }
local I = { host = "local", id = "ii", alias = "ii", session = "ii", kind = "agent", leader = "aa" }
local J = { host = "local", id = "jj", alias = "jj", session = "jj", kind = "agent", leader = "aa" }
local H = { host = "local", id = "hh", alias = "hh", session = "hh", kind = "agent", leader = "aa" }
local SCHEDULE = { host = "local", id = "", alias = "schedule", session = "schedule" }
local OUTSIDE = { host = "local", id = "", alias = "outside", session = "outside" }
local MATRIX = { host = "matrix", id = "", alias = "@human:example.org", session = "@human:example.org" }

local function restart()
  bus.mail_loaded, bus.mail_read, bus.mail_unreadable = {}, {}, {}
  bus.inboxes, bus.mail_delivered, bus.mail_resent = {}, {}, {}
  bus.messages, bus.objects = {}, {}
end

local function bhex(id) return component(id) end

-- The ULID is assigned when the intent is recorded; it is the durable identity
-- the delivery retry must reuse.
local function stored_receipt_id(reader, original)
  local intent = db:intent(bhex(reader), original)
  assert(intent, "no intent for " .. tostring(original))
  assert(type(intent.receipt_id) == "string" and intent.receipt_id ~= "",
    "intent has no stored receipt ULID")
  return intent.receipt_id
end

-- 1. A -> B: a read produces exactly one correlated local receipt at A.
local original = mail.queue(A, B, "task one body", "Task one")
assert(original, "initial message was not queued")
assert(mail.inbox("bb", { reader_id = "bb" }):find("task one body"), "B did not read the message")
assert(db:intent(bhex("bb"), original.id), "read did not create an intent")
local first = receipts.drain()
assert(first.delivered == 1, "first drain did not deliver one receipt")
local rid = stored_receipt_id("bb", original.id)
assert(db:intent(bhex("bb"), original.id).status == "delivered", "intent was not completed")
local receipt = bus.messages[rid]
assert(receipt, "receipt message is missing")
assert(receipt.receipt_of == original.id, "receipt_of does not correlate to the original")
assert(receipt.from.id == "bb" and receipt.from.alias == "bb", "receipt sender is not the reader")
assert(receipt.to[1].id == "aa", "receipt recipient is not the original sender")
assert(#db:receipts_for(bhex("aa")) == 1, "A does not have exactly one receipt")
assert(#notices == 1 and notices[1].receipt_of == original.id and notices[1].to == "aa",
  "newly accepted receipt did not notify the original sender once")

-- 2. A read of the receipt creates an intent, but the structured field stops
--    the loop: it is skipped with no message back to B.
assert(mail.inbox("aa", { reader_id = "aa" }):find("Read receipt"), "A did not see the receipt")
assert(db:intent(bhex("aa"), rid), "reading a receipt created no intent")
local loop = receipts.drain()
assert(loop.skipped == 1, "receipt intent was not skipped")
assert(db:intent(bhex("aa"), rid).status == "skipped", "receipt intent was not marked skipped")
assert(#db:rows_for(bhex("bb")) == 1, "receipt loop produced mail for B")
assert(#notices == 1, "skipped receipt notified")

-- 3. Receipt identity survives a process-level restart; a second drain does
--    not duplicate the receipt even though the intent is gone.
restart()
assert(mail.find_message(rid).receipt_of == original.id, "receipt_of did not survive reload")
local stable = receipts.drain()
assert(stable.delivered == 0 and stable.errors == 0, "restart drain changed outcomes")
assert(#db:receipts_for(bhex("aa")) == 1, "restart duplicated the receipt")
assert(#db:rows_for(bhex("bb")) == 1, "restart produced receipt mail for B")

-- 4. Duplicate read: no new intent, no new receipt.
restart()
assert(mail.inbox("bb", { reader_id = "bb" }) == "inbox empty", "duplicate read returned mail")
assert(receipts.drain().delivered == 0, "duplicate read delivered a receipt")
assert(#db:receipts_for(bhex("aa")) == 1, "duplicate read duplicated the receipt")

-- 5. Batch: two unread messages in one read produce two distinct receipts.
local batch_one = mail.queue(A, B, "batch one", "Batch one")
local batch_two = mail.queue(A, B, "batch two", "Batch two")
assert(batch_one and batch_two, "batch messages were not queued")
restart()
local batch_text = mail.inbox("bb", { reader_id = "bb" })
assert(batch_text:find("batch one", 1, true) and batch_text:find("batch two", 1, true), "batch read missed a message")
local batch = receipts.drain()
assert(batch.delivered == 2, "batch drain did not deliver two receipts")
local first_id, second_id = stored_receipt_id("bb", batch_one.id), stored_receipt_id("bb", batch_two.id)
assert(first_id ~= second_id, "batch receipts share an identity")
assert(db:intent(bhex("bb"), batch_one.id).status == "delivered"
  and db:intent(bhex("bb"), batch_two.id).status == "delivered", "batch intents were not completed")
assert(#db:receipts_for(bhex("aa")) == 3, "A does not have three distinct receipts")
assert(#notices == 3 and notices[2].receipt_of == batch_one.id and notices[3].receipt_of == batch_two.id,
  "batch notifications are missing or not distinct")

-- 6. Crash after local acceptance, before the completion mark: the mail is
--    durable, the intent is still pending, and the retry completes without a
--    duplicate.
local crash_message = mail.queue(A, C, "crash body", "Crash")
assert(crash_message, "crash-scenario message was not queued")
restart()
assert(mail.inbox("cc", { reader_id = "cc" }):find("crash body", 1, true), "C did not read")
db.fail = function(sql)
  return sql:find("UPDATE read_receipt_intents SET status", 1, true) ~= nil
end
local crashed = receipts.drain()
db.fail = nil
assert(crashed.errors == 1, "failed completion mark was not reported")
assert(db:intent(bhex("cc"), crash_message.id).status == "pending", "failed mark did not stay pending")
local crash_rid = stored_receipt_id("cc", crash_message.id)
assert(#crash_rid == 26 and crash_rid:match("^[0-9A-HJKMNP-TV-Z]+$"),
  "stored receipt identity is not a Butler ULID")
assert(#db:rows_for(bhex("aa")) == 4, "accepted receipt was lost")
assert(#notices == 4, "accepted receipt did not notify once")
local attempts_before_retry = notice_attempts
local retried = receipts.drain()
assert(retried.delivered == 1, "retry did not complete the pending intent")
assert(db:intent(bhex("cc"), crash_message.id).status == "delivered", "retry did not mark it delivered")
assert(#db:rows_for(bhex("aa")) == 4, "retry duplicated the accepted receipt")
assert(#notices == 4, "retry typed the receipt notice twice")
assert(notice_attempts == attempts_before_retry + 1,
  "accepted retry did not re-attempt the notice")
assert(#db:rows_for(bhex("cc")) == 1, "retry produced mail for the reader")

-- 6b. Crash after the body file was written, before the envelope and inbox
--     row: identical staged content is reused, never treated as a collision.
local staged_message = mail.queue(A, E, "staged body", "Staged")
assert(staged_message, "staged-scenario message was not queued")
restart()
assert(mail.inbox("ee", { reader_id = "ee" }):find("staged body", 1, true), "E did not read")
local staged_rid = stored_receipt_id("ee", staged_message.id)
local staged_body = "Read receipt: ee fetched message " .. staged_message.id .. " from the Butler inbox."
put(root .. "/objects/object-" .. staged_rid, staged_body)
local staged = receipts.drain()
assert(staged.delivered == 1, "partial-file crash did not recover")
assert(#db:rows_for(bhex("aa")) == 5, "partial-file recovery added or lost mail")
assert(bus.messages[staged_rid].receipt_of == staged_message.id, "staged receipt is not correlated")
assert(bus.objects["object-" .. staged_rid].content == staged_body, "staged body was not reused")
assert(#notices == 5, "partial-file recovery did not notify once")

-- 6c. Crash after the inbox row was accepted but before the notice: the retry
--     re-attempts the notice. The per-ID dedupe prevents a second notice when
--     the first one did land.
local recover_message = mail.queue(A, G, "recover body", "Recover")
assert(recover_message, "notice-recovery message was not queued")
restart()
assert(mail.inbox("gg", { reader_id = "gg" }):find("recover body", 1, true), "G did not read")
local normal_notify = remuda._butler_read_receipts_config.notify
remuda._butler_read_receipts_config.notify = function() error("simulated crash before notice") end
db.fail = function(sql)
  return sql:find("UPDATE read_receipt_intents SET status", 1, true) ~= nil
end
local before_notice = receipts.drain()
db.fail = nil
remuda._butler_read_receipts_config.notify = normal_notify
assert(before_notice.errors >= 1, "notice-crash scenario did not fail")
assert(db:intent(bhex("gg"), recover_message.id).status == "pending",
  "notice-crash scenario did not stay pending")
assert(#notices == 5, "notice-crash scenario notified before acceptance")
local recovered = receipts.drain()
assert(recovered.delivered == 1, "notice-crash retry did not complete")
assert(db:intent(bhex("gg"), recover_message.id).status == "delivered",
  "notice-crash retry did not mark delivered")
assert(#notices == 6, "notice-crash retry did not notify")
assert(#db:rows_for(bhex("aa")) == 6, "notice-crash retry duplicated mail")

-- 6d. The receipt body is fixed in the intent. A later envelope/alias change
--     between a body-only acceptance and the retry must reuse the stored body
--     instead of computing a different one and calling it a collision.
local fixed_message = mail.queue(A, H, "fixed body", "Fixed")
assert(fixed_message, "body-fix message was not queued")
restart()
assert(mail.inbox("hh", { reader_id = "hh" }):find("fixed body", 1, true), "H did not read")
db.fail = function(sql)
  return sql:find("UPDATE read_receipt_intents SET status", 1, true) ~= nil
end
local fixed_first = receipts.drain()
db.fail = nil
assert(fixed_first.errors >= 1, "body-fix first drain did not fail the mark")
local fixed_intent = db:intent(bhex("hh"), fixed_message.id)
assert(fixed_intent.receipt_body and fixed_intent.receipt_body:find("hh fetched", 1, true),
  "receipt body was not fixed in the intent")
for _, row in ipairs(db.rows) do
  if row.recipient == bhex("hh") and row.message_id == fixed_message.id then
    row.envelope = row.envelope:gsub('"alias":"hh"', '"alias":"renamed"')
  end
end
local fixed_retry = receipts.drain()
assert(fixed_retry.delivered == 1 and fixed_retry.errors == 0,
  "body-fix retry did not reuse the stored body")
assert(db:intent(bhex("hh"), fixed_message.id).status == "delivered",
  "body-fix retry did not complete")
assert(#db:rows_for(bhex("aa")) == 7, "body-fix retry duplicated mail")
assert(#notices == 7, "body-fix retry did not notify once")

-- 7. Collision: an unrelated message already at the deterministic ID is not
--    success and is not overwritten; the intent stays pending.
local collision_message = mail.queue(A, D, "collision body", "Collision")
assert(collision_message, "collision-scenario message was not queued")
restart()
assert(mail.inbox("dd", { reader_id = "dd" }):find("collision body", 1, true), "D did not read")
local collision_rid = stored_receipt_id("dd", collision_message.id)
local squatter = mail.queue_receipt(D, A, "not the receipt", "Unrelated", "some-other-message", collision_rid)
assert(squatter, "collision setup failed")
local before_collision = #db:rows_for(bhex("aa"))
local collision = receipts.drain()
assert(collision.errors == 1, "collision was not reported as an error")
assert(db:intent(bhex("dd"), collision_message.id).status == "failed", "collision was not terminally failed")
assert(#db:rows_for(bhex("aa")) == before_collision, "collision added mail")
local squatter_row
for _, row in ipairs(db:rows_for(bhex("aa"))) do
  if row.message_id == collision_rid then squatter_row = row end
end
assert(squatter_row and squatter_row.envelope:find('"subject":"Unrelated"', 1, true),
  "collision overwrote the existing message")
assert(#notices == 7, "collision notified a receipt")

-- 7b. Content conflict: the same stable identity, sender and recipient but a
--     different body is not the receipt and must not overwrite it.
local conflict_message = mail.queue(A, F, "conflict body", "Conflict")
assert(conflict_message, "content-conflict message was not queued")
restart()
assert(mail.inbox("ff", { reader_id = "ff" }):find("conflict body", 1, true), "F did not read")
local conflict_rid = stored_receipt_id("ff", conflict_message.id)
local wrong = mail.queue_receipt(F, A, "different content", "Read receipt",
  conflict_message.id, conflict_rid)
assert(wrong, "content-conflict setup failed")
local before_conflict = #db:rows_for(bhex("aa"))
local conflicted = receipts.drain()
assert(conflicted.errors > 0, "content conflict was not reported")
assert(db:intent(bhex("ff"), conflict_message.id).status == "failed",
  "content conflict was not terminally failed")
assert(#db:rows_for(bhex("aa")) == before_conflict, "content conflict added mail")
assert(#notices == 7, "content conflict notified")

-- 8. Exclusions: schedule, self, unaddressable and Matrix.
restart()
local schedule_message = mail.queue(SCHEDULE, B, "schedule body", "Schedule")
local self_message = mail.queue(B, B, "self body", "Self")
local outside_message = mail.queue(OUTSIDE, B, "outside body", "Outside")
local matrix_message = mail.queue(MATRIX, B, "matrix body", "Matrix",
  nil, nil, { sender = "@human:example.org", room_id = "!room", event_id = "$event" })
assert(schedule_message and self_message and outside_message and matrix_message, "exclusion setup failed")
assert(mail.inbox("bb", { reader_id = "bb" }):find("matrix body", 1, true), "B did not read the exclusions")
local excluded = receipts.drain()
assert(excluded.skipped == 3, "schedule/self/unaddressable were not skipped")
assert(excluded.deferred == 1, "Matrix was not deferred")
assert(db:intent(bhex("bb"), schedule_message.id).status == "skipped", "schedule intent not skipped")
assert(db:intent(bhex("bb"), self_message.id).status == "skipped", "self intent not skipped")
assert(db:intent(bhex("bb"), outside_message.id).status == "skipped", "unaddressable intent not skipped")
assert(db:intent(bhex("bb"), matrix_message.id).status == "pending", "Matrix intent was not preserved")
assert(db:intent(bhex("bb"), matrix_message.id).deferred_at ~= nil,
  "Matrix intent was not marked deferred for ordering")
assert(#db:rows_for(bhex("aa")) == 9, "exclusions produced receipts")
assert(#notices == 7, "exclusions notified")

-- 9. File-only fallback: no SQLite, no intents, no delivery.
restart()
remuda._butler_read_receipts_config.simple = nil
local unavailable = receipts.drain()
assert(unavailable.available == false, "file-only fallback claimed availability")
assert(#db:rows_for(bhex("aa")) == 9, "file-only fallback delivered a receipt")

-- 10. Fairness: 50 terminally failing pending intents must not block a later
--     normal receipt. Permanent failures are marked failed and do not consume
--     the delivery budget, so the normal item is delivered in the same drain.
remuda._butler_read_receipts_config.simple = { db = db, store = store }
local real_mail = mail
restart()
local many = {}
for index = 1, 50 do
  many[index] = assert(mail.queue(A, B, "failing body " .. index, "Failing " .. index))
end
assert(mail.inbox("bb", { reader_id = "bb" }):find("failing body 50", 1, true), "B did not read the failing batch")
local normal_message = assert(mail.queue(A, C, "normal after failures", "Normal after failures"))
assert(mail.inbox("cc", { reader_id = "cc" }):find("normal after failures", 1, true), "C did not read the normal message")
local rows_before = #db:rows_for(bhex("aa"))
remuda._butler_read_receipts_config.mail = { queue_receipt = function(from, to, text, subject, receipt_of, stable_id, created_at)
  if from and from.id == "bb" and to and to.id == "aa" then
    return nil, "synthetic permanent collision", nil, nil, "collision"
  end
  return real_mail.queue_receipt(from, to, text, subject, receipt_of, stable_id, created_at)
end }
local fair = receipts.drain()
remuda._butler_read_receipts_config.mail = real_mail
assert(fair.delivered == 1, "normal receipt after 50 failures was not delivered")
assert(fair.failed == 50 and fair.errors == 50, "permanent failures were not counted or failed")
for index = 1, 50 do
  assert(db:intent(bhex("bb"), many[index].id).status == "failed",
    "permanent failure " .. index .. " was not terminally failed")
end
assert(db:intent(bhex("cc"), normal_message.id).status == "delivered",
  "normal intent after failures was not delivered")
assert(#db:rows_for(bhex("aa")) == rows_before + 1, "fairness drain delivered the wrong number of receipts")
assert(#notices == 8, "fairness drain notified the wrong number of times")

-- 11. The reader identity comes from the canonical id, not the original
--     envelope's to alias (a forwarded mail names the actual reader).
remuda._butler_read_receipts_config.reader_address = function(id)
  if id == "aa" then return A elseif id == "bb" then return B elseif id == "cc" then return C end
  return nil
end
local forwarded = assert(mail.queue(A, B, "forward source", "Forward source"))
assert(forwarded, "forward source was not queued")
local forward_copy = assert(mail.forward(B, forwarded.id, C, "forward note", true))
assert(forward_copy, "forward copy was not delivered")
restart()
local fwd_text = mail.inbox("cc", { reader_id = "cc" })
assert(fwd_text:find("forward source", 1, true), "C did not read the forward")
local forward_drain = receipts.drain()
assert(forward_drain.delivered == 1, "forwarded-mail receipt was not delivered")
local forward_intent = db:intent(bhex("cc"), forwarded.id)
assert(forward_intent and forward_intent.status == "delivered", "forward intent was not delivered")
local forward_receipt = bus.messages[forward_intent.receipt_id]
assert(forward_receipt.from.id == "cc" and forward_receipt.from.alias == "cc",
  "forwarded-mail receipt named the envelope to alias instead of the reader")
assert(bus.objects["object-" .. forward_intent.receipt_id].content:find("cc fetched", 1, true),
  "forwarded-mail receipt body named the wrong reader")
remuda._butler_read_receipts_config.reader_address = nil

-- 12. Deferred rotation: more than one page of Matrix-deferred intents sits
--     ahead of a recovered deferred local intent. The first bounded drain
--     retries only the first page; the second must rotate to the recovered
--     item instead of selecting the same page forever.
restart()
for _, intent in pairs(db.intents) do
  if intent.status == "pending" then intent.status = "skipped" end
end
for index = 1, 50 do
  assert(mail.queue(MATRIX, I, "matrix rotation " .. index, "Matrix rotation " .. index,
    nil, nil, { sender = "@human:example.org", room_id = "!room",
      event_id = "$rotation-" .. index }), "rotation message was not queued")
end
assert(mail.inbox("ii", { reader_id = "ii" }):find("matrix rotation 50", 1, true),
  "I did not read the rotation batch")
local recovered_message = assert(mail.queue(A, G, "recovered local", "Recovered local"))
assert(mail.inbox("gg", { reader_id = "gg" }):find("recovered local", 1, true),
  "G did not read the recovered message")
local recovered_intent = assert(db:intent(bhex("gg"), recovered_message.id),
  "recovered intent was not recorded")
-- Simulate a row that an earlier transient failure had deferred.
recovered_intent.deferred_at = "2026-11-13T04:00:00Z"
local rows_before_rotation = #db:rows_for(bhex("aa"))
local first_page = receipts.drain()
assert(first_page.deferred == 50, "the first drain must retry one bounded page")
assert(recovered_intent.status == "pending",
  "a recovered item behind the first deferred page must not be skipped")
-- A daemon restart must not reset the rotation.
restart()
local second_page = receipts.drain()
assert(second_page.delivered == 1, "the second drain did not rotate to the recovered item")
assert(recovered_intent.status == "delivered",
  "the second drain must rotate to the recovered deferred item")
assert(#db:rows_for(bhex("aa")) == rows_before_rotation + 1,
  "the recovered item produced the wrong number of receipts")

-- 13. More than 100 deferred items: three bounded ticks must attempt all of
--     them, with no wall-clock tie able to pin a page.
restart()
local stress = {}
for index = 1, 120 do
  stress[index] = assert(mail.queue(MATRIX, J, "stress rotation " .. index,
    "Stress rotation " .. index, nil, nil, { sender = "@human:example.org",
      room_id = "!room", event_id = "$stress-" .. index }), "stress message was not queued")
end
assert(mail.inbox("jj", { reader_id = "jj" }):find("stress rotation 120", 1, true),
  "J did not read the stress batch")
for _ = 1, 3 do receipts.drain() end
for index = 1, 120 do
  local intent = db:intent(bhex("jj"), stress[index].id)
  assert(intent and intent.attempt_seq ~= nil,
    "deferred item " .. index .. " was starved after three ticks")
end

assert(run("rm -rf '" .. root .. "'"))
print("ok")
