-- Lua-side L3 relay tests. The HTTP callback is scripted at the stable
-- remuda.butler.matrix.request_json boundary; run under core so the relay's
-- persisted state uses the same remuda.json implementation as production.
assert(type(remuda) == "table" and type(remuda.json) == "table",
  "run this suite with a Remuda core that provides remuda.json")
remuda.butler = { matrix = {} }
remuda._relay_timers = {}
function remuda.schedule(spec)
  local timer = { spec = spec, cancelled = false }
  remuda._relay_timers[#remuda._relay_timers + 1] = timer
  return timer
end
function remuda.cancel(timer) if timer then timer.cancelled = true end end
local matrix = dofile("packages/butler/matrix_request.lua")
dofile("packages/butler/matrix_setup.lua")
dofile("packages/butler/matrix_cli.lua")
local setup_tests = dofile("tests/butler_matrix_setup.lua")
local relay_module = dofile("packages/butler/matrix_relay.lua")

local function fixture()
  local dir = os.tmpname()
  os.remove(dir)
  assert(os.execute("mkdir -p " .. string.format("%q", dir)))
  local path = dir .. "/config"
  local file = assert(io.open(path, "w"))
  file:write("https://matrix.invalid\n!room:example.org\n@bot:example.org\n",
    "@alice:example.org\nfalse\n30000\n")
  file:close()
  return dir, path
end

local function scripted_client()
  local client = { requests = {}, callbacks = {}, cancelled = {} }
  function client.request_json(args, callback)
    local index = #client.requests + 1
    client.requests[index] = args
    client.callbacks[index] = callback
    return { cancel = function() client.cancelled[index] = true end }
  end
  function client:complete(index, value)
    assert(self.callbacks[index], "missing request callback " .. tostring(index))
    local callback = self.callbacks[index]
    self.callbacks[index] = nil
    callback(value)
  end
  return client
end

local function tick_timers(count)
  for _ = 1, count or 1 do
    for _, timer in ipairs(remuda._relay_timers) do
      if not timer.cancelled then timer.spec.run() end
    end
  end
end

local function test_baseline_resume_filters_and_envelope()
  local dir, config_path = fixture()
  local client, delivered = scripted_client(), {}
  local relay = relay_module.new({
    config_path = config_path,
    matrix = client,
    deliver = function(event)
      delivered[#delivered + 1] = event
      return true
    end,
  })

  assert(relay:start())
  assert(#client.requests == 1)
  assert(client.requests[1].method == "GET")
  assert(client.requests[1].path == "/_matrix/client/v3/sync?timeout=0")
  assert(client.requests[1].timeout == 10)
  client:complete(1, { json = { next_batch = "s0" } })

  assert(#client.requests == 2)
  assert(client.requests[2].path == "/_matrix/client/v3/sync?since=s0&timeout=30000")
  client:complete(2, { json = {
    next_batch = "s1",
    rooms = { join = {
      ["!other:example.org"] = { timeline = { events = {
        { type = "m.room.message", event_id = "$other", sender = "@alice:example.org",
          content = { msgtype = "m.text", body = "wrong room" } },
      } } },
      ["!room:example.org"] = { timeline = { events = {
        { type = "m.room.message", event_id = "$self", sender = "@bot:example.org",
          content = { msgtype = "m.text", body = "self" } },
        { type = "m.room.message", event_id = "$bad-sender", sender = "@mallory:example.org",
          content = { msgtype = "m.text", body = "blocked" } },
        { type = "m.room.message", event_id = "$bad-type", sender = "@alice:example.org",
          content = { msgtype = "m.image", body = "blocked" } },
        { type = "m.room.message", event_id = "$notice", sender = "@alice:example.org",
          content = { msgtype = "m.notice", body = "notice" } },
        { type = "m.room.message", event_id = "$emote", sender = "@alice:example.org",
          content = { msgtype = "m.emote", body = "emote" } },
        { type = "m.room.message", event_id = "$fallback-ts", sender = "@alice:example.org",
          content = { msgtype = "m.notice", body = "timestamp fallback" } },
        { type = "m.room.message", event_id = "$event", sender = "@alice:example.org",
          origin_server_ts = 0,
          content = { msgtype = "m.text", body = "hello", url = "mxc://media/file",
            ["m.relates_to"] = { rel_type = "m.thread", event_id = "$root",
              ["m.in_reply_to"] = { event_id = "$parent" } } } },
      } } },
    } },
  } })
  assert(#delivered == 4, "only allowed msgtypes from the sender in this room should deliver")
  local event
  for _, candidate in ipairs(delivered) do
    if candidate.event_id == "$event" then event = candidate end
  end
  assert(event, "text event metadata was not delivered")
  assert(event.sender == "@alice:example.org")
  assert(event.room_id == "!room:example.org")
  assert(event.event_id == "$event")
  assert(event.body == "hello")
  assert(event.created_at == "1970-01-01T00:00:00Z")
  assert(event.thread_root == "$root")
  assert(event.in_reply_to == "$parent")
  assert(event.mxc == "mxc://media/file")
  assert(relay:state().since == "s1")

  client:complete(3, { json = { next_batch = "s2", rooms = { join = {
    ["!room:example.org"] = { timeline = { events = {
      { type = "m.room.message", event_id = "$event", sender = "@alice:example.org",
        content = { msgtype = "m.text", body = "duplicate" } },
    } } },
  } } } })
  assert(#delivered == 4, "processed event IDs must suppress duplicate events")
  local fallback_time
  for _, candidate in ipairs(delivered) do
    if candidate.event_id == "$fallback-ts" then fallback_time = candidate.created_at end
  end
  assert(fallback_time and fallback_time:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"),
    "missing or invalid event time must fall back to UTC")

  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_state_restart_corruption_and_processed_cap()
  local dir, config_path = fixture()
  local client = scripted_client()
  local state_path = config_path .. ".since"
  local ids = matrix.json_array({})
  for i = 1, 5003 do ids[i] = "event-" .. tostring(i) end
  local encoded = assert(matrix.encode_json({ since = "persisted", processed_event_ids = ids,
    messages_since = matrix.json_null, pending_events = remuda.json.object({}) }))
  local file = assert(io.open(state_path, "wb")); file:write(encoded); file:close()

  local relay = relay_module.new({ config_path = config_path, matrix = client, deliver = function() return true end })
  assert(#relay:state().processed_order == 5000)
  assert(relay:state().processed_order[1] == "event-4")
  relay:start()
  assert(client.requests[1].path == "/_matrix/client/v3/sync?since=persisted&timeout=30000",
    "restart must resume the stored cursor without running a baseline")
  relay:stop()

  local legacy_file = assert(io.open(state_path, "wb")); legacy_file:write('{"since":"legacy-cursor"}'); legacy_file:close()
  local legacy = relay_module.new({ config_path = config_path, matrix = client, deliver = function() return true end })
  assert(legacy:state().since == "legacy-cursor", "old cursor-only state must remain readable")
  legacy:start()
  assert(client.requests[2].path == "/_matrix/client/v3/sync?since=legacy-cursor&timeout=30000")
  legacy:stop()

  local bad = assert(io.open(state_path, "wb")); bad:write("{broken"); bad:close()
  local corrupted = relay_module.new({ config_path = config_path, matrix = client, deliver = function() return true end })
  assert(corrupted:state().since == nil and #corrupted:state().processed_order == 0,
    "malformed state should reset to a clean baseline")
  corrupted:start()
  assert(client.requests[3].path == "/_matrix/client/v3/sync?timeout=0")
  corrupted:stop()
  local wrong_types = assert(io.open(state_path, "wb")); wrong_types:write('{"processed_event_ids":5}'); wrong_types:close()
  local typed = relay_module.new({ config_path = config_path, matrix = client, deliver = function() return true end })
  assert(typed:state().since == nil and #typed:state().processed_order == 0,
    "wrongly typed state fields should reset to a clean baseline")
  typed:stop()
  os.remove(state_path)
  local backup = assert(io.open(state_path .. ".bak", "wb")); backup:write('{"since":"backup-cursor"}'); backup:close()
  local recovered = relay_module.new({ config_path = config_path, matrix = client, deliver = function() return true end })
  local recovered_file = io.open(state_path, "rb")
  assert(recovered:state().since == "backup-cursor" and recovered_file,
    "a crash-window backup should be restored before polling")
  recovered_file:close()
  recovered:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_pending_delivery_retries_safely_after_restart()
  local dir, config_path = fixture()
  local first_client, second_client = scripted_client(), scripted_client()
  local successes = 0
  local first = relay_module.new({ config_path = config_path, matrix = first_client, deliver = function()
    return nil -- simulate a mail-channel delivery that did not commit
  end })
  first:start()
  first_client:complete(1, { json = { next_batch = "s0" } })
  first_client:complete(2, { json = { next_batch = "s1", rooms = { join = {
    ["!room:example.org"] = { timeline = { events = {
      { type = "m.room.message", event_id = "$pending-restart", sender = "@alice:example.org",
        content = { msgtype = "m.text", body = "durable before cursor" } },
    } } },
  } } } })
  assert(first:state().pending["$pending-restart"], "pending envelope must persist before the cursor advances")
  first:stop()

  local restarted = relay_module.new({ config_path = config_path, matrix = second_client, deliver = function()
    successes = successes + 1
    return true
  end })
  restarted:start()
  assert(successes == 1, "restart must retry the pending envelope")
  assert(restarted:state().pending["$pending-restart"] == nil)
  assert(restarted:state().processed["$pending-restart"])
  assert(second_client.requests[1].path == "/_matrix/client/v3/sync?since=s1&timeout=30000")
  second_client:complete(1, { json = { next_batch = "s2", rooms = { join = {
    ["!room:example.org"] = { timeline = { events = {
      { type = "m.room.message", event_id = "$pending-restart", sender = "@alice:example.org",
        content = { msgtype = "m.text", body = "duplicate after restart" } },
    } } },
  } } } })
  assert(successes == 1, "acknowledged event must not be delivered a second time")
  restarted:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_ack_reconcile_and_utf8_body_cap()
  local dir, config_path = fixture()
  local client, delivered = scripted_client(), {}
  local state_path = config_path .. ".since"
  local pending = {
    ["$pending"] = { sender = "@alice:example.org", room_id = "!room:example.org",
      created_at = "time", body = "pending" },
    ["$drained"] = { sender = "@alice:example.org", room_id = "!room:example.org",
      created_at = "time", body = "drained" },
  }
  local encoded = assert(matrix.encode_json({ since = "s1", processed_event_ids = matrix.json_array({}),
    pending_events = pending }))
  local file = assert(io.open(state_path, "wb")); file:write(encoded); file:close()
  file = assert(io.open(config_path .. ".acks", "wb")); file:write("$pending\n"); file:close()
  file = assert(io.open(config_path .. ".acks.drain", "wb")); file:write("$drained\n"); file:close()
  local relay = relay_module.new({ config_path = config_path, matrix = client, deliver = function(e)
    delivered[#delivered + 1] = e
    return true
  end })
  relay:start()
  assert(relay:state().pending["$pending"] == nil, "acknowledged pending event must be removed")
  assert(relay:state().processed["$pending"], "acknowledged event must enter processed IDs")
  assert(relay:state().pending["$drained"] == nil and relay:state().processed["$drained"],
    "a stale drain file must reconcile before the new ack batch")
  assert(#delivered == 0, "ack must reconcile before pending delivery")
  relay:stop()

  local long = string.rep("a", 65534) .. "🙂"
  local body = relay_module.cap_body and relay_module.cap_body(long)
  if not body then
    local c = relay_module.new({ config_path = config_path, matrix = client, deliver = function(e)
      delivered[#delivered + 1] = e; return true
    end })
    c:start()
    local req = #client.requests
    client:complete(req, { json = { next_batch = "s1", rooms = { join = {
      ["!room:example.org"] = { timeline = { events = {
        { type = "m.room.message", event_id = "$large", sender = "@alice:example.org",
          content = { msgtype = "m.text", body = long } },
      } } },
    } } } })
    body = delivered[#delivered].body
    c:stop()
  end
  assert(#body <= 65536, "capped body may not exceed 64 KiB")
  assert(body:match("%[truncated %d+ bytes%]$"), "capped body includes an accurate truncation suffix")
  local prefix = body:match("^(.*)%[truncated")
  assert(prefix:byte(-1) ~= nil and prefix:byte(-1) < 0x80,
    "UTF-8 truncation must not end on a partial multibyte sequence")
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_messages_backfill_baseline_and_retry_backoff()
  local dir, config_path = fixture()
  local file = assert(io.open(config_path, "wb")); file:write(
    "https://matrix.invalid\n!room:example.org\n@bot:example.org\n@alice:example.org\nmessages\n30000\n"); file:close()
  local client, delivered = scripted_client(), {}
  local old = { type = "m.room.message", event_id = "$old", sender = "@alice:example.org",
    content = { msgtype = "m.text", body = "baseline duplicate must be suppressed" } }
  local relay = relay_module.new({ config_path = config_path, matrix = client, deliver = function(e)
    delivered[#delivered + 1] = e; return true
  end })
  relay:start()
  assert(client.requests[1].path == "/_matrix/client/v3/rooms/%21room%3Aexample.org/messages?dir=b&limit=1")
  client:complete(1, { json = { start = "start", ["end"] = "back", chunk = {
    old,
  } } })
  assert(relay:state().messages_since == "start")
  assert(relay:state().processed["$old"], "backfill baseline events must be suppressed")
  tick_timers(3)
  assert(client.requests[2].path == "/_matrix/client/v3/rooms/%21room%3Aexample.org/messages?from=start&dir=f&limit=100")
  client:complete(2, { json = { start = "start", ["end"] = "forward", chunk = {
    old,
    { type = "m.room.message", event_id = "$new", sender = "@alice:example.org",
      content = { msgtype = "m.text", body = "new" } },
  } } })
  assert(#delivered == 1 and delivered[1].event_id == "$new",
    "a baseline event repeated by forward pagination must stay suppressed")
  tick_timers(3)
  assert(client.requests[3].path:find("from=forward", 1, true), "forward cursor must advance")
  client:complete(3, { error = "offline" })
  assert(#remuda._relay_timers > 0, "transport errors schedule a retry")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_retry_backoff_grows_and_resets_after_recovery()
  local dir, config_path = fixture()
  local client = scripted_client()
  local relay = relay_module.new({ config_path = config_path, matrix = client, deliver = function() return true end })
  relay:start()
  for attempt = 1, 7 do
    client:complete(attempt, { error = "offline" })
    local delay = math.min(60, 2 ^ (attempt - 1))
    tick_timers(delay - 1)
    assert(#client.requests == attempt, "retry started before its backoff delay")
    tick_timers(1)
    assert(#client.requests == attempt + 1, "retry did not start after its backoff delay")
  end
  assert(#client.requests == 8, "the capped 60-second retry was not scheduled")
  client:complete(8, { json = { next_batch = "s0" } })
  assert(#client.requests == 9, "successful baseline immediately begins long polling")
  client:complete(9, { error = "offline again" })
  tick_timers(1)
  assert(#client.requests == 10, "success resets the next retry to one second")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_allowlist_refusal_is_logged_once()
  local dir, config_path = fixture()
  local calls, logs = 0, {}
  local client = { request_json = function(_, callback)
    calls = calls + 1
    callback({ error = "room is outside the configured Matrix allowlist" })
  end }
  local old_stderr = io.stderr
  io.stderr = { write = function(_, line) logs[#logs + 1] = line end }
  local relay = relay_module.new({ config_path = config_path, matrix = client, deliver = function() return true end })
  relay:start()
  tick_timers(1)
  io.stderr = old_stderr
  local refusals = 0
  for _, line in ipairs(logs) do
    if line:find("request refused by configured allowlist", 1, true) then refusals = refusals + 1 end
  end
  assert(calls == 2, "refusal retry fixture did not exercise a repeated request")
  assert(refusals == 1, "a persistent allowlist refusal must log once per relay lifetime")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end


-- A mod that redefines the public read_config/is_agent_mxid words must not
-- widen the sender allowlist or reclassify agents: the relay, write and mail
-- composites bind the L1 originals at load.
local function test_redefined_public_words_do_not_change_trust()
  remuda._butler_new_ulid = remuda._butler_new_ulid or function() return "01TESTULID" end
  dofile("packages/butler/matrix_write.lua")
  remuda._butler_mail_config = { bus = { inboxes = {}, messages = {}, objects = {} } }
  dofile("packages/butler/mail.lua")
  local saved_read, saved_agent = matrix.read_config, matrix.is_agent_mxid
  matrix.read_config = function(path)
    local cfg, err = saved_read(path)
    if cfg then cfg.allowed_senders["@mallory:example.org"] = true end
    return cfg, err
  end
  matrix.is_agent_mxid = function() return false end

  local dir, config_path = fixture()
  local client, delivered = scripted_client(), {}
  local relay = relay_module.new({ config_path = config_path, matrix = client,
    deliver = function(event) delivered[#delivered + 1] = event return true end })
  assert(relay:start())
  client:complete(1, { json = { next_batch = "s0" } })
  client:complete(2, { json = { next_batch = "s1", rooms = { join = {
    ["!room:example.org"] = { timeline = { events = {
      { type = "m.room.message", event_id = "$mallory", sender = "@mallory:example.org",
        content = { msgtype = "m.text", body = "let me in" } },
    } } },
  } } } })
  assert(#delivered == 0, "a redefined read_config widened the sender allowlist")
  local quarantined = relay:quarantine_list()
  assert(quarantined[1] and quarantined[1].reason == "sender_not_allowlisted",
    "attacker event was not quarantined as sender_not_allowlisted")
  relay:stop()
  for _, suffix in ipairs({ "", ".since", ".acks" }) do os.remove(config_path .. suffix) end
  assert(os.remove(dir))

  local result
  matrix.send({ room = "!room:example.org", text = "hi @agent-x:example.org" },
    function(value) result = value end)
  assert(type(result) == "table" and result.error == "Butler-to-Butler sends are disabled",
    "a redefined is_agent_mxid reclassified an agent mention in matrix.send")
  remuda._butler_mail_config.bus.messages.m1 = { id = "m1",
    matrix = { sender = "@agent-x:example.org", room_id = "!room:example.org", event_id = "$e" } }
  local sent
  assert(remuda._butler_mail.reply({ id = "op", alias = "op" }, "m1", "hi", true,
    function(message) sent = message return true end))
  assert(sent.matrix_route.from_agent == true,
    "a redefined is_agent_mxid reclassified an agent sender in mail reply")
  matrix.read_config, matrix.is_agent_mxid = saved_read, saved_agent
end


-- Owner room invites (notes/invite-design.md). The config file is the one
-- room boundary: an accepted invite appends `room=ID how=...` to it.
local HOME, ALL, NEW = "!room:example.org", "!all:example.org", "!new:example.org"
local OWNER, STRANGER = "@alice:example.org", "@mallory:example.org"

local function invite_fixture(senders, extra)
  local dir, path = fixture()
  local file = assert(io.open(path, "w"))
  file:write("http://matrix.invalid\n", HOME, "\n@bot:example.org\n", senders or OWNER,
    "\nfalse\n30000\nall_room=", ALL, "\n", extra or "")
  file:close()
  return dir, path
end

local function read_text(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("a")
  file:close()
  return text
end

local function room_line(path, room)
  for line in read_text(path):gmatch("[^\n]+") do
    if line:match("^room=(%S+)") == room then return line end
  end
end

local function encoded(room)
  return (room:gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Scripted client that also records the L2 send/reply words, so the tests do
-- not dictate which word the relay uses for its notices.
local function invite_client()
  local client = scripted_client()
  local function record(opts, callback)
    return client.request_json({ method = "PUT", room = opts.room, text = opts.text,
      path = "/_matrix/client/v3/rooms/" .. encoded(opts.room) .. "/send/m.room.message/w" }, callback)
  end
  client.send, client.reply = record, record
  function client:sync(value)
    for index = #self.requests, 1, -1 do
      if self.requests[index].path:find("/sync", 1, true) and self.callbacks[index] then
        return self:complete(index, value)
      end
    end
    error("no pending /sync request")
  end
  -- Answer every pending non-sync request; join_result overrides the join reply.
  function client:pump(join_result)
    local progressed = true
    while progressed do
      progressed = false
      for index, args in ipairs(self.requests) do
        if self.callbacks[index] and not args.path:find("/sync", 1, true) then
          progressed = true
          if args.path:find("/join", 1, true) then
            self:complete(index, join_result or { json = { room_id = NEW } })
          else
            self:complete(index, { json = { event_id = "$sent" .. index } })
          end
        end
      end
    end
  end
  function client:joins(room)
    local n = 0
    for _, args in ipairs(self.requests) do
      if args.method == "POST" and args.path == "/_matrix/client/v3/rooms/" .. encoded(room) .. "/join" then
        n = n + 1
      end
    end
    return n
  end
  function client:messages(room, text)
    local n = 0
    for _, args in ipairs(self.requests) do
      local body = args.text or args.body or ""
      if args.method == "PUT" and (args.room == room or args.path:find("/rooms/" .. encoded(room) .. "/", 1, true))
        and body:find(text, 1, true) then n = n + 1 end
    end
    return n
  end
  return client
end

local function invite(room, inviter)
  return { [room] = { invite_state = { events = {
    { type = "m.room.name", sender = inviter, state_key = "", content = { name = "x" } },
    { type = "m.room.member", sender = inviter, state_key = "@bot:example.org",
      content = { membership = "invite" } },
  } } } }
end

local function started_relay(path, client, delivered)
  local relay = relay_module.new({ config_path = path, matrix = client,
    deliver = function(event) delivered[#delivered + 1] = event return true end })
  assert(relay:start())
  client:sync({ json = { next_batch = "s0" } })
  return relay
end

local function owner_message(room, id)
  return { [room] = { timeline = { events = {
    { type = "m.room.message", event_id = id, sender = OWNER,
      content = { msgtype = "m.text", body = "hello from " .. room } },
  } } } }
end

local function delivered_ids(delivered, id)
  for _, event in ipairs(delivered) do if event.event_id == id then return true end end
  return false
end

local function test_owner_invite_joins_writes_line_and_notices_once()
  local dir, path = invite_fixture()
  local client, delivered = invite_client(), {}
  local relay = started_relay(path, client, delivered)
  client:sync({ json = { next_batch = "s1", rooms = { invite = invite(NEW, OWNER) } } })
  client:pump()
  assert(client:joins(NEW) == 1, "an owner invite must POST join exactly once")
  local line = room_line(path, NEW)
  assert(line and line:find("how=owner-invite", 1, true),
    "an owner invite must append 'room=" .. NEW .. " how=owner-invite' to the config")
  local notice = "Joined; I read messages here from the owner."
  assert(client:messages(NEW, notice) == 1, "the joined room must get the notice once")
  client:sync({ json = { next_batch = "s2", rooms = { invite = invite(NEW, OWNER) } } })
  client:pump()
  assert(client:joins(NEW) == 1 and client:messages(NEW, notice) == 1,
    "a repeated invite for a joined room must not join or notice again")
  client:sync({ json = { next_batch = "s3", rooms = { join = owner_message(NEW, "$in-new") } } })
  assert(delivered_ids(delivered, "$in-new"),
    "a later owner message in the joined room must become mail (HOME rules)")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_stranger_invite_is_quarantined_with_home_next()
  local dir, path = invite_fixture()
  local before = read_text(path)
  local client, delivered = invite_client(), {}
  local relay = started_relay(path, client, delivered)
  client:sync({ json = { next_batch = "s1", rooms = { invite = invite(NEW, STRANGER) } } })
  client:pump()
  assert(client:joins(NEW) == 0, "a stranger invite must never be joined")
  assert(read_text(path) == before, "a stranger invite must not change the config")
  local item
  for _, q in ipairs(relay:quarantine_list()) do
    if q.reason == "invite_not_allowlisted" then item = q end
  end
  assert(item, "a stranger invite must be quarantined as invite_not_allowlisted")
  assert(item.sender == STRANGER and item.room_id == NEW,
    "the quarantine record must name the inviter and the invited room")
  local line = "Invite to " .. NEW .. " from " .. STRANGER
    .. " was not accepted. Next: remuda butler matrix join '" .. NEW .. "'"
  assert(client:messages(HOME, line) == 1, "HOME must get one line with the Next command")
  client:sync({ json = { next_batch = "s2", rooms = { invite = invite(NEW, STRANGER) } } })
  client:pump()
  assert(client:joins(NEW) == 0 and client:messages(HOME, line) == 1,
    "a repeated stranger invite must not join or repeat the HOME line")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_agent_invite_is_not_joined()
  local agents = { "@agent-x:example.org", "@butler-x:example.org" }
  local dir, path = invite_fixture(OWNER .. "," .. table.concat(agents, ","))
  local before = read_text(path)
  local client, delivered = invite_client(), {}
  local relay = started_relay(path, client, delivered)
  for i, agent in ipairs(agents) do
    local room = "!agent" .. i .. ":example.org"
    client:sync({ json = { next_batch = "s" .. i, rooms = { invite = invite(room, agent) } } })
    client:pump()
    assert(client:joins(room) == 0, "an agent-MXID invite must not be joined: " .. agent)
  end
  assert(read_text(path) == before, "an agent invite must not change the config")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function http_fake(status, calls)
  return { request = function(spec)
    calls[#calls + 1] = spec
    spec.callback({ status = status, headers = {}, body = status == 200 and "{}" or
      '{"errcode":"M_FORBIDDEN","error":"no"}' })
    return { cancel = function() end }
  end }
end

local function with_operator_config(path, status, run)
  dofile("packages/butler/matrix_request.lua") -- fresh rate-limit bucket
  remuda._butler_new_ulid = remuda._butler_new_ulid or function() return "01TESTULID" end
  dofile("packages/butler/matrix_write.lua")
  local token = path .. ".token"
  local file = assert(io.open(token, "w")); file:write("access-token"); file:close()
  local saved_http, saved_conf = remuda.http, remuda._butler_matrix_config
  local calls = {}
  remuda.http = http_fake(status, calls)
  remuda._butler_matrix_config = { token_path = token, config_path = path }
  remuda._butler_matrix_paths = remuda._butler_matrix_config
  local ok, err = pcall(run, calls)
  remuda.http, remuda._butler_matrix_config, remuda._butler_matrix_paths = saved_http, saved_conf, nil
  if not ok then error(err, 0) end
end

local function test_join_failure_rolls_back_room_line()
  local dir, path = invite_fixture()
  local before = read_text(path)
  local client, delivered = invite_client(), {}
  local relay = started_relay(path, client, delivered)
  client:sync({ json = { next_batch = "s1", rooms = { invite = invite(NEW, OWNER) } } })
  client:pump({ error = "M_FORBIDDEN" })
  assert(client:joins(NEW) == 1, "the owner invite must attempt the join")
  assert(read_text(path) == before, "a failed relay join must remove the room line again")
  assert(client:messages(NEW, "Joined;") == 0, "a failed join must not post the Joined notice")
  relay:stop()

  with_operator_config(path, 403, function(calls)
    local result
    matrix.join({ room = NEW }, function(value) result = value end)
    assert(#calls == 1 and calls[1].method == "POST" and calls[1].url:find("/join", 1, true),
      "matrix join must POST join for a new room (the room line allows it)")
    assert(result and result.error, "a failed operator join must report the error")
    assert(read_text(path) == before, "a failed operator join must remove the room line again")
  end)
  with_operator_config(path, 200, function()
    local result
    matrix.join({ room = NEW }, function(value) result = value end)
    assert(result and not result.error, "operator join failed: " .. tostring(result and result.error))
    local line = room_line(path, NEW)
    assert(line and line:find("how=operator", 1, true), "matrix join must append how=operator")
  end)
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_joined_room_survives_restart()
  local dir, path = invite_fixture(nil, "room=" .. NEW .. " how=owner-invite\n")
  local client, delivered = invite_client(), {}
  local relay = started_relay(path, client, delivered)
  client:sync({ json = { next_batch = "s1", rooms = { join = owner_message(NEW, "$after-restart") } } })
  assert(delivered_ids(delivered, "$after-restart"),
    "a relay started on a config with the room line must listen in that room")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_running_relay_picks_up_operator_join_from_config()
  local dir, path = invite_fixture()
  local client, delivered = invite_client(), {}
  local relay = started_relay(path, client, delivered)
  assert(matrix.config_add_room(path, NEW, "operator"), "could not add operator room config line")
  client:sync({ json = { next_batch = "s1", rooms = { join = owner_message(NEW, "$operator-joined") } } })
  assert(delivered_ids(delivered, "$operator-joined"),
    "a running relay must listen in a room added to config without restarting")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_leave_removes_room_home_and_all_refused()
  local dir, path = invite_fixture(nil, "room=" .. NEW .. " how=operator\n")
  with_operator_config(path, 200, function(calls)
    for _, room in ipairs({ HOME, ALL }) do
      local before, result = read_text(path), nil
      matrix.leave({ room = room }, function(value) result = value end)
      assert(result and result.error and result.error:find("can't be removed", 1, true),
        "leaving HOME/ALL must be refused: " .. room)
      assert(#calls == 0 and read_text(path) == before, "a refused leave must not call or edit")
    end
    local result
    matrix.leave({ room = NEW }, function(value) result = value end)
    assert(result and not result.error, "leave of a joined room failed: " .. tostring(result and result.error))
    assert(#calls == 1 and calls[1].url:find("/rooms/" .. encoded(NEW) .. "/leave", 1, true),
      "leave must POST leave for the joined room")
    assert(room_line(path, NEW) == nil, "leave must remove the room line")
    assert(read_text(path):find("all_room=" .. ALL, 1, true), "leave must keep the other config lines")
  end)
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_leave_unconfigured_room_is_refused()
  local dir, path = invite_fixture()
  with_operator_config(path, 200, function(calls)
    local result
    matrix.leave({ room = NEW }, function(value) result = value end)
    assert(result and result.error == NEW .. " is not a configured Matrix room.",
      "leaving an unconfigured room must explain that it is not configured")
    assert(#calls == 0, "leaving an unconfigured room must not make an HTTP request")
  end)
  os.execute("rm -rf " .. string.format("%q", dir))
end

local function test_unconfigured_room_request_is_refused()
  local dir, path = invite_fixture(nil, "room=" .. NEW .. " how=operator\n")
  with_operator_config(path, 200, function(calls)
    local other = "!other:example.org"
    local results = {}
    local collect = function(value) results[#results + 1] = value end
    matrix.request_json({ method = "GET",
      path = "/_matrix/client/v3/rooms/" .. encoded(other) .. "/state" }, collect)
    matrix.request_json({ method = "GET", path = "/_matrix/client/v3/account/whoami", room = other }, collect)
    matrix.same_room(other, "$event", collect)
    assert(#results == 3 and #calls == 0, "unconfigured-room requests must be refused before HTTP")
    for _, r in ipairs(results) do
      assert(r.error and r.error:find("outside the configured Matrix allowlist", 1, true),
        "unconfigured-room refusal changed: " .. tostring(r.error))
    end
    local joined
    matrix.request_json({ method = "GET",
      path = "/_matrix/client/v3/rooms/" .. encoded(NEW) .. "/state", room = NEW },
      function(value) joined = value end)
    assert(joined and not joined.error and #calls == 1,
      "a room= line must admit that room to request_json: " .. tostring(joined and joined.error))
  end)
  os.execute("rm -rf " .. string.format("%q", dir))
end

test_baseline_resume_filters_and_envelope()
test_state_restart_corruption_and_processed_cap()
test_pending_delivery_retries_safely_after_restart()
test_ack_reconcile_and_utf8_body_cap()
test_messages_backfill_baseline_and_retry_backoff()
test_retry_backoff_grows_and_resets_after_recovery()
test_allowlist_refusal_is_logged_once()
setup_tests(matrix)
test_redefined_public_words_do_not_change_trust()
print("ok: Matrix relay resume, exactly-once, filters, state, acks, caps, fallback, and backoff")

-- Invite tests run last and report every failure before failing the suite.
local invite_failures = {}
for _, case in ipairs({
  { "test_owner_invite_joins_writes_line_and_notices_once", test_owner_invite_joins_writes_line_and_notices_once },
  { "test_stranger_invite_is_quarantined_with_home_next", test_stranger_invite_is_quarantined_with_home_next },
  { "test_agent_invite_is_not_joined", test_agent_invite_is_not_joined },
  { "test_join_failure_rolls_back_room_line", test_join_failure_rolls_back_room_line },
  { "test_joined_room_survives_restart", test_joined_room_survives_restart },
  { "test_running_relay_picks_up_operator_join_from_config", test_running_relay_picks_up_operator_join_from_config },
  { "test_leave_removes_room_home_and_all_refused", test_leave_removes_room_home_and_all_refused },
  { "test_leave_unconfigured_room_is_refused", test_leave_unconfigured_room_is_refused },
  { "test_unconfigured_room_request_is_refused", test_unconfigured_room_request_is_refused },
}) do
  local ok, err = pcall(case[2])
  if not ok then invite_failures[#invite_failures + 1] = case[1] .. ": " .. tostring(err) end
end
assert(#invite_failures == 0, "invite tests failed:\n" .. table.concat(invite_failures, "\n"))
print("ok: Matrix owner invites, room lines, join/leave, and the one room allowlist")
