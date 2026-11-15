-- S1 end-to-end characterization: one eligible Matrix event through the real
-- relay, real SQLite inbox, notification policy and read state, across a
-- restart and a replay. The substituted layer is the transport and its clock:
-- tests/support/fake_http.lua replaces remuda.http, remuda.schedule and
-- remuda.cancel, and pins the request clock, so relay retry/timer cadence runs
-- on the harness tick. This records what the current code does; it enables no
-- shadow wire, no cursor authority and no exactly-once claim.
local phase = assert(remuda._qa_phase, "remuda._qa_phase is required")
local EVENT_ID, BODY = "$e2e1", "hello from the end-to-end harness"
local SENDER, ROOM = "@alice:example.org", "!room:example.org"
local SYNC = "https://matrix.invalid/_matrix/client/v3/sync"
local DATA = assert(os.getenv("XDG_DATA_HOME"), "XDG_DATA_HOME is required")
local qa = {}

local function event()
  return { type = "m.room.message", event_id = EVENT_ID, sender = SENDER,
    origin_server_ts = os.time() * 1000,
    content = { msgtype = "m.text", body = BODY } }
end

local function batch(next_batch, with_event)
  local response = { next_batch = next_batch }
  if with_event then
    response.rooms = { join = { [ROOM] = { timeline = { events = { event() } } } } }
  end
  return { status = 200, body = remuda.json.encode(response) }
end

local function relay_state()
  local relay = remuda.butler and remuda.butler.matrix and remuda.butler.matrix.relay
  return relay and relay.instance and relay.instance:state() or nil
end

local function root_id()
  local agent = remuda._butler_bus and remuda._butler_bus.agents
    and remuda._butler_bus.agents.butler
  return agent and agent.id or nil
end

