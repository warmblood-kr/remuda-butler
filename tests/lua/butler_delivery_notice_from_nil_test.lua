-- The delivery notice cache must classify an origin, not require one.
--
-- A real Matrix parent reply returns its durable marker and the reply API
-- early-returns; a local reply saves durable mail and notifies once; and a
-- delivery envelope with no `from` must still commit its mail and keep the
-- already computed notice result instead of throwing after the commit.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))

T.eval([==[
  remuda._butler_argv = { "sh", "-c", "sleep 60" }
  remuda._butler_skip_relay = true
  remuda._butler_readiness_timeout = 1
]==])

T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 10, "Butler root start")

T.eval([==[
  local counters = { notify = {}, runs = 0 }
  remuda._t_counters = counters
  local real_notify = assert(remuda._butler_notify, "the notice seam is installed")
  remuda._butler_notify = function(alias, notice, message_id, ...)
    counters.notify[message_id or alias] = (counters.notify[message_id or alias] or 0) + 1
    return real_notify(alias, notice, message_id, ...)
  end
  local real_run = remuda.process and remuda.process.run
  if type(real_run) == "function" then
    remuda.process.run = function(...)
      counters.runs = counters.runs + 1
      return real_run(...)
    end
  end
]==])

local http_file = assert(io.open("tests/support/fake_http.lua"))
local http_source = http_file:read("a")
http_file:close()
T.eval(http_source)

T.test("a local reply saves durable mail and notifies once", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local counters = remuda._t_counters
    bus.agents.fixer = { id = "01FIXER000000000000000000", alias = "fixer",
      session = "fixer", kind = "agent" }
    bus.inboxes.fixer = bus.inboxes.fixer or {}
    local parent = assert(remuda._butler_mail.queue("fixer", "butler", "parent body",
      "Parent subject"))
    local summary = remuda._butler_reply("butler", parent.id, "local reply body")
    local reply_id = summary:match("queued (%w+)")
    assert(reply_id and #reply_id == 26, "the local reply saved one durable ULID: " .. summary)
    local message = assert(remuda._butler_mail.find_message(reply_id), "the reply is readable")
    assert(message.in_reply_to == parent.id, "the reply names its parent")
    assert(message.subject == "Re: Parent subject", "the reply keeps the thread subject")
    assert(message.references and message.references[#message.references] == parent.id,
      "the reply references the parent")
    assert(message.from and message.from.host == "local", "the reply keeps the local sender")
    local object = message.body and bus.objects[message.body.object_id]
    assert(object and object.content == "local reply body", "the full reply body is stored")
    assert(remuda._butler_mail.is_unread("01FIXER000000000000000000", reply_id),
      "the reply is delivered to the local recipient")
    assert(counters.notify[reply_id] == 1, "exactly one notice for the local reply")
    local pending = bus.notices.fixer
    assert(pending and pending.message_ids and pending.message_ids[reply_id],
      "one notice for the local reply is queued for the pane")
    assert(#remuda.http.calls == 0, "a local reply never uses the Matrix outbox")
    assert(counters.runs == 0, "a local reply starts no native helper")
    return reply_id
  ]==])
  T.eq(#out, 26, "local reply ULID")
end)

T.test("a from-less delivery commits and keeps its notice result", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local counters = remuda._t_counters
    local config = remuda._butler_notice_config
    local before = {}
    for _, id in ipairs(bus.inboxes.butler or {}) do before[id] = true end
    local delivered = remuda.emit_until_success("butler/deliver", {
      to = "butler", text = "from-less body", subject = "From-less subject",
      references = {},
    })
    assert(type(delivered) == "table", "the delivery hook answered")
    assert(delivered.__butler_delivery_hook_error == nil,
      "the nil origin must not throw after the durable queue: "
        .. tostring(delivered.__butler_delivery_hook_error))
    local id = assert(delivered.id, "the delivery returned its durable id")
    assert(#id == 26, "the from-less delivery saved one durable ULID")
    local message = assert(remuda._butler_mail.find_message(id), "the mail is readable")
    assert(message.from and message.from.host == "local" and message.from.alias == "outside",
      "mail.queue keeps its existing normalization for an absent sender")
    assert(not before[id], "the from-less delivery is the new inbox row")
    local object = message.body and bus.objects[message.body.object_id]
    assert(object and object.content == "from-less body", "the full body is stored")
    assert(counters.notify[id] == 1, "one notice attempt for the from-less delivery")
    local cached = config.take_delivery_notice_result({ id = id }, "butler")
    assert(type(cached) == "table", "the computed result is cached after the missing origin")
    assert(cached.recipient_live == true, "the cached result keeps the live recipient fact")
    assert(counters.notify[id] == 1, "taking the cached result does not notify again")
    assert(config.take_delivery_notice_result({ id = id }, "butler") == nil,
      "the cached result is consumed exactly once")
    assert(counters.runs == 0, "the from-less path starts no native helper")
    return id
  ]==])
  T.eq(#out, 26, "from-less ULID")
end)

