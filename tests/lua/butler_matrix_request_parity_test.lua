-- B06 (Rust->Lua migration, #320): Matrix request transport, the shared fake
-- remuda.http (tests/support/fake_http.lua), paged reads and bounded writes.
-- Test names equal the Rust names in tests/butler_daemon.rs.
local REPO = assert(os.getenv("REMUDA_LUA_REPO"))
local SCRATCH = assert(os.getenv("REMUDA_LUA_SCRATCH"))
T.install_mod("butler", REPO)
T.eval("remuda._butler_test_mode = 'lifecycle'; remuda._butler_skip_relay = true")
T.eval('return remuda.exec("butler")')
-- One child daemon serves every test in this file (Rust spawned one per test),
-- so remember the real transport: the fake replaces it and D111 needs it back.
T.eval("remuda._b06_real = { http = remuda.http, schedule = remuda.schedule, cancel = remuda.cancel }")

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

-- Same files as the Rust butler_config helper: a token plus a config of
-- homeserver, room, self mxid, allowed senders, blank, poll timeout 100.
local function config(tag, homeserver, room, self_mxid, allowed, config_text)
  local dir = SCRATCH .. "/b06-" .. tag
  remuda.mkdir(dir)
  local token_path, config_path = dir .. "/" .. tag .. ".token", dir .. "/" .. tag .. ".config"
  write_file(token_path, "test-token\n")
  write_file(config_path, config_text
    or (homeserver .. "\n" .. room .. "\n" .. self_mxid .. "\n" .. allowed .. "\n\n100\n"))
  return dir, token_path, config_path
end

-- Reset the shared daemon to the real transport, drop any relay a previous
-- test left behind, optionally load the shared fake, then point the Matrix
-- modules at this test's token/config and (re)load them: each exec rebuilds
-- the request limiter, so every test starts with a fresh one.
local function boot(opts)
  local lines = { string.format("local REPO = %q", REPO), [[
    local real = remuda._b06_real
    remuda.http, remuda.schedule, remuda.cancel = real.http, real.schedule, real.cancel
    local relay = remuda.butler.matrix and remuda.butler.matrix.relay
    if relay and relay.instance then
      if type(relay.instance.stop) == "function" then pcall(relay.instance.stop, relay.instance) end
      relay.instance = nil
    end
  ]] }
  if opts.fake ~= false then lines[#lines + 1] = 'dofile(REPO .. "/tests/support/fake_http.lua")' end
  if opts.token_path then
    lines[#lines + 1] = string.format(
      "remuda._butler_matrix_config = { token_path = %q, config_path = %q }", opts.token_path, opts.config_path)
  end
  for _, module in ipairs(opts.modules or {}) do
    lines[#lines + 1] = string.format("remuda.exec(%q)", module)
  end
  lines[#lines + 1] = "return 'booted'"
  T.eq(T.eval(table.concat(lines, "\n")), "booted", "boot failed")
end

local function vars(values)
  local lines = {}
  for name, value in pairs(values) do lines[#lines + 1] = string.format("local %s = %q", name, value) end
  return table.concat(lines, "\n") .. "\n"
end

T.test("butler_matrix_request_uses_fake_http_for_auth_trust_allow_and_same_room", function()
  local room = "!request:example.org"
  local pin_hex = string.rep("00", 32)
  local _, token_path, config_path = config("request", "https://matrix.example.org", room, "@bot:example.org", "",
    "https://matrix.example.org\n" .. room .. "\n@bot:example.org\n\npin_sha256=" .. pin_hex
      .. "\nca_file=/tmp/test-ca.pem\n")
  boot({ token_path = token_path, config_path = config_path })
  local result = T.eval(vars({ ROOM = room }) .. [==[
      local loaded, load_error = pcall(remuda.exec, "butler/matrix_request")
      if not loaded then return "missing|" .. tostring(load_error) end
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/joined_rooms",
        { status = 200, headers = {}, body = "{}" })
      local finished, finished_count
      finished_count = 0
      matrix.request({ method = "GET", path = "/_matrix/client/v3/joined_rooms",
        max_bytes = 2048, timeout = 12 }, function(value) finished = value; finished_count = finished_count + 1 end)
      local spec = remuda.http.calls[1]
      if not spec then return "no-request" end
      if finished then return "callback-ran-inline" end
      if spec.headers.Authorization ~= "Bearer test-token" then return "bad-auth" end
      if spec.pin ~= "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" then return "bad-pin:" .. tostring(spec.pin) end
      if spec.ca_file ~= "/tmp/test-ca.pem" then return "bad-ca" end
      if spec.max_bytes ~= 2048 or spec.timeout ~= 12 then return "bad-bounds" end
      remuda.http.tick()
      remuda.http.tick()
      if finished.status ~= 200 then return "callback-not-delivered" end
      if finished_count ~= 1 then return "callback-not-once" end
      local denied
      matrix.request({ method = "GET", path = "/_matrix/client/v3/rooms/!other:example.org/messages",
        room = "!other:example.org" }, function(value) denied = value end)
      if #remuda.http.calls ~= 1 then return "allowlist-reached-network" end
      if not denied or not denied.error then return "allowlist-not-reported" end
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/rooms/%21request%3Aexample.org/context/%24event",
        { status = 200, headers = {}, body = '{"event":{"room_id":"' .. ROOM .. '"}}' })
      local same
      matrix.same_room(ROOM, "$event", function(value) same = value end)
      if #remuda.http.calls ~= 1 then return "limiter-did-not-queue" end
      remuda.http.respond("PUT", "https://matrix.example.org/_matrix/media/v3/upload",
        { status = 201, headers = { ["Content-Type"] = "application/octet-stream" }, body = "\0\255" })
      local uploaded
      matrix.request({ method = "PUT", path = "/_matrix/media/v3/upload", room = ROOM,
        body = "\0\255", headers = { ["Content-Type"] = "application/octet-stream" }, max_bytes = 4096 },
        function(value) uploaded = value end)
      if #remuda.http.calls ~= 1 then return "limiter-did-not-queue-burst" end
      remuda.http.tick()
      if #remuda.http.calls ~= 2 then return "limiter-did-not-release" end
      if same ~= true then return "same-room-failed" end
      if uploaded then return "second-callback-ran-too-early" end
      remuda.http.tick()
      if #remuda.http.calls ~= 3 then return "limiter-did-not-preserve-burst" end
      local raw = remuda.http.calls[3]
      if raw.method ~= "PUT" or raw.body ~= "\0\255" then return "raw-body-changed" end
      if raw.headers["Content-Type"] ~= "application/octet-stream" then return "raw-content-type-lost" end
      if not uploaded or uploaded.status ~= 201 then return "raw-callback-not-delivered" end
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/versions",
        { status = 200, headers = {}, body = '{"next_batch":"n","unicode":"\\uD83D\\uDE42","ok":true}' })
      local decoded
      matrix.request_json({ method = "GET", path = "/_matrix/client/v3/versions" },
        function(value) decoded = value end)
      remuda.http.tick()
      if not decoded or not decoded.json or decoded.json.next_batch ~= "n" or decoded.json.ok ~= true
        or decoded.json.unicode ~= "🙂" then return "json-response-not-decoded" end
      local encoded, encode_error = matrix.encode_json({ body = "line\n", count = 2 })
      if not encoded then return "json-encode-failed:" .. tostring(encode_error) end
      local roundtrip = matrix.decode_json(encoded)
      if not roundtrip or roundtrip.body ~= "line\n" or roundtrip.count ~= 2 then return "json-roundtrip-failed" end
      local duplicate, duplicate_error = remuda.json.decode('{"key":1,"key":2}')
      if duplicate ~= nil or duplicate_error ~= "duplicate key" then return "duplicate-key-not-rejected" end
      local tagged = remuda.json.encode({ array = remuda.json.array({}), object = remuda.json.object({}) })
      local tagged_value = remuda.json.decode(tagged)
      if not tagged_value or getmetatable(tagged_value.array) ~= getmetatable(remuda.json.array({}))
        or getmetatable(tagged_value.object) ~= getmetatable(remuda.json.object({})) then
        return "empty-json-shapes-not-preserved"
      end
      remuda.http.respond("GET", "https://matrix.example.org/_matrix/client/v3/bad",
        { status = 400, headers = {}, body = "bad request" })
      local failed
      matrix.request_json({ method = "GET", path = "/_matrix/client/v3/bad" }, function(value) failed = value end)
      remuda.http.tick()
      if not failed or not failed.error or not failed.error:find("Matrix HTTP 400", 1, true) then return "http-error-not-surfaced" end
      return "ok"
  ]==])
  T.eq(result, "ok", "Matrix request word should use the fake async HTTP boundary: " .. result)
end)

T.test("butler_matrix_request_uses_system_tls_trust_by_default", function()
  local room = "!request:example.org"
  local _, token_path, config_path = config("no-trust", "https://matrix.example.org", room, "@bot:example.org", "",
    "https://matrix.example.org\n" .. room .. "\n@bot:example.org\n")
  boot({ token_path = token_path, config_path = config_path,
    modules = { "butler/matrix_request", "butler/matrix_relay" } })
  local result = T.eval([==[
      local failure
      remuda.butler.matrix.request({ method = "GET", path = "/_matrix/client/v3/versions" },
        function(value) failure = value end)
      local spec = remuda.http.calls[1]
      if failure then return "request-failed:" .. tostring(failure.error) end
      if not spec then return "no-request" end
      if spec.url ~= "https://matrix.example.org/_matrix/client/v3/versions" then return "bad-url" end
      if spec.pin ~= nil or spec.ca_file ~= nil then return "trust-override-added" end
      return "ok"
  ]==])
  T.eq(result, "ok", "HTTPS requests should use the core system trust verifier by default: " .. result)
end)

T.test("butler_matrix_fake_http_holds_and_releases_long_poll_on_tick", function()
  boot({})
  local result = T.eval([==[
      local url = "https://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=30000"
      remuda.http.hold("GET", url)
      local completed
      remuda.http.request({ method = "GET", url = url, timeout = 30,
        callback = function(value) completed = value end })
      remuda.http.tick()
      if completed then return "held-callback-fired" end
      if #remuda.http.calls ~= 1 then return "request-not-recorded" end
      local released = remuda.http.release("GET", url,
        { status = 200, headers = {}, body = "{}" })
      if not released then return "request-not-released" end
      if completed then return "release-fired-inline" end
      remuda.http.tick()
      if not completed or completed.status ~= 200 then return "release-not-delivered-on-tick" end
      return "ok"
  ]==])
  T.eq(result, "ok", "fake HTTP long-poll hold must be asynchronous: " .. result)
end)

T.test("butler_matrix_relay_uses_async_request_and_preserves_envelope_metadata", function()
  local room = "!relay:example.org"
  local _, token_path, config_path = config("relay", "https://matrix.example.org", room, "@bot:example.org",
    "@alice:example.org",
    " https://matrix.example.org/  \r\n " .. room .. "  \r\n @bot:example.org \r\n @alice:example.org \r\n false \r\n 30000 \r\n ca_file = /tmp/test-ca.pem \r\n")
  boot({ token_path = token_path, config_path = config_path,
    modules = { "butler/matrix_request", "butler/matrix_relay" } })
  local event = { type = "m.room.message", event_id = "$relay-event", sender = "@alice:example.org",
    origin_server_ts = 0,
    content = { msgtype = "m.text", body = "hello", url = "mxc://media/example",
      ["m.relates_to"] = { rel_type = "m.thread", event_id = "$thread-root",
        ["m.in_reply_to"] = { event_id = "$parent" } } } }
  local response = remuda.json.encode({ next_batch = "s1",
    rooms = { join = { [room] = { timeline = { events = { event } } } } } })
  local result = T.eval(vars({
    BASELINE = "https://matrix.example.org/_matrix/client/v3/sync?timeout=0",
    SYNC = "https://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=30000",
    RESPONSE = response, CONFIG = config_path }) .. [==[
            local matrix = remuda.butler.matrix
            remuda.http.respond("GET", BASELINE, { status = 200, headers = {}, body = '{"next_batch":"s0"}' })
            remuda.http.respond("GET", SYNC, { status = 200, headers = {}, body = RESPONSE })
            -- #235 step B: the first mail from an unseen thread waits for two context GETs.
            remuda.http.respond_prefix("GET", "https://matrix.example.org/_matrix/client/v3/rooms/%21relay%3Aexample.org/event/",
              { status = 200, headers = {}, body = '{"type":"m.room.message","event_id":"$thread-root","sender":"@alice:example.org","origin_server_ts":0,"content":{"msgtype":"m.text","body":"thread start"}}' })
            remuda.http.respond_prefix("GET", "https://matrix.example.org/_matrix/client/v1/rooms/%21relay%3Aexample.org/relations/",
              { status = 200, headers = {}, body = '{"chunk":[]}' })
            remuda.relay_deliveries = {}
            remuda.relay_client = matrix.relay.new({ config_path = CONFIG, matrix = matrix,
              deliver = function(value) table.insert(remuda.relay_deliveries, value); return true end })
            remuda.relay_client:start()
            if #remuda.http.calls ~= 1 then return "baseline-not-started" end
            if remuda.relay_deliveries[1] then return "callback-ran-inline" end
            remuda.http.tick()
            remuda.http.tick()
            -- Old expectation: delivered after these two ticks. Since #235 step B the
            -- two context GETs wait their turn in the request queue first.
            for _ = 1, 12 do
              if #remuda.relay_deliveries == 1 then break end
              remuda.http.tick()
            end
            if #remuda.relay_deliveries ~= 1 then return "event-not-delivered" end
            local event = remuda.relay_deliveries[1]
            if event.event_id ~= "$relay-event" or event.thread_root ~= "$thread-root"
              or event.in_reply_to ~= "$parent" or event.mxc ~= "mxc://media/example" then return "metadata-lost" end
            if event.created_at ~= "1970-01-01T00:00:00Z" then return "timestamp-wrong" end
            local first = remuda.http.calls[1]
            if first.headers.Authorization ~= "Bearer test-token" then return "missing-auth" end
            if first.ca_file ~= "/tmp/test-ca.pem" then return "missing-ca" end
            if first.timeout ~= 10 then return "baseline-timeout-wrong" end
            if remuda.http.calls[2].url ~= SYNC then return "since-poll-wrong" end
            remuda.relay_client:stop()
            return "ok"
  ]==])
  T.eq(result, "ok", "L3 must poll asynchronously via L1 and retain envelope metadata: " .. result)
end)

T.test("butler_matrix_relay_persists_matrix_event_time_through_real_mail_delivery", function()
  local room = "!relay-time:example.org"
  local _, token_path, config_path = config("mail-time", "http://matrix.example.org", room, "@bot:example.org",
    "@alice:example.org")
  boot({ token_path = token_path, config_path = config_path,
    modules = { "butler/matrix_request", "butler/matrix_relay" } })
  local event = { type = "m.room.message", event_id = "$mail-time", sender = "@alice:example.org",
    origin_server_ts = 0,
    content = { msgtype = "m.text", body = "dated \27[31mby Matrix" .. string.char(194, 155) .. "2J" } }
  local response = remuda.json.encode({ next_batch = "s1",
    rooms = { join = { [room] = { timeline = { events = { event } } } } } })
  local result = T.eval(vars({
    BASELINE = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0",
    SYNC = "http://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=100",
    RESPONSE = response }) .. [==[
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", BASELINE, {status=200,headers={},body='{"next_batch":"s0"}'})
      remuda.http.respond("GET", SYNC, {status=200,headers={},body=RESPONSE})
      local original_delivery = remuda._butler_inbox_delivery
      remuda._butler_inbox_delivery = function(message)
        remuda.captured_delivery = message
        return original_delivery(message)
      end
      assert(matrix.relay.start(remuda._butler_matrix_config))
      for _=1,4 do remuda.http.tick() end
      remuda._butler_inbox_delivery = original_delivery
      local bus = remuda._butler_bus
      local root = assert(bus.agents.butler)
      for _, id in ipairs(remuda._butler_mail.mailbox(root.id)) do
        local message = bus.messages[id]
        if message and message.matrix and message.matrix.event_id == "$mail-time" then
          local body = bus.objects[message.body.object_id].content
          matrix.relay.stop()
          return message.created_at .. "|" .. tostring(message.matrix.room)
            .. "|" .. tostring(message.matrix.event_id) .. "|" .. body
        end
      end
      local state = matrix.relay.instance:state()
      local report = "mail-not-found|captured=" .. tostring(remuda.captured_delivery ~= nil)
        .. "|calls=" .. #remuda.http.calls .. "|pending=" .. tostring(state.pending["$mail-time"] ~= nil)
        .. "|inbox=" .. #remuda._butler_mail.mailbox(root.id)
      matrix.relay.stop()
      return report
  ]==])
  T.eq(result, "1970-01-01T00:00:00Z|home|$mail-time|dated [31mby Matrix2J",
    "relay-to-mail delivery must preserve metadata and strip control characters: " .. result)
end)

T.test("butler_matrix_read_composites_use_async_request_for_history_and_thread_pages", function()
  local _, token_path, config_path = config("read", "http://matrix.example.org", "!read:example.org",
    "@bot:example.org", "")
  boot({ token_path = token_path, config_path = config_path,
    modules = { "butler/matrix_request", "butler/matrix_read" } })
  local result = T.eval([==[
      local matrix = remuda.butler.matrix
      local room = "!read:example.org"
      local encoded_room = "%21read%3Aexample.org"
      local history_url = "http://matrix.example.org/_matrix/client/v3/rooms/" .. encoded_room .. "/messages?dir=b&limit=25"
      remuda.http.respond("GET", history_url, { status = 200, headers = {}, body = '{"chunk":[{"event_id":"$h"}]}' })
      local history
      matrix.history({ n = 25 }, function(value) history = value end)
      if history then return "history-callback-inline" end
      remuda.http.tick()
      if not history or not history.json or history.json.chunk[1].event_id ~= "$h" then return "history-result" end
      if remuda.http.calls[1].headers.Authorization ~= "Bearer test-token" then return "history-auth" end
      local invalid
      matrix.history({ n = 201 }, function(value) invalid = value end)
      if not invalid or not invalid.error or #remuda.http.calls ~= 1 then return "history-bound" end

      local first = "http://matrix.example.org/_matrix/client/v1/rooms/" .. encoded_room
        .. "/relations/%24root/m.thread?dir=b&limit=100"
      local second = first .. "&from=page%2F2"
      remuda.http.respond("GET", first, { status = 200, headers = {}, body = '{"chunk":[{"event_id":"$a"}],"next_batch":"page/2"}' })
      remuda.http.respond("GET", second, { status = 200, headers = {}, body = '{"chunk":[{"event_id":"$b"}]}' })
      local thread
      matrix.thread({ event_id = "$root" }, function(value) thread = value end)
      for _ = 1, 6 do remuda.http.tick() end
      if not thread or #thread.json.chunk ~= 2 then return "thread-pages" end
      if thread.json.chunk[1].event_id ~= "$a" or thread.json.chunk[2].event_id ~= "$b" then return "thread-order" end
      if #remuda.http.calls ~= 3 then return "thread-request-count" end
      local rooms
      matrix.rooms({}, function(value) rooms = value end)
      if not rooms or rooms.status ~= 200 or not rooms.json or not rooms.json.rooms or not rooms.json.rooms[1]
        or rooms.json.rooms[1].room ~= room or rooms.json.rooms[1].kind ~= "home" then return "rooms-result" end
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/rooms/" .. encoded_room .. "/event/%24event",
        { status = 200, headers = {}, body = '{"event_id":"$event","room_id":"!read:example.org"}' })
      local event
      matrix.event({ event_id = "$event" }, function(value) event = value end)
      for _ = 1, 5 do remuda.http.tick() end
      if not event or event.json.event_id ~= "$event" or event.json.room_id ~= room then return "event-result" end
      if #remuda.http.calls ~= 4 then return "read-request-count" end
      return "ok"
  ]==])
  T.eq(result, "ok", "read composites should page asynchronously through matrix.request: " .. result)
end)

T.test("butler_matrix_read_status_and_download_keep_cursor_and_media_bounds", function()
  local dir, token_path, config_path = config("read-media", "http://matrix.example.org", "!read:example.org",
    "@bot:example.org", "")
  write_file(config_path .. ".since", '{"since":"s-7","messages_since":"m-4"}')
  local output, empty_output = dir .. "/download.bin", dir .. "/empty-download.bin"
  os.remove(output)
  os.remove(empty_output)
  boot({ token_path = token_path, config_path = config_path,
    modules = { "butler/matrix_request", "butler/matrix_read" } })
  local result = T.eval(vars({ OUTPUT = output, EMPTY_OUTPUT = empty_output }) .. [==[
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/account/whoami",
        { status = 200, headers = {}, body = '{"user_id":"@bot:example.org","device_id":"D1"}' })
      remuda.http.respond("GET", "http://matrix.example.org/_matrix/client/v3/joined_rooms",
        { status = 200, headers = {}, body = '{"joined_rooms":["!read:example.org"]}' })
      local status
      matrix.status({}, function(value) status = value end)
      for _ = 1, 5 do remuda.http.tick() end
      if not status or status.json.user_id ~= "@bot:example.org" or status.json.device_id ~= "D1" then return "status-identity" end
      if status.json.sync_cursor ~= "s-7" or status.json.fallback_cursor ~= "m-4" then return "status-cursor" end
      local v1 = "http://matrix.example.org/_matrix/client/v1/media/download/media.example/asset%3A1"
      local legacy = "http://matrix.example.org/_matrix/media/v3/download/media.example/asset%3A1"
      remuda.http.respond("GET", v1, { status = 404, headers = {}, body = '{"errcode":"M_NOT_FOUND"}' })
      remuda.http.respond("GET", legacy, { status = 200, headers = { ["content-type"] = "application/octet-stream" }, body = string.char(0, 255) .. "binary" })
      local media
      matrix.download({ mxc = "mxc://media.example/asset:1", output = OUTPUT }, function(value) media = value end)
      for _ = 1, 6 do remuda.http.tick() end
      if not media or media.bytes ~= 8 then return "download-result:" .. tostring(media and media.error) .. ":bytes=" .. tostring(media and media.bytes) .. ":calls=" .. #remuda.http.calls end
      if remuda.http.calls[3].max_bytes ~= 20 * 1024 * 1024 or remuda.http.calls[4].max_bytes ~= 20 * 1024 * 1024 then return "download-cap" end
      if remuda.http.calls[3].headers.Accept ~= "*/*" or remuda.http.calls[4].headers.Authorization ~= "Bearer test-token" then return "download-headers" end
      local empty_url = "http://matrix.example.org/_matrix/client/v1/media/download/media.example/empty"
      remuda.http.respond("GET", empty_url, { status = 200, headers = {}, body = "" })
      local empty
      matrix.download({ mxc = "mxc://media.example/empty", output = EMPTY_OUTPUT }, function(value) empty = value end)
      for _ = 1, 5 do remuda.http.tick() end
      if not empty or empty.error or empty.bytes ~= 0 then return "empty-download" end
      local relative
      matrix.download({ mxc = "mxc://media.example/asset", output = "relative.bin" }, function(value) relative = value end)
      if not relative or not relative.error or #remuda.http.calls ~= 5 then return "relative-output" end
      return "ok"
  ]==])
  T.eq(result, "ok", "status and media reads should remain bounded and authenticated: " .. result)
  T.ok(read_file(output) == "\0\255binary", "downloaded bytes differ")
  T.ok(read_file(empty_output) == "", "empty download should leave an empty file")
end)

