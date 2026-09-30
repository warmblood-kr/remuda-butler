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
    messages_since = matrix.json_null, pending_events = remuda.json.object({ ["$pending"] = remuda.json.object({
      event_id = "$pending", sender = "@alice:example.org", room_id = "!room:example.org",
      created_at = "2026-09-30T10:00:00Z", body = "saved", references = "not-a-list",
    }) }) }))
  local file = assert(io.open(state_path, "wb")); file:write(encoded); file:close()

  local relay = relay_module.new({ config_path = config_path, matrix = client, deliver = function() return true end })
  assert(#relay:state().processed_order == 5000)
  assert(relay:state().processed_order[1] == "event-4")
  assert(relay:state().pending["$pending"].references == nil,
    "invalid saved references should be discarded when pending state loads")
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

local function test_thread_root_mail_references_are_stable()
  local dir, config_path = fixture()
  local client, delivered = scripted_client(), {}
  local relay = relay_module.new({ config_path = config_path, matrix = client,
    deliver = function(event)
      delivered[#delivered + 1] = event
      return { id = "M" .. tostring(#delivered - 1) }
    end,
  })
  local function event(id, relates_to, body)
    return { type = "m.room.message", event_id = id, sender = "@alice:example.org",
      content = { msgtype = "m.text", body = body, ["m.relates_to"] = relates_to } }
  end
  local function sync(index, since, events)
    client:complete(index, { json = { next_batch = since, rooms = { join = {
      ["!room:example.org"] = { timeline = { events = events } },
    } } } })
  end

  relay:start()
  client:complete(1, { json = { next_batch = "s0" } })
  sync(2, "s1", { event("$human-root", nil, "Root mail.") })
  assert(delivered[1] and delivered[1].event_id == "$human-root")
  assert(relay:record_outgoing_reply("$human-root", "$butler-sent"),
    "the Butler's Matrix reply event should map back to its answered mail")

  sync(3, "s2", { event("$thread-first-response", {
    rel_type = "m.thread", event_id = "$butler-sent",
    ["m.in_reply_to"] = { event_id = "$butler-sent" },
  }, "Thread starts here.") })
  assert(delivered[2].context_mail_id == "M0", "the first thread mail should target the mail answered by the Butler")
  assert(delivered[2].references and delivered[2].references[1] == "M0",
    "the first thread mail should reference the stable root mail")

  sync(4, "s3", { event("$thread-second-response", {
    rel_type = "m.thread", event_id = "$butler-sent",
    ["m.in_reply_to"] = { event_id = "$thread-first-response" },
  }, "Second response.") })
  assert(delivered[3].context_mail_id == "M1", "a later thread mail should retain its direct reply target")
  assert(delivered[3].references and delivered[3].references[1] == "M0",
    "later thread mail should keep the original root mail reference")
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

local function render_fixture(name, specs)
  local bus = { inboxes = {}, messages = {}, objects = {} }
  for index, spec in ipairs(specs) do
    local object_id = "fixture-object-" .. tostring(index)
    bus.inboxes.butler = bus.inboxes.butler or {}
    bus.inboxes.butler[#bus.inboxes.butler + 1] = spec.id
    bus.messages[spec.id] = {
      id = spec.id,
      from = { host = "matrix", session = "@alice:example.org" },
      created_at = spec.created_at,
      subject = spec.subject,
      in_reply_to = spec.in_reply_to,
      references = spec.references,
      matrix = spec.matrix,
      body = { object_id = object_id },
    }
    bus.objects[object_id] = { content = spec.body }
  end
  remuda._butler_mail_config = { bus = bus }
  dofile("packages/butler/mail.lua")
  local actual = remuda._butler_mail.inbox("butler")
  local file = assert(io.open("tests/fixtures/" .. name, "rb"))
  local expected = file:read("*a")
  file:close()
  expected = expected:gsub("\n$", "")
  assert(actual == expected, name .. " rendered text differs\nexpected:\n" .. expected .. "\nactual:\n" .. actual)
end

local function test_thread_first_fixtures()
  local failures = {}
  local cases = {
    { "matrix-mail-thread-first.txt", {
      { id = "MAIL-THREAD-FIRST", created_at = "2026-09-30T10:00:00Z",
        subject = "Matrix thread reply from @alice:example.org", in_reply_to = "M0",
        references = { "M0" }, body = "The Butler's reply started this thread.",
        matrix = { event_id = "$thread-first-response" } },
    } },
    { "matrix-mail-thread-human-root.txt", {
      { id = "MAIL-HUMAN-ROOT", created_at = "2026-09-30T09:59:00Z",
        subject = "Matrix message from @alice:example.org", references = { "MAIL-HUMAN-ROOT" },
        body = "Starting the human-rooted thread.", matrix = { event_id = "$human-root" } },
    } },
  }
  for _, case in ipairs(cases) do
    local ok, err = pcall(render_fixture, case[1], case[2])
    if not ok then failures[#failures + 1] = tostring(err) end
  end
  assert(#failures == 0, table.concat(failures, "\n"))
end

local function test_thread_reply_fixture()
  render_fixture("matrix-mail-thread-replies.txt", {
    { id = "MAIL-THREAD-REPLY-1", created_at = "2026-09-30T10:01:00Z",
      subject = "Matrix thread reply from @alice:example.org", in_reply_to = "MAIL-THREAD-ROOT",
      references = { "MAIL-THREAD-ROOT" }, body = "I suggest the blue version.",
      matrix = { event_id = "$thread-reply-1" } },
    { id = "MAIL-THREAD-REPLY-2", created_at = "2026-09-30T10:02:00Z",
      subject = "Matrix thread reply from @alice:example.org", in_reply_to = "MAIL-THREAD-REPLY-1",
      references = { "MAIL-THREAD-ROOT" }, body = "Agreed, use blue.",
      matrix = { event_id = "$thread-reply-2" } },
  })
end

local function test_plain_reply_fixture()
  local dir, config_path = fixture()
  local client, received = scripted_client(), {}
  local relay = relay_module.new({ config_path = config_path, matrix = client,
    deliver = function(event) received[#received + 1] = event return true end,
  })
  relay:start()
  client:complete(1, { json = { next_batch = "s0" } })
  client:complete(2, { json = { next_batch = "s1", rooms = { join = {
    ["!room:example.org"] = { timeline = { events = {
      { type = "m.room.message", event_id = "$plain-reply", sender = "@alice:example.org",
        content = { msgtype = "m.text", body = "> <@alice:example.org> original\n\nYes, it is ready.",
          ["m.relates_to"] = { ["m.in_reply_to"] = { event_id = "$plain-target" } } } },
    } } },
  } } } })
  assert(received[1] and received[1].body == "Yes, it is ready.",
    "plain replies should drop the leading Matrix fallback quote and separator")
  relay:stop()
  os.execute("rm -rf " .. string.format("%q", dir))
  render_fixture("matrix-mail-plain-reply.txt", {
    { id = "MAIL-PLAIN-REPLY", created_at = "2026-09-30T10:03:00Z",
      subject = "Matrix message from @alice:example.org", in_reply_to = "MAIL-PLAIN-TARGET",
      body = received[1].body,
      matrix = { event_id = "$plain-reply" } },
  })
end

local function test_image_fixture()
  render_fixture("matrix-mail-image.txt", {
    { id = "MAIL-IMAGE", created_at = "2026-09-30T10:04:00Z",
      subject = "Matrix message from @alice:example.org", body = "",
      matrix = { event_id = "$image", media = { kind = "image", filename = "chart.png",
        mimetype = "image/png", size = 12345, mxc = "mxc://example.org/chart" } } },
  })
end

test_baseline_resume_filters_and_envelope()
test_state_restart_corruption_and_processed_cap()
test_pending_delivery_retries_safely_after_restart()
test_ack_reconcile_and_utf8_body_cap()
test_messages_backfill_baseline_and_retry_backoff()
test_retry_backoff_grows_and_resets_after_recovery()
test_allowlist_refusal_is_logged_once()
test_thread_root_mail_references_are_stable()
setup_tests(matrix)
test_redefined_public_words_do_not_change_trust()
local fixture_failures = {}
for _, test in ipairs({ test_thread_first_fixtures, test_thread_reply_fixture,
    test_plain_reply_fixture, test_image_fixture }) do
  local ok, err = pcall(test)
  if not ok then fixture_failures[#fixture_failures + 1] = tostring(err) end
end
assert(#fixture_failures == 0, "rendered mail fixture failures:\n" .. table.concat(fixture_failures, "\n"))
print("ok: Matrix relay resume, exactly-once, filters, state, acks, caps, fallback, and backoff")