T.test("a Matrix parent reply saves one outbox send and no native notice", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local counters = remuda._t_counters
    local config = remuda._butler_notice_config
    local root = assert(os.getenv("XDG_CONFIG_HOME"), "the daemon has a config home")
    local dir = root .. "/from-nil-matrix"
    pcall(remuda.mkdir, dir)
    local config_path, token_path = dir .. "/matrix.conf", dir .. "/matrix.conf.token"
    local file = assert(io.open(config_path, "w"))
    file:write("http://matrix.invalid\n!room:example.org\n@bot:example.org\n@alice:example.org\n",
      "false\n30000\nroom=!room:example.org how=operator mode=all\n")
    file:close()
    local token = assert(io.open(token_path, "w"))
    token:write("fake-token")
    token:close()
    remuda._butler_matrix_config = { config_path = config_path, token_path = token_path }

    remuda.http.calls = {}
    remuda.http.pending = {}
    remuda.http.responses = {}
    remuda.http.response_prefixes = {
      { method = "POST", prefix = "http://matrix.invalid/_matrix/client/v3/sync",
        result = { json = { next_batch = "s0", rooms = { join = {} } } } },
      { method = "GET", prefix = "http://matrix.invalid/_matrix/client/v3/rooms/",
        result = { body = '{"event":{"room_id":"!room:example.org","event_id":"$human-root"}}' } },
      { method = "PUT", prefix = "http://matrix.invalid/_matrix/client/v3/rooms/",
        result = { body = '{"event_id":"$butler-sent"}' } },
    }
    assert(remuda.butler.matrix.relay.start(remuda._butler_matrix_config),
      "the real Matrix relay starts on the fake homeserver")

    local parent = assert(remuda._butler_mail.queue(
      { host = "matrix", id = "", alias = "@alice:example.org",
        session = "@alice:example.org", kind = "matrix" },
      "butler", "matrix parent body", "Matrix message from @alice:example.org",
      nil, nil, { sender = "@alice:example.org", room_id = "!room:example.org",
        event_id = "$human-root", created_at = "2026-11-06T11:00:00Z",
        room = "test", room_kind = "dm", trusted = true, mentions = {} }))

    local summary = remuda._butler_reply("butler", parent.id, "matrix reply body")
    local reply_id = summary:match("queued Matrix reply (%w+)")
    assert(reply_id and #reply_id == 26,
      "the Matrix reply returned its durable marker: " .. tostring(summary))
    assert(config.take_delivery_notice_result({ id = reply_id }, "butler") == nil,
      "a genuine Matrix reply never enters the notice cache")

    remuda.http.tick()
    remuda.http.tick()
    local sends, txn = 0, nil
    for _, call in ipairs(remuda.http.calls) do
      local spec = call.spec or call
      if spec.method == "PUT" and spec.url:find("/send/m.room.message/", 1, true) then
        sends = sends + 1
        txn = spec.url:match("/send/m%.room%.message/([^%?]+)")
        assert(spec.body:find("matrix reply body", 1, true) ~= nil, "the outbox carries the reply text")
      end
    end
    assert(sends == 1, "exactly one outbox send for the Matrix reply: " .. sends)
    assert(txn and txn:sub(1, #("butler_" .. reply_id)) == "butler_" .. reply_id,
      "the outbox reuses the reply id as its txn: " .. tostring(txn))
    local status = remuda.butler.matrix.mail_reply_status(parent.id)
    assert(type(status) == "table" and status.reply_mail_id == reply_id,
      "the relay retained the same reply id")
    assert(status.event_id == "$butler-sent", "the relay recorded the sent event")
    assert(counters.runs == 0, "a Matrix reply starts no native helper")
    remuda.butler.matrix.relay.stop()
    return summary
  ]==])
  T.eq(out:sub(1, 19), "queued Matrix reply", "Matrix reply marker")
end)