T.test("butler_matrix_fake_http_matches_core_cancellation_bounds_and_headers", function()
  boot({})
  local result = T.eval([==[
      local url = "http://matrix.example.org/parity"
      local function request(extra, callback)
        local spec = { method = "GET", url = url, timeout = 3, callback = callback }
        for key, value in pairs(extra or {}) do spec[key] = value end
        return remuda.http.request(spec)
      end
      local cancelled, count = nil, 0
      local handle = request({}, function(value) cancelled = value; count = count + 1 end)
      handle:cancel()
      remuda.http.tick()
      if not cancelled or cancelled.error ~= "request cancelled" or count ~= 1 then return "cancel-not-once" end
      remuda.http.tick()
      if count ~= 1 then return "cancel-delivered-twice" end

      local too_big
      remuda.http.respond("GET", url, { status = 200, headers = {}, body = "12345" })
      request({ max_bytes = 4 }, function(value) too_big = value end)
      remuda.http.tick()
      if not too_big or too_big.error ~= "response exceeds max_bytes" or too_big.status then return "max-bytes" end

      local normalized
      remuda.http.respond("GET", url, { status = 200,
        headers = { ["Content-Type"] = "application/json", ["CONTENT-TYPE"] = "text/plain",
          ["Set-Cookie"] = { "a=1", "b=2" } }, body = "{}" })
      request({}, function(value) normalized = value end)
      if normalized then return "callback-ran-inline" end
      remuda.http.tick()
      local content_type = normalized.headers["content-type"]
      if content_type ~= "application/json, text/plain" and content_type ~= "text/plain, application/json" then
        return "duplicate-header:" .. tostring(normalized.headers["content-type"])
      end
      if type(normalized.headers["set-cookie"]) ~= "table" or normalized.headers["set-cookie"][2] ~= "b=2" then
        return "set-cookie"
      end
      local invalid
      request({ timeout = 3601 }, function(value) invalid = value end)
      remuda.http.tick()
      if not invalid or not invalid.error then return "invalid-timeout-accepted" end
      local oversized
      request({ max_bytes = 20 * 1024 * 1024 + 1 }, function(value) oversized = value end)
      remuda.http.tick()
      if not oversized or oversized.error ~= "max_bytes exceeds 20 MiB" then return "oversized-limit-accepted" end
      return "ok"
  ]==])
  T.eq(result, "ok", "fake HTTP transport semantics should match core: " .. result)
end)