local function hex(value)
  return (value:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function rows(root)
  local simple = remuda._butler_simple_inbox
  assert(simple and simple.db, "the SQLite inbox is not active")
  return assert(simple.db:query(
    "SELECT message_id, is_read FROM simple_inbox WHERE recipient = ?",
    { hex(root) }))
end

local function store(name, value)
  local file = assert(io.open(DATA .. "/qa-" .. name, "wb"))
  assert(file:write(value))
  assert(file:close())
end

local function recall(name)
  local file = io.open(DATA .. "/qa-" .. name, "rb")
  if not file then return nil end
  local value = file:read("*a")
  file:close()
  return value
end

local function drive(replay)
  -- fake_http replaces remuda.schedule, so this real ticker is created first.
  remuda.schedule({ every = 1, name = "qa-matrix-inbox-e2e", run = function()
    if not (remuda.http and remuda.http.tick) then return end
    local ok, err = pcall(remuda.http.tick)
    if not ok then remuda._qa_tick_error = tostring(err) return end
    -- The stimulus itself: a completed response body that carried the event
    -- into the product request path. Without this, an eventless replay would
    -- pass by doing nothing.
    for _, entry in ipairs(remuda.http.pending or {}) do
      local body = entry.result and entry.result.body
      if entry.completed and not entry.qa_event and type(body) == "string"
          and body:find(EVENT_ID, 1, true) then
        entry.qa_event = true
        remuda._qa_event_served = (remuda._qa_event_served or 0) + 1
      end
    end
    local route, state = remuda.http.response_prefixes[1], relay_state()
    if not route or not state then return end
    if state.since == "s4" then remuda._qa_replay_batch = true end
    if state.processed and state.processed[EVENT_ID] then
      route.result = batch("s9")
    elseif state.since == nil then
      route.result = batch("s0")
    else
      route.result = batch("s1", true)
    end
  end })
  remuda._qa_tick_error = nil
  remuda._qa_replay_batch = false
  remuda._qa_event_served = 0
  dofile("tests/support/fake_http.lua")
  remuda.http.response_prefixes[1] = { method = "GET", prefix = SYNC,
    result = replay and batch("s4", true) or batch("s0") }
  remuda._butler_argv = { "sh", "-c", "sleep 60" }
  local ok, err = pcall(remuda.exec, "butler")
  assert(ok, "butler did not load: " .. tostring(err))
end

if phase == "drive" or phase == "replay" then
  drive(phase == "replay")
  return "relay started"
end

assert(phase == "check" or phase == "replay-check", "unknown phase " .. tostring(phase))
-- A tick failure would otherwise look like "nothing happened".
assert(remuda._qa_tick_error == nil, "harness tick error: "
  .. tostring(remuda._qa_tick_error))
local state = assert(relay_state(), "the relay is not running")
local root = assert(root_id(), "the root agent identity is missing")
assert(state.processed and state.processed[EVENT_ID],
  "the relay did not record the event as processed")
local inbox = assert(remuda._butler_mail and remuda._butler_mail.inbox)
local unread = assert(remuda._butler_mail.unread(root))

if phase == "check" then
  assert(state.since and state.since ~= "s0", "the relay cursor did not advance")
  assert(unread == 1, "expected exactly one unread message, got " .. tostring(unread))
  local ids = remuda._butler_bus.inboxes[root] or {}
  assert(#ids == 1, "expected exactly one inbox membership, got " .. tostring(#ids))
  local message = assert(remuda._butler_bus.messages[ids[1]],
    "the inbox message is missing")
  local object = assert(io.open(DATA .. "/remuda/butler/mail/objects/"
    .. tostring(message.body and message.body.object_id), "rb"),
    "the message body object is missing")
  local stored_body = object:read("*a")
  object:close()
  assert(stored_body == BODY, "body mismatch: " .. tostring(stored_body))
  assert(message.matrix and message.matrix.event_id == EVENT_ID,
    "event identity mismatch")
  assert(message.matrix.room_id == ROOM, "room identity mismatch")
  assert(message.subject == "Matrix message from " .. SENDER,
    "subject mismatch: " .. tostring(message.subject))
  local notice = remuda._butler_bus.notices and remuda._butler_bus.notices.butler
  assert(notice and notice.message_ids and notice.message_ids[ids[1]],
    "the notification policy did not queue a notice for the mail id")
  assert(notice.text:find(ids[1], 1, true), "the queued notice lacks the mail id")
  local delivered = 0
  local diagnostics = remuda._butler_diagnostics
  for _, row in ipairs(diagnostics and diagnostics.snapshot({ subsystem = "matrix" }).events or {}) do
    if row.outcome == "delivered" then delivered = delivered + 1 end
  end
  assert(delivered == 1, "expected one delivery, got " .. tostring(delivered))
  assert(remuda._qa_event_served == 1, "expected one event-bearing response, got "
    .. tostring(remuda._qa_event_served))
  local stored = rows(root)
  assert(#stored == 1, "expected one SQLite row, got " .. tostring(#stored))
  assert(stored[1].message_id == ids[1], "SQLite mail id mismatch")
  assert(stored[1].is_read == 0, "the new message is already read")
  -- Read through the real inbox path and observe durable read state.
  local rendered = inbox(root)
  assert(rendered:find(BODY, 1, true), "the inbox render lacks the body")
  assert(remuda._butler_mail.unread(root) == 0, "read did not clear unread")
  assert(rows(root)[1].is_read == 1, "SQLite read state was not written")
  store("root", root)
  store("mail", ids[1])
  return "check ok"
end

-- After restart and replay: same identity, same membership, no resurrection.
assert(recall("root") == root, "the root identity changed across restart")
local mail_id = assert(recall("mail"), "the stored mail id is missing")
assert(unread == 0, "the replay resurrected unread state: " .. tostring(unread))
assert(inbox(root):find("inbox empty", 1, true),
  "the replay returned the read message to the unread inbox")
local stored = rows(root)
assert(#stored == 1 and stored[1].message_id == mail_id and stored[1].is_read == 1,
  "the replay changed the SQLite membership or read state")
local found = assert(remuda._butler_mail.find_message(mail_id),
  "the message did not survive the restart")
assert(found.matrix and found.matrix.event_id == EVENT_ID
  and found.matrix.room_id == ROOM, "the message identity changed across restart")
local object = assert(io.open(DATA .. "/remuda/butler/mail/objects/"
  .. tostring(found.body and found.body.object_id), "rb"),
  "the body object did not survive the restart")
local stored_body = object:read("*a")
object:close()
assert(stored_body == BODY, "the body changed across restart")
-- The replay runs in a fresh process, so any notice here would be new. A
-- tolerance of "count == 1" would hide exactly the duplicate under test.
assert(remuda._butler_bus.notices == nil or remuda._butler_bus.notices.butler == nil,
  "the replay queued a notice")
local delivered = 0
local diagnostics = remuda._butler_diagnostics
for _, row in ipairs(diagnostics and diagnostics.snapshot({ subsystem = "matrix" }).events or {}) do
  if row.outcome == "delivered" then delivered = delivered + 1 end
end
assert(delivered == 0, "the replay delivered the event again")
assert(remuda._qa_replay_batch == true,
  "the replay batch was not observed as accepted by the relay")
assert((remuda._qa_event_served or 0) >= 1,
  "the replay response did not carry the event")
assert((remuda._butler_bus.inboxes[root] or {})[1] == nil,
  "the replay returned the message to the unread inbox")
local since_requests = 0
for _, spec in ipairs(remuda.http.calls) do
  if spec.url:find("since=", 1, true) then since_requests = since_requests + 1 end
end
assert(since_requests >= 1, "no post-restart sync request was answered")
assert(state.since == "s9", "the replay cursor did not advance: " .. tostring(state.since))
return "replay check ok"
