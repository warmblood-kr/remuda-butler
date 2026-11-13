-- L3 Matrix read-receipt tests. The relay, outbox and thread reply shape are
-- the production modules; only the HTTP boundary (request_json), Butler mail
-- delivery and the SQLite store are scripted. No live daemon or homeserver.
dofile("tests/lib/isolated_test.lua")(remuda)
assert(type(remuda) == "table" and type(remuda.json) == "table",
  "run this suite with a Remuda core that provides remuda.json")
remuda.butler = { matrix = {} }
remuda._butler_new_ulid = remuda._butler_new_ulid or function() return "01TESTULID" end
remuda._relay_timers = {}
function remuda.schedule(spec)
  local timer = { spec = spec, cancelled = false }
  remuda._relay_timers[#remuda._relay_timers + 1] = timer
  return timer
end
function remuda.cancel(timer) if timer then timer.cancelled = true end end

local matrix = dofile("packages/butler/matrix_request.lua")
local package_exec = remuda.exec
remuda.exec = function() end
local matrix_module_ok, matrix_module_error = pcall(dofile, "packages/butler/matrix.lua")
remuda.exec = package_exec
assert(matrix_module_ok, matrix_module_error)
dofile("packages/butler/system.lua")
dofile("packages/butler/matrix_setup.lua")
dofile("packages/butler/matrix_read.lua")
dofile("packages/butler/matrix_cli.lua")
dofile("packages/butler/approval.lua")
dofile("packages/butler/typed_lines.lua")
dofile("packages/butler/approve_text.lua")
dofile("packages/butler/status_command.lua")
dofile("packages/butler/guard_policy.lua")
dofile("packages/butler/guard_grants.lua")
dofile("packages/butler/guard_approval.lua")
dofile("packages/butler/matrix_delivery_policy.lua")
dofile("packages/butler/matrix_mentions.lua")
dofile("packages/butler/matrix_write.lua")
local relay_module = dofile("packages/butler/matrix_relay.lua")

local ROOM, OWNER, SELF = "!room:example.org", "@alice:example.org", "@bot:example.org"
local RX_ALLY = "@agent-ally:example.org"

local function fixture(extra)
  local dir = os.tmpname()
  os.remove(dir)
  assert(os.execute("mkdir -p " .. string.format("%q", dir)))
  local path = dir .. "/config"
  local file = assert(io.open(path, "w"))
  file:write("https://matrix.invalid\n", ROOM, "\n", SELF, "\n", OWNER, "\nfalse\n30000\n", extra or "")
  file:close()
  return dir, path
end

local function cleanup(dir, path)
  for _, suffix in ipairs({ "", ".since", ".since.bak", ".acks", ".acks.drain", ".token" }) do
    os.remove(path .. suffix)
  end
  assert(os.execute("rm -rf " .. string.format("%q", dir)))
end

local function scripted_client()
  local client = { requests = {}, callbacks = {} }
  function client.request_json(args, callback)
    local index = #client.requests + 1
    client.requests[index] = args
    client.callbacks[index] = callback
    return { cancel = function() end }
  end
  function client:complete(index, value)
    local callback = assert(self.callbacks[index], "missing request callback " .. tostring(index))
    self.callbacks[index] = nil
    callback(value)
  end
  function client:sync(value)
    for index = #self.requests, 1, -1 do
      if tostring(self.requests[index].path):find("/sync", 1, true) and self.callbacks[index] then
        return self:complete(index, value)
      end
    end
    error("no pending /sync request")
  end
  return client
end

local function event(id, sender, body, extra)
  local content = { msgtype = "m.text", body = body }
  for key, value in pairs(extra or {}) do content[key] = value end
  return { type = "m.room.message", event_id = id, sender = sender,
    origin_server_ts = os.time() * 1000, content = content }
end

remuda._mq_now = 1000000
remuda._butler_matrix_request_clock = function() return remuda._mq_now end
local function tick_timers(count)
  for _ = 1, count or 1 do
    remuda._mq_now = remuda._mq_now + 250
    for _, timer in ipairs(remuda._relay_timers) do
      if not timer.cancelled then timer.spec.run() end
    end
  end
end

local function hex(value)
  return (value:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end

local READER = "01READER" .. string.rep("0", 18)
local db, intents, seq = {}, {}, 0
local store = {}
function store.pending_recipients()
  local seen, out = {}, {}
  for _, intent in ipairs(intents) do
    if intent.status == "pending" and not seen[intent.recipient] then
      seen[intent.recipient] = true
      out[#out + 1] = { recipient = intent.recipient }
    end
  end
  return out
end
function store.pending_intent_details(_, recipient)
  local out = {}
  for _, intent in ipairs(intents) do
    if intent.recipient == recipient and intent.status == "pending" then out[#out + 1] = intent end
  end
  return out
end
-- Mirrors the real store: the local query omits the Matrix projection, so a
-- Matrix drain that picks it up loses durable queued/uncertain evidence.
function store.pending_local_intent_details(_, recipient)
  local out = {}
  for _, intent in ipairs(intents) do
    if intent.recipient == recipient and intent.status == "pending" then
      out[#out + 1] = { recipient = intent.recipient, message_id = intent.message_id,
        read_at = intent.read_at, receipt_id = intent.receipt_id,
        receipt_body = intent.receipt_body, envelope = intent.envelope }
    end
  end
  return out
end
function store.mark_intent_status(_, recipient, message_id, status)
  for _, intent in ipairs(intents) do
    if intent.recipient == recipient and intent.message_id == message_id and intent.status == "pending" then
      intent.status = status
      return 1
    end
  end
  return 0
end
function store.claim_receipt(_, recipient, message_id, candidate_id, candidate_body)
  for _, intent in ipairs(intents) do
    if intent.recipient == recipient and intent.message_id == message_id then
      intent.receipt_id = intent.receipt_id or candidate_id
      intent.receipt_body = intent.receipt_body or candidate_body
      return intent.receipt_id, intent.receipt_body
    end
  end
end
function store.record_matrix_state(_, recipient, message_id, state, txn_id, event_id, err)
  if store.fail_state then return nil, "synthetic state write failure" end
  for _, intent in ipairs(intents) do
    if intent.recipient == recipient and intent.message_id == message_id then
      intent.matrix_state = state
      intent.matrix_txn_id = txn_id or intent.matrix_txn_id
      intent.matrix_event_id = event_id or intent.matrix_event_id
      intent.matrix_error = err
    end
  end
  return 1
end
function store.record_intent_failure(_, recipient, message_id, permanent)
  for _, intent in ipairs(intents) do
    if intent.recipient == recipient and intent.message_id == message_id then
      if permanent then intent.status = "failed" else intent.deferred = true end
    end
  end
  return 1
end

remuda._butler_read_receipts_config = {
  simple = { db = {}, store = store },
  json = remuda.json,
  reader_address = function(id)
    if id ~= READER then return nil end
    return { host = "local", id = id, alias = "butler", session = "butler",
      kind = "codex", leader = "" }
  end,
  new_ulid = function()
    seq = seq + 1
    return "01FIXED" .. string.rep("0", 18) .. string.format("%d", seq)
  end,
  matrix = {
    available = function() return matrix.relay and matrix.relay.instance ~= nil end,
    status = function(reply_id) return matrix.read_receipt_status(reply_id) end,
    route = function(mail_id) return matrix.read_receipt_route(mail_id) end,
    mail_reply = function(opts) return matrix.mail_reply(opts) end,
  },
}
local receipts = dofile("packages/butler/read_receipts.lua")

local function envelope_for(delivered, mail_id, allowlisted)
  local sender = delivered.sender
  return matrix.encode_json({
    id = mail_id,
    from = { host = "matrix", id = "", alias = sender, session = sender,
      kind = delivered.from_agent and "matrix-agent" or "matrix", leader = "" },
    to = { { host = "local", id = READER, alias = "butler", session = "butler",
      kind = "codex", leader = "" } },
    subject = "Matrix message from " .. sender,
    created_at = delivered.created_at or "2026-11-13T00:00:00Z",
    content_type = "text/plain; charset=utf-8",
    body = { object_id = "object-" .. mail_id },
    matrix = { sender = sender, room_id = delivered.room_id, event_id = delivered.event_id,
      thread_root = delivered.thread_root, in_reply_to = delivered.in_reply_to,
      room_kind = delivered.room_kind, from_agent = delivered.from_agent,
      allowlisted_human = allowlisted,
      trusted = delivered.trusted ~= false },
  })
end

local function add_intent(mail_id, envelope)
  intents[#intents + 1] = { recipient = hex(READER), message_id = mail_id,
    read_at = "2026-11-13T00:00:00Z", status = "pending", envelope = envelope }
  return intents[#intents]
end

local dir, path = fixture()
local function json_quote(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end
local mail_bus = { messages = {}, objects = {}, inboxes = {} }
remuda._butler_mail_config = { bus = mail_bus, root = dir .. "/mail", json_quote = json_quote }
dofile("packages/butler/mail.lua")
local mail = assert(remuda._butler_mail)
local client, delivered, sends = scripted_client(), {}, {}
local api = {
  request_json = client.request_json,
  -- The relay's send seam. Recording instead of performing keeps the HTTP
  -- shape deterministic; the real matrix.reply relation/content is checked
  -- separately below.
  reply = function(opts, callback)
    sends[#sends + 1] = { opts = opts, callback = callback }
    return { cancel = function() end }
  end,
}
matrix.request_json = client.request_json
local relay = relay_module.new({ config_path = path, matrix = api,
  deliver = function(item)
    delivered[#delivered + 1] = item
    return { id = "M" .. tostring(#delivered) }
  end })
matrix.relay.instance = relay
assert(relay:start())
client:sync({ json = { next_batch = "s0" } })
tick_timers(3)

-- 1. An allowlisted human event is mail; reading it produces exactly one
--    threaded reply whose durable identity is the intent's receipt ULID.
client:sync({ json = { next_batch = "s1", rooms = { join = { [ROOM] = { timeline = { events = {
  event("$in-1", OWNER, "please read this") } } } } } } })
assert(#delivered == 1, "the allowlisted human event must be delivered as mail")
local first = delivered[1]
assert(first.trusted == true and first.from_agent == false, "owner event must be trusted human mail")
local first_intent = add_intent("M1", envelope_for(first, "M1", true))
local first_drain = receipts.drain_matrix()
assert(first_drain.queued == 1, "the Matrix receipt must be queued: " .. tostring(first_drain.queued))
assert(#sends == 1, "exactly one relay send after the first drain")
local send = sends[1]
assert(send.opts.event_id == "$in-1",
  "the receipt must target the original event")
assert(relay:state().reply_outbox[first_intent.receipt_id].source_mail_id == "M1",
  "the outbox item must keep the original mail identity")
assert(send.opts.txn_id == "butler_" .. first_intent.receipt_id,
  "the txn must derive from the receipt ULID")
assert(send.opts.from_outbox == true, "outbox sends must mark their origin")
assert(send.opts.content_extra and send.opts.content_extra["io.butler.receipt_of"] == "M1"
  and send.opts.content_extra["io.butler.receipt"] == true,
  "the structured loop guard must reach the relay outbox")
assert(type(send.opts.text) == "string"
  and send.opts.text:find("Read receipt: butler fetched message M1", 1, true) ~= nil,
  "the receipt body must name the canonical reader: " .. tostring(send.opts.text))
send.callback({ event_id = "$receipt-1", event_ids = { "$receipt-1" } })

-- 2. A later drain observes the durable result and never re-sends.
local second_drain = receipts.drain_matrix()
assert(second_drain.delivered == 1, "the accepted receipt must converge to delivered")
assert(first_intent.status == "delivered", "the intent must be marked delivered")
assert(first_intent.matrix_state == "delivered"
  and first_intent.matrix_event_id == "$receipt-1", "the relay result must be projected")
assert(#sends == 1, "a delivered receipt must not be sent again")

-- 1b. The real mail writer copies the relay flags; after a reload and route
--     removal, the durable envelope still proves the allowlisted-human route.
local function matrix_fields(item)
  return { sender = item.sender, room_id = item.room_id, event_id = item.event_id,
    thread_root = item.thread_root, in_reply_to = item.in_reply_to,
    room_kind = item.room_kind, context_mail_id = item.context_mail_id,
    from_agent = item.from_agent,
    allowlisted_human = item.trusted == true and item.from_agent == false,
    trusted = item.trusted ~= false }
end
local stored = assert(mail.queue(
  { host = "matrix", id = "", alias = first.sender, session = first.sender,
    kind = "matrix", leader = "" },
  { host = "local", id = READER, alias = "butler", session = "butler",
    kind = "codex", leader = "" },
  "saved inbound", "Matrix message from " .. first.sender, nil, nil, matrix_fields(first)))
local envelope_file = assert(io.open(dir .. "/mail/messages/" .. stored.id .. ".json", "rb"))
local envelope_text = envelope_file:read("*a")
envelope_file:close()
assert(envelope_text:find('"from_agent":false', 1, true)
  and envelope_text:find('"allowlisted_human":true', 1, true),
  "the real envelope did not copy the relay flags")
mail_bus.messages, mail_bus.objects = {}, {}
local reloaded = assert(mail.find_message(stored.id), "the saved envelope did not reload")
assert(reloaded.matrix and reloaded.matrix.allowlisted_human == true
  and reloaded.matrix.from_agent == false,
  "the reloaded envelope lost the relay flags")
relay:state().routes[stored.id] = nil
local fallback_intent = add_intent(stored.id, envelope_text)
assert(receipts.drain_matrix().queued == 1, "the trimmed-route fallback did not queue")
local fallback_send = sends[#sends]
assert(fallback_send.opts.event_id == first.event_id, "the fallback used the wrong event")
assert(fallback_send.opts.content_extra["io.butler.receipt_of"] == stored.id,
  "the fallback used the wrong source mail")
fallback_send.callback({ event_id = "$receipt-fallback", event_ids = { "$receipt-fallback" } })
assert(receipts.drain_matrix().delivered == 1, "the fallback receipt did not converge")
assert(fallback_intent.status == "delivered", "the fallback intent was not delivered")

-- 3. A receipt intent from a non-allowlisted route is skipped, not sent.
local stranger = add_intent("M-STRANGER", matrix.encode_json({
  id = "M-STRANGER",
  from = { host = "matrix", id = "", alias = "@mallory:example.org",
    session = "@mallory:example.org", kind = "matrix", leader = "" },
  to = { { host = "local", id = READER, alias = "butler", session = "butler",
    kind = "codex", leader = "" } },
  subject = "Matrix message", created_at = "2026-11-13T00:00:00Z",
  content_type = "text/plain; charset=utf-8", body = { object_id = "object-M-STRANGER" },
  matrix = { sender = "@mallory:example.org", room_id = ROOM, event_id = "$stranger",
    from_agent = false, allowlisted_human = false, trusted = false },
}))
local skipped = receipts.drain_matrix()
assert(skipped.skipped == 1, "a non-allowlisted sender must be skipped")
assert(stranger.status == "skipped", "the skipped intent must be durable")
assert(#sends == 2, "a non-allowlisted sender must never get a receipt")

-- 4. Uncertain outcomes are surfaced durably and never retried blindly.
client:sync({ json = { next_batch = "s2", rooms = { join = { [ROOM] = { timeline = { events = {
  event("$in-2", OWNER, "second message") } } } } } } })
local ids = {}
for _, d in ipairs(delivered) do ids[#ids + 1] = d.event_id end
assert(#delivered == 2, "the second owner event must be delivered: " .. table.concat(ids, ","))
local second_intent = add_intent("M2", envelope_for(delivered[2], "M2", true))
assert(receipts.drain_matrix().queued == 1, "the second receipt must be queued")
assert(#sends == 3, "one send for the second receipt")
local second_rid = second_intent.receipt_id
relay:state().reply_outbox[second_rid].status = "uncertain"
relay:state().reply_outbox[second_rid].last_error = "previous dispatch did not record an outcome"
local uncertain = receipts.drain_matrix()
assert(uncertain.uncertain == 1, "an uncertain outbox item must be surfaced")
assert(second_intent.status == "pending" and second_intent.matrix_state == "uncertain",
  "an uncertain dispatch must stay pending and visible")
assert(#sends == 3, "an uncertain receipt must not be re-sent")

-- 4b. Durable terminal/queued evidence wins over a missing relay record, and a
--     failed status/state write never causes a send.
local function crafted(mail_id, state, receipt_id)
  local intent = add_intent(mail_id, envelope_for(delivered[1], mail_id, true))
  intent.receipt_id = receipt_id
  intent.matrix_state = state
  return intent
end
local queued_intent = crafted("M-QUEUED", "queued", "01QUEUED" .. string.rep("0", 18))
local queued_counts = receipts.drain_matrix()
assert(queued_counts.uncertain >= 1 and queued_intent.matrix_state == "uncertain",
  "a queued intent whose relay evidence is gone must become uncertain, not resend")
assert(#sends == 3, "a queued intent with lost evidence must not be sent")
local delivered_intent = crafted("M-DELIVERED", "delivered", "01DELIVERED" .. string.rep("0", 15))
assert(receipts.drain_matrix().delivered == 1, "durable delivered evidence must converge")
assert(delivered_intent.status == "delivered", "the durable delivered intent was not marked")
local failed_intent = crafted("M-FAILED", "failed", "01FAILED" .. string.rep("0", 18))
assert(receipts.drain_matrix().failed == 1, "durable failed evidence must stay terminal")
assert(failed_intent.status == "failed", "the durable failed intent was not marked")
assert(#sends == 3, "durable terminal evidence must not send")

local real_status = remuda._butler_read_receipts_config.matrix.status
remuda._butler_read_receipts_config.matrix.status = function() return nil, "status unavailable" end
local query_intent = crafted("M-QUERYFAIL", nil, "01QUERY" .. string.rep("0", 19))
local query_counts = receipts.drain_matrix()
assert(query_counts.errors >= 1 and query_counts.queued == 0,
  "a relay status query failure must be reported and must not send")
assert(query_intent.status == "pending" and query_intent.matrix_state == nil,
  "a status query failure must leave the intent pending without a send")
assert(#sends == 3, "a status query failure must not send")
remuda._butler_read_receipts_config.matrix.status = real_status

store.fail_state = true
local write_intent = crafted("M-WRITEFAIL", nil, "01WRITE" .. string.rep("0", 19))
local write_counts = receipts.drain_matrix()
assert(write_counts.errors >= 1 and write_counts.queued == 0,
  "a projection write failure must be reported and must not send")
assert(write_intent.status == "pending" and write_intent.matrix_state == nil,
  "a projection write failure must leave the intent pending")
assert(#sends == 3, "a projection write failure must not send")
store.fail_state = nil

-- A thrown dispatch is not a clean pre-send refusal: it may have queued or
-- sent, so it becomes uncertain and is never retried.
local real_mail_reply = remuda._butler_read_receipts_config.matrix.mail_reply
remuda._butler_read_receipts_config.matrix.mail_reply = function()
  error("synthetic dispatch crash")
end
local exception_intent = crafted("M-EXCEPTION", nil, "01EXCEPTION" .. string.rep("0", 15))
assert(receipts.drain_matrix().uncertain >= 1, "a thrown dispatch must be surfaced")
assert(exception_intent.matrix_state == "uncertain" and exception_intent.status == "pending",
  "a thrown dispatch must stay uncertain and pending")
assert(#sends == 3, "a thrown dispatch must not send")
remuda._butler_read_receipts_config.matrix.mail_reply = real_mail_reply
assert(receipts.drain_matrix().uncertain >= 1, "the uncertain state must survive the retry")
assert(#sends == 3, "an uncertain exception must never be retried")

-- A throw after the relay accepted the dispatch is the dangerous case: the
-- outbox item exists and the send may have happened. It must still become
-- uncertain and must never be dispatched again.
local accepted_reply = remuda._butler_read_receipts_config.matrix.mail_reply
local post_intent = crafted("M-POSTTHROW", nil, "01POSTTHROW" .. string.rep("0", 15))
remuda._butler_read_receipts_config.matrix.mail_reply = function(opts)
  local ok, err = accepted_reply(opts)
  assert(ok, "the post-acceptance fixture could not queue: " .. tostring(err))
  error("synthetic crash after acceptance")
end
local sends_before_post = #sends
local post_counts = receipts.drain_matrix()
assert(post_counts.uncertain >= 1, "a post-acceptance throw must be surfaced")
assert(post_intent.matrix_state == "uncertain" and post_intent.status == "pending",
  "a post-acceptance throw must stay uncertain and pending")
assert(#sends == sends_before_post + 1,
  "the accepted dispatch must have reached the relay exactly once")
assert(relay:state().reply_outbox[post_intent.receipt_id],
  "the accepted outbox item must survive the throw")
remuda._butler_read_receipts_config.matrix.mail_reply = accepted_reply
assert(receipts.drain_matrix().uncertain >= 1,
  "the post-acceptance uncertain state must survive the retry")
assert(#sends == sends_before_post + 1,
  "a post-acceptance throw must never be dispatched again")

-- 5. Agent receipt echoes never become mail or new receipts. Body text alone is
--    not a filter: a human mail that says "Read receipt:" is ordinary mail.
client:sync({ json = { next_batch = "s3", rooms = { join = { [ROOM] = { timeline = { events = {
  event("$echo-1", RX_ALLY, "Read receipt: butler fetched message M1",
    { ["io.butler.receipt_of"] = "M1", ["io.butler.receipt"] = true }),
  event("$human-prefix", OWNER, "Read receipt: this is just my text"),
} } } } } } })
assert(#delivered == 3, "only the human mail with the receipt prefix is delivered")
assert(delivered[3].event_id == "$human-prefix", "the human prefix message is normal mail")

-- 6. Wildcarding / machine guard: a machine reply on a non-allowlisted route is
--    refused even if an operator-style caller asks for it.
relay:state().routes["M-MALLORY"] = { room_id = ROOM, event_id = "$mallory",
  from_agent = false, allowlisted_human = false, created_at = "2026-11-13T00:00:00Z" }
local queued, guard_error = relay:queue_mail_reply({ mail_id = "M-MALLORY",
  reply_mail_id = "GUARD1", text = "should not send", machine = true })
assert(queued == nil and tostring(guard_error):find("non%-allowlisted") ~= nil,
  "machine replies must fail closed on a non-allowlisted route: " .. tostring(guard_error))
assert(#sends == 4, "the refused machine reply must not reach /send")

-- 7. Unknown structured fields are refused before any HTTP request is made.
local extra_error
matrix.send({ room = ROOM, text = "structured probe",
  content_extra = { ["not.butler.field"] = "x" } }, function(result) extra_error = result.error end)
assert(type(extra_error) == "string" and extra_error:find("invalid content_extra", 1, true) ~= nil,
  "content_extra must accept only the io.butler namespace: " .. tostring(extra_error))
assert(#sends == 4, "an invalid content_extra must not reach /send")

-- 7b. A reply identity may not be reused for different mail, text or txn.
local collided = assert(relay:queue_mail_reply({ mail_id = "M1", reply_mail_id = "COLL1",
  text = "collision one", txn_id = "COLL1_T" }))
assert(collided, "the collision fixture reply was not queued")
local function refuses(opts)
  local ok, err = relay:queue_mail_reply(opts)
  return ok == nil and type(err) == "string" and err:find("already used by another mail", 1, true) ~= nil
end
assert(refuses({ mail_id = "M1", reply_mail_id = "COLL1", text = "collision two", txn_id = "COLL1_T" }),
  "a different text under an existing reply id must be refused")
assert(refuses({ mail_id = "M2", reply_mail_id = "COLL1", text = "collision one", txn_id = "COLL1_T" }),
  "a different source under an existing reply id must be refused")
assert(refuses({ mail_id = "M1", reply_mail_id = "COLL1", text = "collision one", txn_id = "OTHER_T" }),
  "a different txn under an existing reply id must be refused")
assert(refuses({ mail_id = "M2", reply_mail_id = first_intent.receipt_id,
  text = "collision three", txn_id = "COLL3_T" }),
  "an accepted reply id must not be reused for another mail")
assert(relay:state().reply_outbox["COLL1"].text == "collision one",
  "a refused collision must not overwrite the queued reply")

-- 8. The real matrix.reply composes the thread relation, passes the durable
--    txn through, and merges the structured loop guard into the content.
dofile("packages/butler/matrix_request.lua")
dofile("packages/butler/matrix_write.lua")
local token = path .. ".token"
local token_file = assert(io.open(token, "w"))
token_file:write("access-token")
token_file:close()
local saved_http, saved_config = remuda.http, remuda._butler_matrix_config
local http_calls = {}
remuda.http = { request = function(spec)
  http_calls[#http_calls + 1] = spec
  if tostring(spec.url):find("/context/", 1, true) then
    spec.callback({ status = 200, body = '{"event":{"room_id":"' .. ROOM .. '"}}' })
  else
    spec.callback({ status = 200, body = '{"event_id":"$receipt-real"}' })
  end
  return { cancel = function() end }
end }
remuda._butler_matrix_config = { token_path = token, config_path = path }
remuda._butler_matrix_paths = remuda._butler_matrix_config
local reply_result
matrix.reply({ room = ROOM, event_id = "$in-1", text = "real receipt", from_outbox = true,
  txn_id = "butler_REAL", content_extra = { ["io.butler.receipt_of"] = "M1" } },
  function(value) reply_result = value end)
for _ = 1, 8 do if reply_result then break end tick_timers(1) end
assert(type(reply_result) == "table" and reply_result.event_ids
  and reply_result.event_ids[1] == "$receipt-real",
  "the real reply must complete through the HTTP seam: calls=" .. tostring(#http_calls)
    .. " first=" .. tostring(http_calls[1] and http_calls[1].method)
    .. " " .. tostring(http_calls[1] and http_calls[1].url)
    .. " result=" .. tostring(reply_result))
local put
for _, spec in ipairs(http_calls) do
  if spec.method == "PUT" then put = spec end
end
assert(put, "the real reply must issue one PUT")
assert(tostring(put.url):find("butler_REAL_1", 1, true) ~= nil, "the durable txn must reach the URL")
local real_content = matrix.decode_json(put.body)
assert(real_content["m.relates_to"] and real_content["m.relates_to"].rel_type == "m.thread"
  and real_content["m.relates_to"].event_id == "$in-1"
  and real_content["m.relates_to"]["m.in_reply_to"].event_id == "$in-1",
  "the receipt must be a threaded reply to the original event")
assert(real_content["io.butler.receipt_of"] == "M1",
  "the structured loop guard must be in the outbound content")
remuda.http, remuda._butler_matrix_config, remuda._butler_matrix_paths = saved_http, saved_config, nil
os.remove(token)

-- 7c. A real relay reconstruction with its state file gone must not resend a
--     durably queued receipt.
local restart_intent = crafted("M-RESTART", nil, "01RESTART" .. string.rep("0", 16))
assert(receipts.drain_matrix().queued >= 1, "the restart fixture receipt was not queued")
local restart_sends_before = #sends
local restart_rid = restart_intent.receipt_id
assert(relay:state().reply_outbox[restart_rid], "the restart fixture outbox is missing")
local stable_txn = relay:state().reply_outbox[restart_rid].txn_id
assert(stable_txn == "butler_" .. restart_rid, "the outbox txn must be the receipt identity")

-- A relay reconstructed with its state intact sees the queued item and must
-- not dispatch it again; the durable txn is what a homeserver retry dedupes.
relay:stop()
local client3, sends3 = scripted_client(), {}
local api3 = { request_json = client3.request_json,
  reply = function(opts, callback)
    sends3[#sends3 + 1] = { opts = opts, callback = callback }
    return { cancel = function() end }
  end }
matrix.request_json = client3.request_json
local relay3 = relay_module.new({ config_path = path, matrix = api3,
  deliver = function() return { id = "M-RECONSTRUCTED" } end })
matrix.relay.instance = relay3
assert(relay3:start())
client3:sync({ json = { next_batch = "reconstruct" } })
local reconstruct_counts = receipts.drain_matrix()
assert(reconstruct_counts.queued + reconstruct_counts.uncertain >= 1,
  "a reconstructed relay must report the durable outbox state")
assert(#sends3 == 0, "a reconstructed relay with intact state must not resend")
assert(relay3:state().reply_outbox[restart_rid].txn_id == stable_txn,
  "the stable txn must survive reconstruction")
relay3:stop()

os.remove(path .. ".since")
os.remove(path .. ".since.bak")
local client2, sends2 = scripted_client(), {}
local api2 = { request_json = client2.request_json,
  reply = function(opts, callback)
    sends2[#sends2 + 1] = { opts = opts, callback = callback }
    return { cancel = function() end }
  end }
matrix.request_json = client2.request_json
local relay2 = relay_module.new({ config_path = path, matrix = api2,
  deliver = function() return { id = "M-RESTARTED" } end })
matrix.relay.instance = relay2
assert(relay2:start())
client2:sync({ json = { next_batch = "restart" } })
local restart_counts = receipts.drain_matrix()
assert(restart_counts.uncertain >= 1 and restart_intent.matrix_state == "uncertain",
  "a queued receipt with the relay state gone must become uncertain")
-- The item accepted before a throw has no relay evidence after this state
-- loss either; its durable uncertain state must still block a second send.
assert(post_intent.status == "pending" and post_intent.matrix_state == "uncertain",
  "a post-acceptance throw must survive relay state loss as uncertain")
assert(#sends2 == 0, "a restarted relay must not resend a queued receipt")
assert(#sends == restart_sends_before, "the old relay must not send after the restart")
relay2:stop()
relay:stop()
matrix.relay.instance = nil
cleanup(dir, path)
print("ok")