-- Real loopback HTTP on purpose (no fake): the real remuda.http binding must
-- deliver an error-only result for an unreachable local port.
T.test("butler_matrix_real_http_binding_delivers_unreachable_local_error", function()
  local _, token_path, config_path = config("real-http", "http://127.0.0.1:1", "!smoke:example.org",
    "@bot:example.org", "")
  boot({ fake = false, token_path = token_path, config_path = config_path, modules = { "butler/matrix_request" } })
  T.eval([==[
      remuda._butler_real_http_result = nil
      remuda.butler.matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami", timeout = 2 },
        function(value) remuda._butler_real_http_result = value end)
  ]==])
  local result = T.wait_until(function()
    local value = T.eval([==[
          local value = remuda._butler_real_http_result
          if not value then return "pending" end
          if not value.error then return "missing-error" end
          if value.status ~= nil or value.headers ~= nil or value.body ~= nil then return "failure-has-response-fields" end
          return "error:" .. value.error
    ]==])
    if value ~= "pending" then return value end
    return false
  end, 5, "real remuda.http callback arrived")
  T.ok(result:sub(1, 6) == "error:", "real remuda.http failure shape: " .. result)
end)

T.test("butler_matrix_cancellation_completes_queued_inflight_and_held_once", function()
  local room = "!cancel:example.org"
  local _, token_path, config_path = config("cancel", "http://matrix.example.org", room, "@bot:example.org", "")
  boot({ token_path = token_path, config_path = config_path, modules = { "butler/matrix" } })
  local result = T.eval(vars({ ROOM = room }) .. [==[
      local matrix, room = remuda.butler.matrix, ROOM
      local first_result, queued_result, queued_count
      queued_count = 0
      local first = matrix.request({ method = "GET", path = "/_matrix/client/v3/first" }, function(value) first_result = value end)
      local queued = matrix.request({ method = "GET", path = "/_matrix/client/v3/queued" }, function(value)
        queued_result = value; queued_count = queued_count + 1 end)
      queued:cancel()
      queued:cancel()
      if not queued_result or queued_result.error ~= "cancelled" or queued_count ~= 1 then return "queued-cancel-not-completed-once" end
      if #remuda.http.calls ~= 1 then return "queued-cancel-consumed-network-slot" end
      first:cancel()
      first:cancel()
      remuda.http.tick()
       if not first_result or first_result.error ~= "request cancelled" then return "inflight-cancel-not-reported" end
      local count = 0
      local held_url = "https://matrix.example.org/_matrix/client/v3/sync?timeout=30000"
      remuda.http.hold("GET", held_url)
       local held = remuda.http.request({ method = "GET", url = held_url, timeout = 35, callback = function(value)
         count = count + 1; if value.error ~= "request cancelled" then count = 99 end end })
      remuda.http.tick()
      held:cancel()
      held:cancel()
      remuda.http.tick()
      if count ~= 1 then return "held-cancel-not-reported-once" end
      local completed_count = 0
      local complete_url = "https://matrix.example.org/_matrix/client/v3/complete"
      remuda.http.respond("GET", complete_url, { status = 200, headers = {}, body = "{}" })
       local completed = remuda.http.request({ method = "GET", url = complete_url, timeout = 10, callback = function()
        completed_count = completed_count + 1 end })
      remuda.http.tick()
      completed:cancel()
      remuda.http.tick()
      if completed_count ~= 1 then return "completed-cancel-was-not-a-noop" end
      return "ok"
  ]==])
  T.eq(result, "ok", "Matrix cancellation must settle queued, in-flight, and held calls once: " .. result)
end)

