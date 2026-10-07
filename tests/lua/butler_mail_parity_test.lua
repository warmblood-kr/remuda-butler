T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda.exec("butler"); remuda._b01_default_mail_config = remuda._butler_mail_config')

local function setup(tag, receiver)
  return string.format([=[
    local root = os.getenv("XDG_DATA_HOME") .. "/mail-b01-%s"
    for _, part in ipairs({"inboxes", "read", "messages", "objects"}) do remuda.mkdir(root .. "/" .. part) end
    remuda._mail_test_ulid = 0
    remuda._butler_new_ulid = function()
      remuda._mail_test_ulid = remuda._mail_test_ulid + 1
      return string.format("0000000000%%016X", remuda._mail_test_ulid)
    end
    remuda._butler_mail_config = {
      bus = { agents = { fixer = { id = %q } }, inboxes = {}, messages = {}, objects = {}, next = 0 },
      root = root, json_quote = function(value) return '"' .. value .. '"' end,
    }
    remuda.exec("butler/mail")
    local M = remuda._butler_mail
    local B = { host = "local", id = "01REP1YBUT1ER0000000000000", alias = "butler", session = "butler" }
    local F = { host = "local", id = %q, alias = "fixer", session = "fixer" }
    local W = { host = "local", id = "01REP1YW0RKER0000000000000", alias = "worker", session = "worker" }
    local function write(path, value)
      local ok, err = remuda.fs.write_atomic(path, value)
      assert(ok, tostring(err))
    end
    local function hex(id)
      return (id:gsub(".", function(c) return string.format("%%02x", c:byte()) end))
    end
    local function seed(id)
      write(root .. "/messages/message-a.json", '{"id":"message-a","from":{"host":"local","session":"old"},"subject":"Seeded A","body":{"object_id":"object-a"}}')
      write(root .. "/objects/object-a", "body of a")
      return root .. "/inboxes/" .. hex(id) .. ".jsonl", root .. "/read/" .. hex(id) .. ".jsonl"
    end
  ]=], tag, receiver, receiver)
end

T.test("butler_mail_torn_inbox_tail_does_not_swallow_the_next_delivery", function()
  local id = "01TORNTA1L000000000000000A"
  local result = T.eval(setup("torn", id) .. string.format([=[
    local inbox = seed("%s")
    write(inbox, '{"message_id":"message-a"}\n{"message_id":"message-to')
    local to = { host = "local", id = "%s", alias = "fixer", session = "fixer" }
    assert(M.queue("butler", to, "the new delivery"))
    remuda._butler_mail_config = {
      bus = { agents = {}, inboxes = {}, messages = {}, objects = {}, next = 0 }, root = root,
      json_quote = function(value) return '"' .. value .. '"' end,
    }
    remuda.exec("butler/mail")
    return remuda._butler_mail.inbox("%s")
  ]=], id, id, id))
  T.ok(result:find("body of a", 1, true), "the torn row's neighbour was lost: " .. result)
  T.ok(result:find("the new delivery", 1, true), "the delivery after a torn row was lost: " .. result)
end)

T.test("butler_mail_unloadable_envelope_stays_unread_and_is_reported", function()
  local id = "01UN10ADAB1E00000000000000"
  local result = T.eval(setup("unloadable", id) .. string.format([=[
    local inbox, read = seed("%s")
    write(root .. "/messages/message-corrupt.json", "{not json")
    write(inbox, '{"message_id":"message-a"}\n{"message_id":"message-missing"}\n{"message_id":"message-corrupt"}\n')
    local first = M.inbox("%s")
    local read_ids = assert(io.open(read, "rb")):read("*a")
    remuda._butler_mail_config = { bus = { agents = {}, inboxes = {}, messages = {}, objects = {}, next = 0 }, root = root,
      json_quote = function(value) return '"' .. value .. '"' end }
    remuda.exec("butler/mail")
    local again = remuda._butler_mail.inbox("%s")
    return first .. "\n--READ--\n" .. read_ids .. "\n--AGAIN--\n" .. again
  ]=], id, id, id))
  T.ok(result:find("body of a", 1, true), result)
  local first = result:match("^(.-)\n%-%-READ%-%-") or ""
  local read_ids = result:match("\n%-%-READ%-%-\n(.-)\n%-%-AGAIN%-%-") or ""
  local again = result:match("\n%-%-AGAIN%-%-\n(.*)$") or ""
  for _, bad in ipairs({"message-missing", "message-corrupt"}) do
    T.ok(first:find("message " .. bad .. ": envelope unreadable, left unread", 1, true), bad .. " was not reported")
    T.ok(not read_ids:find(bad, 1, true), bad .. " was marked read")
    T.ok(again:find("message " .. bad .. ": envelope unreadable", 1, true), bad .. " was not retried")
  end
  T.ok(read_ids:find("message-a", 1, true), "the shown message was not marked read")
  T.ok(not again:find("body of a", 1, true), "a read message came back")
end)

