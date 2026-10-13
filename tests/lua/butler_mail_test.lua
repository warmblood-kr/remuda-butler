T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.eval([=[remuda._butler_mail_config = remuda._butler_mail_config or { bus = { agents = {}, inboxes = {}, messages = {}, objects = {}, next = 0 } }; return remuda.exec("butler/mail")]=])

local function mail_root(tag)
  return T.eval([=[
    local root = os.getenv("XDG_DATA_HOME") .. "/mail-]=] .. tag .. [=["
    remuda.mkdir(root .. "/inboxes")
    remuda.mkdir(root .. "/read")
    remuda.mkdir(root .. "/messages")
    remuda.mkdir(root .. "/objects")
    return root
  ]=])
end

T.test("prompt_parser_returns_multiline_task_and_stops_at_codex_footer", function()
  T.eq(T.eval([=[
    local decision, text = remuda._butler_prompt_is_empty("codex",
      "Ask Codex\n› START task\nsecond task line\nEND task\nGPT-6-Luna medium · ~/projects/ids · task\n? for shortcuts\n98% context left")
    return decision .. "\n" .. text
  ]=]), "NON-EMPTY\nSTART task\nsecond task line\nEND task")
end)

T.test("butler_mail_separates_the_envelope_from_its_body_object", function()
  local result = T.eval([=[
    remuda._butler_new_ulid = remuda._butler_new_ulid or function()
      remuda._mail_test_ulid = (remuda._mail_test_ulid or 0) + 1
      return string.format("0000000000%016X", remuda._mail_test_ulid)
    end
    remuda._butler_mail_config = {
      bus = { agents = { fixer = { id = "01FIXER" } }, inboxes = {}, messages = {}, objects = {}, next = 0 },
      json_quote = function(value) return '"' .. value .. '"' end,
    }
    remuda.exec("butler/mail")
    local message = remuda._butler_mail.queue("butler", "fixer", "private body")
    local object = remuda._butler_mail_config.bus.objects[message.body.object_id]
    return message.from.host .. ":" .. message.from.session .. "\n"
      .. message.body.object_id .. "\n" .. object.content .. "\n"
      .. remuda._butler_mail.inbox("01FIXER")
  ]=])
  T.eq(result:match("^[^\n]+"), "local:butler")
  local object_id = result:match("\n([^\n]+)")
  T.ok(object_id and object_id:match("^object%-"), "body object id does not start with object-")
  T.eq(result:match("^[^\n]*\n[^\n]*\n([^\n]*)"), "private body")
  T.ok(result:find("Message from butler\nprivate body", 1, true), "inbox text did not include the sender and body")
end)

T.test("matrix_mail_truncates_oversized_bodies_with_a_byte_count", function()
  local root = mail_root("matrix-body-cap")
  local result = T.eval([=[
    local root = "]=] .. root .. [=["
    remuda._butler_new_ulid = function()
      remuda._mail_test_ulid = (remuda._mail_test_ulid or 0) + 1
      return string.format("0000000000%016X", remuda._mail_test_ulid)
    end
    remuda._butler_mail_config = {
      bus = { agents = {}, inboxes = {}, messages = {}, objects = {}, next = 0 },
      root = root, json_quote = function(value) return '"' .. value .. '"' end,
    }
    remuda.exec("butler/mail")
    local from = { host = "matrix", alias = "@alice:example.org", session = "@alice:example.org", kind = "matrix" }
    local to = { host = "local", id = "01REP1YF1XER00000000000000", alias = "fixer", session = "fixer" }
    local msg = assert(remuda._butler_mail.queue(from, to, string.rep("a", 65536 + 100), nil, nil, nil,
      { sender = "@alice:example.org", room_id = "!room:example.org", event_id = "$large" }))
    local body = remuda._butler_mail_config.bus.objects[msg.body.object_id].content
    return tostring(#body) .. "|" .. (body:match("%[truncated %d+ bytes%]$") or "missing")
  ]=])
  T.eq(result, "65536|[truncated 121 bytes]")
end)

T.test("butler_mail_an_unidentified_caller_cannot_reply_or_forward_but_the_operator_can", function()
  local root = mail_root("mail-authz")
  local result = T.eval([=[
    local root = "]=] .. root .. [=["
    remuda._butler_new_ulid = function()
      remuda._mail_test_ulid = (remuda._mail_test_ulid or 0) + 1
      return string.format("0000000000%016X", remuda._mail_test_ulid)
    end
    remuda._butler_mail_config = {
      bus = { agents = {}, inboxes = {}, messages = {}, objects = {}, next = 0 },
      root = root, json_quote = function(value) return '"' .. value .. '"' end,
    }
    remuda.exec("butler/mail")
    local M = remuda._butler_mail
    local B = { host = "local", id = "01REP1YBUT1ER0000000000000", alias = "butler", session = "butler" }
    local F = { host = "local", id = "01REP1YF1XER00000000000000", alias = "fixer", session = "fixer" }
    local W = { host = "local", id = "01REP1YW0RKER0000000000000", alias = "worker", session = "worker" }
    local OUT = { host = "local", id = "", alias = "outside", session = "outside" }
    local a = assert(M.queue(B, F, "secret"))
    local r1, e1 = M.forward(OUT, a.id, W)
    local r2, e2 = M.reply(OUT, a.id, "x")
    local w_rows = M.unread(W.id)
    local op = M.reply({ host = "local", id = "", alias = "operator", session = "operator" }, a.id, "from op", true)
    return table.concat({ tostring(r1), tostring(e1), tostring(r2), tostring(e2), tostring(w_rows),
      op and op.to[1].alias or "refused" }, "\n")
  ]=])
  local values = {}
  for line in result:gmatch("[^\n]+") do values[#values + 1] = line end
  T.eq(values[1], "nil", "an unidentified forward went through")
  T.ok(values[2]:find("unknown caller", 1, true), "unidentified forward did not report unknown caller")
  T.eq(values[3], "nil", "an unidentified reply went through")
  T.ok(values[4]:find("unknown caller", 1, true), "unidentified reply did not report unknown caller")
  T.eq(values[5], "0", "an unidentified caller delivered mail")
  T.eq(values[6], "butler", "the explicit operator could not reply")
end)
