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
  local relay = relay_module.new({ config_path = config_path, matrix = client, deliver = function(e)
    delivered[#delivered + 1] = e; return true
  end })
  relay:start()
  assert(client.requests[1].path == "/_matrix/client/v3/rooms/%21room%3Aexample.org/messages?dir=b&limit=1")
  client:complete(1, { json = { start = "start", ["end"] = "back", chunk = {
    { event_id = "$old" },
  } } })
  assert(relay:state().messages_since == "start")
  assert(relay:state().processed["$old"], "backfill baseline events must be suppressed")
  tick_timers(3)
  assert(client.requests[2].path == "/_matrix/client/v3/rooms/%21room%3Aexample.org/messages?from=start&dir=f&limit=100")
  client:complete(2, { error = "offline" })
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

test_baseline_resume_filters_and_envelope()
test_state_restart_corruption_and_processed_cap()
test_pending_delivery_retries_safely_after_restart()
test_ack_reconcile_and_utf8_body_cap()
test_messages_backfill_baseline_and_retry_backoff()
test_retry_backoff_grows_and_resets_after_recovery()
print("ok: Matrix relay resume, exactly-once, filters, state, acks, caps, fallback, and backoff")