T.test("butler_mail_unreadable_envelope_is_retried_in_the_same_bus", function()
  local id = "01RETRYUNREADAB1E000000000"
  local result = T.eval(setup("retry", id) .. string.format([=[
    local inbox, read = seed("%s")
    write(inbox, '{"message_id":"message-late"}\n')
    local first = M.inbox("%s")
    local before = tostring(M.unread("%s"))
    write(root .. "/messages/message-late.json", '{"id":"message-late","from":{"host":"local","session":"slow"},"subject":"Late","body":{"object_id":"object-late"}}')
    write(root .. "/objects/object-late", "late body")
    local after = tostring(M.unread("%s"))
    local second = M.inbox("%s")
    local read_ids = assert(io.open(read, "rb")):read("*a")
    return first .. "\n--COUNTS--\n" .. before .. "|" .. after .. "\n--SECOND--\n" .. second .. "\n--READ--\n" .. read_ids
  ]=], id, id, id, id, id))
  local second = result:match("%-%-SECOND%-%-\n(.-)\n%-%-READ%-%-") or ""
  T.ok(result:find("message message-late: envelope unreadable, left unread", 1, true), result)
  T.ok(result:find("--COUNTS--\n0|1", 1, true), "an unreadable id is not counted, then becomes readable")
  T.ok(result:find("late body", 1, true), "the late envelope was not delivered")
  T.ok(not second:find("envelope unreadable", 1, true), second)
  T.ok(result:match("--READ--.-message%-late"), "the delivered id was not marked read")
end)