T.test("butler_matrix_send_chunks_utf8_async_and_rejects_empty_or_dash", function()
  local _, token_path, config_path = config("write", "http://matrix.example.org", "!write:example.org",
    "@bot:example.org", "")
  boot({ token_path = token_path, config_path = config_path, modules = { "butler/matrix" } })
  local result = T.eval([==[
      local matrix = remuda.butler.matrix
      local sent, empty, dash
      matrix.send({ text = "", room = "!write:example.org" }, function(v) empty = v end)
      if not empty or not empty.error or #remuda.http.calls ~= 0 then return "empty-send-not-rejected" end
      remuda.http.respond_prefix("PUT",
        "http://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/send/m.room.message/",
        { status = 200, headers = {}, body = '{"event_id":"$sent"}' })
      matrix.send({ text = "-", room = "!write:example.org" }, function(v) dash = v end)
      if dash or #remuda.http.calls ~= 1 then return "dash-not-sent-literally" end
      remuda.http.tick()
      if not dash or dash.error then return "dash-send-failed" end
      local dash_body = matrix.decode_json(remuda.http.calls[1].body)
      if not dash_body or dash_body.body ~= "-" then return "dash-body-not-literal" end
      matrix.send({ text = string.rep("한", 2000), room = "!write:example.org" }, function(value) sent = value end)
      if sent then return "send-callback-ran-inline" end
      if #remuda.http.calls ~= 1 then return "first-chunk-not-queued" end
      for _ = 1, 4 do remuda.http.tick() end
      if not sent or sent.error then return "send-failed" end
      if sent.sent ~= 2 or #remuda.http.calls ~= 3 then return "wrong-chunk-count" end
      local combined, previous = {}, nil
      for index, spec in ipairs(remuda.http.calls) do
        local body = matrix.decode_json(spec.body)
        if not body or #body.body > 4000 then return "chunk-over-4000-bytes" end
        if index > 1 then combined[#combined + 1] = body.body end
        local txn = spec.url:match("/send/m%.room%.message/(.+)$")
        if not txn or txn == previous then return "transaction-id-not-unique" end
        previous = txn
      end
      if table.concat(combined) ~= string.rep("한", 2000) then return "utf8-chunking-lost-data" end
      return "ok"
  ]==])
  T.eq(result, "ok", "Matrix send should compose bounded async requests: " .. result)
end)

T.test("butler_matrix_send_and_reply_add_formatted_body_and_fall_back_to_plain", function()
  local _, token_path, config_path = config("write", "http://matrix.example.org", "!write:example.org",
    "@bot:example.org", "")
  boot({ token_path = token_path, config_path = config_path, modules = { "butler/matrix" } })
  local result = T.eval([==[
      local matrix, room = remuda.butler.matrix, "!write:example.org"
      -- The shared daemon outlives this test: keep what is replaced below.
      remuda._b06_convert = remuda.butler.md2html.convert
      local base = "http://matrix.example.org/_matrix/client/v3/rooms/%21write%3Aexample.org/"
      remuda.http.respond_prefix("GET", base .. "context/",
        { status = 200, headers = {}, body = '{"event":{"room_id":"!write:example.org"}}' })
      remuda.http.respond_prefix("PUT", base .. "send/m.room.message/",
        { status = 200, headers = {}, body = '{"event_id":"$sent"}' })
      matrix.relay.instance = { can_reply_to = function() return true end,
        thread_root_for_event = function(_, event_id) return event_id end,
        b2b_stopped = function() return false end, b2b_turn_limit = function() return 6 end,
        note_own_turn = function() end,
        -- No route: the reply takes a post slot, as for an unknown route.
        route_for_event = function() return nil end, post_cap_hit = function() end }
      local function content_of(start)
        local before, result = #remuda.http.calls, nil
        start(function(value) result = value end)
        for _ = 1, 4 do remuda.http.tick() end
        local call = remuda.http.calls[#remuda.http.calls]
        if not result or result.error or #remuda.http.calls == before or call.method ~= "PUT" then return {} end
        return matrix.decode_json(call.body) or {}
      end
      local text = "**bold** <b>raw</b>"
      local html = "<p><strong>bold</strong> &lt;b&gt;raw&lt;/b&gt;</p>"
      local sent = content_of(function(done) matrix.send({ text = text, room = room }, done) end)
      if sent.msgtype ~= "m.text" or sent.body ~= text then return "send-body-changed" end
      if sent.format ~= "org.matrix.custom.html" or sent.formatted_body ~= html then
        return "send-not-formatted:" .. tostring(sent.formatted_body)
      end
      local reply = content_of(function(done)
        matrix.reply({ room = room, event_id = "$source", text = text }, done)
      end)
      local relation = reply["m.relates_to"] or {}
      if reply.msgtype ~= "m.text" or reply.body ~= text or relation.rel_type ~= "m.thread"
        or relation.event_id ~= "$source" or (relation["m.in_reply_to"] or {}).event_id ~= "$source" then
        return "reply-body-or-relation-changed"
      end
      if reply.format ~= "org.matrix.custom.html" or reply.formatted_body ~= html then return "reply-not-formatted" end
      -- 3900 empty table cells render to more than the 30000-byte HTML cap.
      local wide = "|a|\n|-|\n" .. string.rep("|", 3900)
      local capped = content_of(function(done) matrix.send({ text = wide, room = room }, done) end)
      if capped.body ~= wide or capped.format ~= nil or capped.formatted_body ~= nil then return "oversized-html-sent" end
      remuda.butler.md2html.convert = function() error("converter broke") end
      local plain = content_of(function(done) matrix.send({ text = text, room = room }, done) end)
      if plain.msgtype ~= "m.text" or plain.body ~= text then return "fallback-body-changed" end
      if plain.format ~= nil or plain.formatted_body ~= nil then return "fallback-not-plain" end
      return "ok"
  ]==])
  -- Undo the stub and the converter break whether or not the checks passed.
  T.eval([==[
      remuda.butler.md2html.convert = remuda._b06_convert
      remuda.butler.matrix.relay.instance = nil
      return "restored"
  ]==])
  T.eq(result, "ok", "Matrix m.text must carry safe HTML next to the unchanged plain body: " .. result)
end)