T.test("butler_mail_reply_threads_with_in_reply_to_and_references", function()
  local out = T.eval(setup("thread", "01REP1YF1XER00000000000000") .. [=[
    local a = assert(M.queue(B, F, "question"))
    local b = assert(M.reply(F, a.id, "answer"))
    local c = assert(M.reply(B, b.id, "thanks"))
    remuda.exec("butler/mail")
    local reloaded = remuda._butler_mail
    local d = assert(reloaded.reply(F, c.id, "after reload"))
    local envelope = assert(io.open(root .. "/messages/" .. c.id .. ".json", "rb")):read("*a")
    local d_envelope = assert(io.open(root .. "/messages/" .. d.id .. ".json", "rb")):read("*a")
    local fresh = reloaded.inbox(B.id)
    return table.concat({a.id, b.id, c.id, b.to[1].alias, c.to[1].alias, b.subject, c.subject,
      table.concat(c.references, ","), c.in_reply_to, envelope, fresh, table.concat(d.references, ","),
      d.in_reply_to, d_envelope}, "\n--PART--\n")
  ]=])
  local v = {}
  for part in (out .. "\n--PART--\n"):gmatch("(.-)\n%-%-PART%-%-\n") do v[#v + 1] = part end
  T.eq(v[4], "butler", "a reply goes to the parent's sender")
  T.eq(v[5], "fixer")
  T.eq(v[6], "Re: Message from butler")
  T.eq(v[7], "Re: Message from butler", "Re: is not doubled")
  T.eq(v[8], v[1] .. "," .. v[2], "references = parent's references + parent")
  T.eq(v[9], v[2])
  T.ok(v[10]:find('"in_reply_to":"' .. v[2] .. '"', 1, true), v[10])
  T.ok(v[10]:find('"references":["' .. v[1] .. '","' .. v[2] .. '"]', 1, true), v[10])
  T.ok(v[11]:find("  in reply to " .. v[2] .. " (thread " .. v[1] .. ")", 1, true), v[11])
  T.ok(v[11]:find("thanks", 1, true) and v[11]:find("question", 1, true), v[11])
  T.eq(v[12], v[1] .. "," .. v[2] .. "," .. v[3], "references load from the persisted parent envelope")
  T.eq(v[13], v[3], "in_reply_to loads from the persisted parent envelope")
  T.ok(v[14]:find('"in_reply_to":"' .. v[3] .. '"', 1, true), v[14])
  T.ok(v[14]:find('"references":["' .. v[1] .. '","' .. v[2] .. '","' .. v[3] .. '"]', 1, true), v[14])
end)

T.test("butler_mail_reply_tolerates_old_missing_and_self_referencing_parents", function()
  local out = T.eval(setup("jwz", "01REP1YF1XER00000000000000") .. [=[
    local inbox = seed(F.id)
    local from_b = '"from":{"host":"local","id":"' .. B.id .. '","alias":"butler","kind":"","leader":"","session":"butler"}'
    local rows = {
      {"message-old", ""}, {"message-orphan", ',"in_reply_to":"message-gone"'},
      {"message-selfref", ',"in_reply_to":"message-selfref","references":["message-selfref"]'},
      {"message-op", ""},
    }
    for _, row in ipairs(rows) do
      local from = row[1] == "message-op" and '"from":{"host":"local","id":"","alias":"operator","kind":"","leader":"","session":"operator"}' or from_b
      write(root .. "/messages/" .. row[1] .. ".json", '{"id":"' .. row[1] .. '",' .. from .. ',"subject":"S ' .. row[1] .. '"' .. row[2] .. ',"body":{"object_id":"object-a"}}')
    end
    write(inbox, '{"message_id":"message-old"}\n{"message_id":"message-orphan"}\n{"message_id":"message-selfref"}\n{"message_id":"message-op"}\n')
    local function refs(id) local m = assert(M.reply(F, id, "r")); return table.concat(m.references, ",") .. "|" .. m.to[1].alias end
    local _, not_mine = M.reply(B, "message-old", "x")
    local _, from_op = M.reply(F, "message-op", "x")
    local old, orphan, selfref = refs("message-old"), refs("message-orphan"), refs("message-selfref")
    remuda.exec("butler/mail")
    local b_view = remuda._butler_mail.inbox(B.id)
    return table.concat({old, orphan, selfref, tostring(not_mine), tostring(from_op), b_view}, "\n--PART--\n")
  ]=])
  local v = {}
  for part in (out .. "\n--PART--\n"):gmatch("(.-)\n%-%-PART%-%-\n") do v[#v + 1] = part end
  T.eq(v[1], "message-old|butler", "an old envelope is a thread root")
  T.eq(v[2], "message-gone,message-orphan|butler", "a missing parent still threads")
  T.eq(v[3], "message-selfref|butler", "a self-reference is dropped, never looped")
  T.ok(v[4]:find("not delivered", 1, true), "reply is only for mail delivered to you: " .. out)
  T.ok(v[5]:find("no Butler inbox", 1, true), "operator has no inbox to reply to: " .. out)
  T.ok(v[6]:find("in reply to message-orphan (thread message-gone)", 1, true), v[6])
end)

T.test("butler_mail_forward_redelivers_the_original_with_a_resent_row", function()
  local out = T.eval(setup("forward", "01REP1YF1XER00000000000000") .. [=[
    local a = assert(M.queue(B, F, "question"))
    local path = root .. "/messages/" .. a.id .. ".json"
    local before = assert(io.open(path, "rb")):read("*a")
    assert(M.forward(F, a.id, W, "see para 2"))
    local _, again = M.forward(F, a.id, W)
    local _, back = M.forward(W, a.id, F)
    local _, stranger = M.forward(W, "message-nope", B)
    local after = assert(io.open(path, "rb")):read("*a")
    local inbox = assert(io.open(root .. "/inboxes/" .. hex(W.id) .. ".jsonl", "rb")):read("*a")
    remuda.exec("butler/mail")
    local fresh = remuda._butler_mail.inbox(W.id)
    return table.concat({a.id, tostring(again), tostring(back), tostring(stranger), tostring(before == after), inbox, fresh}, "\n--PART--\n")
  ]=])
  local v = {}
  for part in (out .. "\n--PART--\n"):gmatch("(.-)\n%-%-PART%-%-\n") do v[#v + 1] = part end
  T.ok(v[2]:find("already delivered to worker", 1, true), "loop guard: " .. out)
  T.ok(v[3]:find("already delivered to fixer", 1, true), "loop guard back: " .. out)
  T.ok(v[4]:find("not delivered", 1, true), "only your own mail: " .. out)
  T.eq(v[5], "true", "the original envelope is never rewritten")
  T.ok(v[6]:find('"message_id":"' .. v[1] .. '","resent":{', 1, true) and v[6]:find("note_object_id", 1, true), v[6])
  T.ok(v[7]:find("[" .. v[1] .. " from local/butler ", 1, true), "original sender kept: " .. v[7])
  T.ok(v[7]:find("forwarded by fixer to worker at ", 1, true) and v[7]:find(": see para 2", 1, true), v[7])
  T.ok(v[7]:find("question", 1, true), "original body kept: " .. v[7])
end)

T.test("butler_mail_forwarded_read_state_is_per_inbox_and_replies_reach_the_original_sender", function()
  local out = T.eval(setup("forward-read", "01REP1YF1XER00000000000000") .. [=[
    local a = assert(M.queue(B, F, "question"))
    assert(M.forward(F, a.id, W))
    M.inbox(F.id)
    local w_unread = M.unread(W.id)
    local w_view = M.inbox(W.id)
    local f_again = M.inbox(F.id)
    local r = assert(M.reply(W, a.id, "answer from worker"))
    return table.concat({tostring(w_unread), tostring(w_view:find("question", 1, true) ~= nil), f_again,
      r.to[1].alias, r.in_reply_to == a.id and "threaded" or "not"}, "\n")
  ]=])
  local v = {}; for line in out:gmatch("[^\n]+") do v[#v + 1] = line end
  T.eq(v[1], "1", "the forwarder reading it leaves the target unread")
  T.eq(v[2], "true", "the target still sees it")
  T.eq(v[3], "inbox empty", "the target reading it does not re-open the forwarder's copy")
  T.eq(v[4], "butler", "a reply to forwarded mail goes to the original sender")
  T.eq(v[5], "threaded")
end)

T.test("butler_mail_refuses_to_overwrite_an_existing_message_on_an_id_collision", function()
  local id = "00000000000000000000000000"
  local out = T.eval(setup("collision", "01REP1YF1XER00000000000000") .. string.format([=[
    local inbox = seed(F.id)
    write(root .. "/messages/%s.json", "ORIGINAL")
    remuda._butler_new_ulid = function() return "%s" end
    local ok, message, err = pcall(M.queue, B, F, "second")
    local original = assert(io.open(root .. "/messages/%s.json", "rb")):read("*a")
    local row_file = io.open(inbox, "rb")
    local rows = row_file and row_file:read("*a") or ""
    if row_file then row_file:close() end
    return tostring(ok) .. "|" .. tostring(message) .. "|" .. tostring(err) .. "|" .. original .. "|" .. tostring(rows:find("%s", 1, true) ~= nil)
  ]=], id, id, id, id))
  T.ok(out:find("true|nil|", 1, true) == 1 and out:find("already exists", 1, true), "not refused loudly: " .. out)
  T.ok(out:find("|ORIGINAL|false", 1, true), "existing data changed or a row was committed: " .. out)
end)

T.test("butler_mail_survives_a_fresh_lua_mailbox_and_remembers_reads", function()
  local out = T.eval(setup("reload", "01FIXER") .. [=[
    local a = assert(M.queue("butler", "fixer", "survives a restart"))
    remuda._butler_mail_config = { bus = { agents = { fixer = { id = "01FIXER" } }, inboxes = {}, messages = {}, objects = {}, next = 0 },
      root = root, json_quote = function(value) return '"' .. value .. '"' end }
    remuda.exec("butler/mail")
    local received = remuda._butler_mail.inbox("01FIXER")
    remuda._butler_mail_config = { bus = { agents = { fixer = { id = "01FIXER" } }, inboxes = {}, messages = {}, objects = {}, next = 0 },
      root = root, json_quote = function(value) return '"' .. value .. '"' end }
    remuda.exec("butler/mail")
    return a.id .. "\n--RECEIVED--\n" .. received .. "\n--AFTER--\n" .. remuda._butler_mail.inbox("01FIXER")
  ]=])
  T.ok(out:find("survives a restart", 1, true), out)
  T.ok(out:match("\n%-%-AFTER%-%-\ninbox empty$"), out)
end)

T.test("butler_initializes_mail_and_persists_a_sent_message", function()
  local out = T.eval([=[
    remuda._butler_mail_config = remuda._b01_default_mail_config
    remuda.exec("butler/mail")
    local sent = remuda._butler_send("butler", "butler", "private body")
    local id = sent:match("^queued ([^ ]+)") or ""
    local mail = os.getenv("XDG_DATA_HOME") .. "/remuda/butler/mail"
    local objects = assert(remuda.list_dir(mail .. "/objects"))
    local envelopes = assert(remuda.list_dir(mail .. "/messages"))
    local inboxes = assert(remuda.list_dir(mail .. "/inboxes"))
    local object = assert(io.open(mail .. "/objects/" .. objects[1], "rb")):read("*a")
    local envelope = assert(io.open(mail .. "/messages/" .. envelopes[1], "rb")):read("*a")
    return sent .. "\n--COUNTS--\n" .. #objects .. "|" .. #envelopes .. "|" .. #inboxes .. "\n--ID--\n" .. id
      .. "\n--OBJECT--\n" .. object .. "\n--ENVELOPE--\n" .. envelope
  ]=])
  local sent = out:match("^(.-)\n%-%-COUNTS%-%-")
  T.ok(sent, out)
  local id = out:match("%-%-ID%-%-\n([^\n]+)") or ""
  T.ok(#id == 26 and id:match("^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]+$"), out)
  T.ok(sent:find("notice deferred", 1, true) or sent:match(" and notified butler$"), sent)
  T.eq(out:match("%-%-COUNTS%-%-\n([^\n]+)"), "1|1|1")
  T.ok(out:match("%-%-OBJECT%-%-\nprivate body"), out)
  T.ok(out:find('"body":{"object_id":"object%-', 1, false), out)
end)

T.test("an_ended_aliases_unread_mail_is_readable_by_alias", function()
  local out = T.eval([=[
    remuda._butler_agent_builders.fake = function() return {"sleep", "100"} end
    remuda._butler_launch("fake", "lead1")
    remuda._butler_send("operator", "lead1", "unread-after-end")
    remuda.emit("session_exited", "lead1")
    local inbox = remuda._butler_inbox("lead1")
    local ok, err = pcall(remuda._butler_inbox, "nobody")
    return inbox .. "\n--UNKNOWN--\n" .. tostring(ok) .. "|" .. tostring(err)
  ]=])
  T.ok(out:find("unread-after-end", 1, true), out)
  local unknown = out:match("%-%-UNKNOWN%-%-\n(.*)$") or ""
  T.ok(unknown:match("^false|"), unknown)
end)

T.test("inbox_id_opens_only_the_callers_own_messages", function()
  local out = T.eval([=[
    remuda.butler.project_home(os.getenv("XDG_DATA_HOME") .. "/projects")
    remuda._butler_agent_builders.codex = function() return {"sleep", "100"} end
    remuda._butler_launch("codex", "cx1")
    local foreign = remuda._butler_send("operator", "butler", "root only"):match("^queued (%S+)")
    local agent = remuda._butler_bus.agents.cx1
    local ok, refused = pcall(remuda._butler_command_run, "inbox", {"inbox", foreign},
      { env = { REMUDA_BUTLER_AGENT_ID = agent.id } })
    refused = tostring(refused)
    local help = tostring(remuda._butler_command_run("inbox", {"inbox", "--help"}, { env = {} }))
    return table.concat({tostring(refused:find("root only", 1, true) == nil), tostring(refused:find("Next:", 1, true) ~= nil),
      tostring(help:find("message-id", 1, true) ~= nil)}, "|")
  ]=])
  T.eq(out, "true|true|true", "inbox ID owner check and help")
end)
