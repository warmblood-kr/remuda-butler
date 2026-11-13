-- A named inbox may only be read by its owner when the caller has an agent identity.
-- Agent names and IDs are both accepted by the operator path.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_launch("codex", "alice")
  remuda._butler_launch("codex", "bob")
  remuda._butler_launch("codex", "carol")
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

local function call(verb, args, agent_id)
  local encoded = {}
  for _, value in ipairs(args) do encoded[#encoded + 1] = string.format("%q", value) end
  local session = agent_id and T.eval("for _, a in pairs(remuda._butler_bus.agents) do if a.id == "
    .. string.format("%q", agent_id) .. " then return a.session_name end end")
  local caller = session and string.format("{ kind = 'session', session = %q, instance_id = _inst(%q) }", session, session)
    or (agent_id and "{ kind = 'session', session = 'unregistered' }" or "{ kind = 'outside' }")
  return T.eval([[
    local ok, value = pcall(remuda._butler_command_run, ]] .. string.format("%q", verb)
    .. ", { " .. table.concat(encoded, ", ") .. " }, " .. caller .. [[)
    return (ok and "ok\0" or "error\0") .. tostring(value)
  ]])
end

local function unread(agent_id, message_id)
  return T.eval("return tostring(remuda._butler_mail.is_unread(" .. string.format("%q", agent_id)
    .. ", " .. string.format("%q", message_id) .. "))")
end

local function intent_state(agent_id, message_id)
  return T.eval(string.format([=[
    local simple = assert(remuda._butler_simple_inbox, "SQLite inbox is not active")
    local function hex(value)
      return (value:gsub(".", function(byte) return string.format("%%02x", string.byte(byte)) end))
    end
    local rows = assert(simple.db:query(
      "SELECT status,deferred_at FROM read_receipt_intents WHERE recipient = ? AND message_id = ?",
      { hex(%q), %q }))
    if #rows == 0 then return "none" end
    return tostring(rows[1].status) .. "|" .. tostring(rows[1].deferred_at)
  ]=], agent_id, message_id))
end

local function receipt_count(agent_id, original_id)
  return T.eval(string.format([=[
    local simple = assert(remuda._butler_simple_inbox, "SQLite inbox is not active")
    local function hex(value)
      return (value:gsub(".", function(byte) return string.format("%%02x", string.byte(byte)) end))
    end
    local rows = assert(simple.db:query(
      "SELECT envelope FROM simple_inbox WHERE recipient = ?", { hex(%q) }))
    local found = 0
    for _, row in ipairs(rows) do
      if row.envelope:find('"receipt_of":"' .. %q .. '"', 1, true) then found = found + 1 end
    end
    return tostring(found)
  ]=], agent_id, original_id))
end

local setup = T.eval([[
  local bus, mail = remuda._butler_bus, remuda._butler_mail
  local ids = { alice = bus.agents.alice.id, bob = bus.agents.bob.id, carol = bus.agents.carol.id }
  local own = remuda._butler_send("butler", "alice", "alice private message")
  local bob_message = remuda._butler_send("butler", "bob", "bob private secret")
  return ids.alice .. "\n" .. ids.bob .. "\n" .. ids.carol .. "\n"
    .. own:match("^queued (%S+)") .. "\n" .. bob_message:match("^queued (%S+)")
]])
local alice_id, bob_id, carol_id, alice_message, bob_message = setup:match("([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]+)")
assert(alice_id and bob_id and carol_id and alice_message and bob_message, "agent/mail setup failed")

T.test("named_inbox_refuses_another_agents_alias_and_id_without_marking_mail_read", function()
  for _, name in ipairs({ "bob", bob_id }) do
    local result = call("inbox", { "inbox", name }, alice_id)
    T.ok(result:match("^error\0"), "cross-member inbox must be refused: " .. result)
    T.ok(not result:find("bob private secret", 1, true), "refusal leaked mail content: " .. result)
    T.eq(T.eval("return tostring(remuda._butler_mail.is_unread(" .. string.format("%q", bob_id)
      .. ", " .. string.format("%q", bob_message) .. "))"), "true", "Bob's mail stays unread")
  end
end)

T.test("named_inbox_refusal_does_not_reveal_whether_the_member_has_mail", function()
  local absent_id = "00000000000000000000000000"
  local results = {
    call("inbox", { "inbox", "bob" }, alice_id),
    call("inbox", { "inbox", "carol" }, alice_id),
    call("inbox", { "inbox", "absent-member" }, alice_id),
    call("inbox", { "inbox", absent_id }, alice_id),
  }
  local refusal = results[1]:match("^error\0(.*)$")
  T.ok(refusal, "cross-member inbox must be refused: " .. results[1])
  for index, result in ipairs(results) do
    T.eq(result:match("^error\0(.*)$"), refusal, "same refusal regardless of target existence (case " .. index .. ")")
  end
  T.eq(T.eval("return tostring(remuda._butler_mail.is_unread(" .. string.format("%q", bob_id)
    .. ", " .. string.format("%q", bob_message) .. "))"), "true", "all refused lookups leave Bob's mail unread")
end)

T.test("agent_can_read_own_named_inbox_and_operator_can_read_any_named_inbox", function()
  local implicit_own = call("inbox", { "inbox" }, alice_id)
  T.ok(implicit_own:match("^ok\0") and implicit_own:find("alice private message", 1, true),
    "no-argument inbox should use the caller identity: " .. implicit_own)
  local own = call("inbox", { "inbox", "alice" }, alice_id)
  T.ok(own:match("^ok\0"), "own inbox should work: " .. own)

  local operator_message = T.eval([[return remuda._butler_send("butler", "bob", "operator-visible secret"):match("^queued (%S+)")]])
  local operator = call("inbox", { "inbox", "bob" })
  T.ok(operator:match("^ok\0"), "operator inbox should work: " .. operator)
  T.ok(operator:find("operator-visible secret", 1, true), "operator inbox content missing")
  T.eq(T.eval("return tostring(remuda._butler_mail.is_unread(" .. string.format("%q", bob_id)
    .. ", " .. string.format("%q", operator_message) .. "))"), "false", "operator read marks mail read")

  -- Caller provenance: Alice's own read creates one intent; the operator's
  -- read of Bob's inbox saves read state but creates no agent receipt intent.
  local provenance = T.eval(string.format([=[
    local simple = assert(remuda._butler_simple_inbox, "SQLite inbox is not active")
    local function hex(value)
      return (value:gsub(".", function(byte) return string.format("%%02x", string.byte(byte)) end))
    end
    local alice = assert(simple.db:query(
      "SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { hex(%q) }))
    local bob = assert(simple.db:query(
      "SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { hex(%q) }))
    local found = false
    for _, row in ipairs(alice) do
      if row.message_id == %q then found = true end
    end
    return tostring(#alice > 0) .. "|" .. #bob .. "|" .. tostring(found)
  ]=], alice_id, bob_id, alice_message))
  T.eq(provenance, "true|0|true", "only the agent's own read should create an intent")
end)

T.test("message_id_lookup_reads_only_that_message_and_creates_one_receipt", function()
  local butler_id = T.eval("return remuda._butler_bus.agents.butler.id")
  local setup = T.eval([[
    local probe = remuda._butler_send("butler", "alice", "single lookup probe"):match("^queued (%S+)")
    local other = remuda._butler_send("butler", "alice", "single lookup other"):match("^queued (%S+)")
    return probe .. "\n" .. other
  ]])
  local probe, other = setup:match("([^\n]+)\n([^\n]+)")
  local result = call("inbox", { "inbox", probe }, alice_id)
  T.ok(result:match("^ok\0") and result:find("single lookup probe", 1, true),
    "single-message lookup did not display the message: " .. result)
  T.eq(unread(alice_id, probe), "false", "single-message lookup must mark that message read")
  T.eq(unread(alice_id, other), "true", "single-message lookup must not read another message")
  T.eq(intent_state(alice_id, probe), "delivered|nil",
    "single-message read must create and deliver one intent")
  T.eq(receipt_count(butler_id, probe), "1",
    "single-message read must deliver one local receipt")

  local again = call("inbox", { "inbox", probe }, alice_id)
  T.ok(again:match("^ok\0") and again:find("single lookup probe", 1, true),
    "re-view did not display the read message: " .. again)
  T.eq(intent_state(alice_id, probe), "delivered|nil", "re-view must not duplicate the intent")
  T.eq(receipt_count(butler_id, probe), "1", "re-view must not duplicate the receipt")
end)

T.test("message_id_lookup_sqlite_failure_leaves_mail_unread_and_retries", function()
  local butler_id = T.eval("return remuda._butler_bus.agents.butler.id")
  local id = T.eval([[return remuda._butler_send("butler", "alice", "sqlite failure probe"):match("^queued (%S+)")]])
  local session = T.eval("for _, a in pairs(remuda._butler_bus.agents) do if a.id == "
    .. string.format("%q", alice_id) .. " then return a.session_name end end")
  local failed = T.eval(string.format([=[
    local simple = assert(remuda._butler_simple_inbox, "SQLite inbox is not active")
    local real = simple.store.mark_read
    simple.store.mark_read = function() return nil, "synthetic mark_read failure" end
    local ok, value = pcall(remuda._butler_command_run, "inbox", { "inbox", %q },
      { kind = "session", session = %q, instance_id = _inst(%q) })
    simple.store.mark_read = real
    return (ok and "ok\0" or "error\0") .. tostring(value)
  ]=], id, session, session))
  T.ok(failed:find("mail read-state was not saved", 1, true),
    "a failed SQLite read must be reported: " .. failed)
  T.eq(unread(alice_id, id), "true", "a failed SQLite read must leave the message unread")
  T.eq(intent_state(alice_id, id), "none", "a failed SQLite read must create no intent")
  local retried = call("inbox", { "inbox", id }, alice_id)
  T.ok(retried:match("^ok\0") and retried:find("sqlite failure probe", 1, true),
    "retry after a SQLite failure did not read the message: " .. retried)
  T.eq(unread(alice_id, id), "false", "the retry must mark the message read")
  T.eq(intent_state(alice_id, id), "delivered|nil", "the retry must create and deliver one intent")
  T.eq(receipt_count(butler_id, id), "1", "the retry must deliver one local receipt")
end)

T.test("message_id_lookup_creates_a_deferred_matrix_intent", function()
  local id = T.eval(string.format([=[
    local mail = remuda._butler_mail
    local message = assert(mail.queue(
      { host = "matrix", id = "", alias = "@alice:example.org",
        session = "@alice:example.org", kind = "matrix", leader = "" },
      { host = "local", id = %q, alias = "alice", session = "alice", kind = "codex", leader = "" },
      "matrix single probe", "Matrix message", nil, nil,
      { sender = "@alice:example.org", room_id = "!room:example.org", event_id = "$single" }))
    return message.id
  ]=], alice_id))
  local result = call("inbox", { "inbox", id }, alice_id)
  T.ok(result:match("^ok\0") and result:find("matrix single probe", 1, true),
    "Matrix single-message lookup did not display the message: " .. result)
  local state = intent_state(alice_id, id)
  T.ok(state:match("^pending|%d%d%d%d"),
    "Matrix single-message read must leave a deferred intent: " .. state)
end)

T.test("ended_member_session_is_unidentified_and_alias_reuse_does_not_restore_it", function()
  local ids = T.eval([[
    local bus = remuda._butler_bus
    remuda._butler_launch("codex", "dave")
    local old = bus.agents.dave.id
    remuda._butler_send("butler", "dave", "dave private note")
    bus.agents.dave = nil -- the session ended; identity records stay
    return old
  ]])
  local old_id = ids:match("%S+")
  local ended = call("inbox", { "inbox", "dave" }, old_id)
  T.ok(ended:match("^error\0") and ended:find("Next:", 1, true),
    "an ended session is unidentified and cannot read its inbox: " .. ended)
  T.eval([[
    -- the alias is taken again by a new holder with another id
    remuda._butler_bus.agents.dave = { id = "01ZZZZZZZZZZZZZZZZZZZZZZZZ", alias = "dave", session_name = "dave-new",
      children = {}, kind = "codex" }
  ]])
  local reused = call("inbox", { "inbox", "dave" }, old_id)
  T.ok(reused:match("^error\0") and not reused:find("dave private note", 1, true),
    "the old identity must not read the new holder of its alias: " .. reused)
  T.eval([[
    -- the new holder also ends: the alias now resolves to the new id, still not the old identity's
    local bus = remuda._butler_bus
    bus.agents.dave = nil
    bus.identities.dave = { id = "01ZZZZZZZZZZZZZZZZZZZZZZZZ", alias = "dave" }
    ]])
  local ended_reused = call("inbox", { "inbox", "dave" }, old_id)
  T.ok(ended_reused:match("^error\0") and not ended_reused:find("dave private note", 1, true),
    "an ended replacement holder's alias is not the old identity's: " .. ended_reused)
end)

T.test("message_id_branch_keeps_owner_not_found_and_not_yours_checks", function()
  local unread_message = T.eval([[return remuda._butler_send("butler", "bob", "unread ownership probe"):match("^queued (%S+)")]])
  local not_yours = call("inbox", { "inbox", unread_message }, alice_id)
  T.ok(not_yours:match("^error\0"), "another agent's message ID must be refused")
  T.ok(not_yours:find("was not delivered to you", 1, true), "not-yours reason missing: " .. not_yours)
  T.eq(unread(bob_id, unread_message), "true", "not-yours lookup leaves mail unread")
  T.eq(intent_state(alice_id, unread_message), "none", "a refused lookup must create no intent")
  T.eq(intent_state(bob_id, unread_message), "none", "a refused lookup must not create the owner's intent")

  local missing = call("inbox", { "inbox", "00000000000000000000000000" }, alice_id)
  T.ok(missing:match("^error\0"), "unknown message ID must remain an error")
  T.ok(missing:find("agents may only read their own Butler inbox", 1, true), "unresolved ULID refusal changed: " .. missing)
  T.ok(not missing:find("bob private secret", 1, true), "not-found lookup leaked mail")
end)

-- Sibling verb probe: sessions/status/quota have no NAME argument; send accepts a
-- destination but performs a write; reply and forward identify source mail by ID and
-- retain the mail ownership checks. These cases document their separate semantics.
T.test("sibling_name_verbs_do_not_read_another_members_private_inbox", function()
  local private_id = T.eval([[return remuda._butler_send("butler", "bob", "sibling private probe"):match("^queued (%S+)")]])
  for _, probe in ipairs({
    { verb = "sessions", args = { "sessions", "bob" } },
    { verb = "status", args = { "status", "bob" } },
    { verb = "quota", args = { "quota", "bob" } },
  }) do
    local result = call(probe.verb, probe.args, alice_id)
    T.ok(not result:find("sibling private probe", 1, true), probe.verb .. " exposed private mail")
    T.eq(T.eval("return tostring(remuda._butler_mail.is_unread(" .. string.format("%q", bob_id)
      .. ", " .. string.format("%q", private_id) .. "))"), "true", probe.verb .. " left mail unread")
  end

  local send = call("send", { "send", "bob", "sibling write probe" }, alice_id)
  T.ok(send:match("^ok\0"), "agent send to a named recipient remains available: " .. send)
  T.ok(not send:find("bob private secret", 1, true), "send exposed the recipient's existing mail")

  local reply = call("reply", { "reply", bob_message, "reply probe" }, alice_id)
  T.ok(reply:match("^error\0") and reply:find("was not delivered to you", 1, true), "reply keeps message ownership: " .. reply)
  local forward = call("forward", { "forward", bob_message, "carol" }, alice_id)
  T.ok(forward:match("^error\0") and forward:find("was not delivered to you", 1, true), "forward keeps message ownership: " .. forward)
end)

-- The legacy one-argument API (used by the retained Rust CLI shim) has no
-- daemon caller-session identity. It must save read state but never claim an
-- agent read, so it creates no receipt intent.
T.test("legacy_one_argument_inbox_reads_without_claiming_an_agent_read", function()
  local id = T.eval([[return remuda._butler_send("butler", "carol", "legacy shim probe"):match("^queued (%S+)")]])
  local text = T.eval([[return remuda._butler_inbox("carol")]])
  T.ok(text:find("legacy shim probe", 1, true), "legacy one-argument read did not show mail")
  T.eq(T.eval("return tostring(remuda._butler_mail.is_unread(" .. string.format("%q", carol_id)
    .. ", " .. string.format("%q", id) .. "))"), "false", "legacy one-argument read did not save read state")
  local intents = T.eval(string.format([=[
    local simple = assert(remuda._butler_simple_inbox, "SQLite inbox is not active")
    local function hex(value)
      return (value:gsub(".", function(byte) return string.format("%%02x", string.byte(byte)) end))
    end
    local rows = assert(simple.db:query(
      "SELECT message_id FROM read_receipt_intents WHERE recipient = ?", { hex(%q) }))
    return tostring(#rows)
  ]=], carol_id))
  T.eq(intents, "0", "legacy one-argument read claimed an agent receipt")
end)

-- A forwarded mail's stored envelope still names the original `to` alias. The
-- receipt must name the member that actually read the copy, resolved by the
-- durable reader ULID.
T.test("read_receipt_for_forwarded_mail_names_the_actual_reader", function()
  local ids = T.eval([[
    local bus = remuda._butler_bus
    local sent = assert(remuda._butler_send("butler", "bob", "forwarded receipt source"))
    local original = assert(sent:match("^queued (%S+)"))
    local forwarded = assert(remuda._butler_forward("operator", original, "carol", "forward note"))
    assert(forwarded, "forward failed")
    local text = assert(remuda._butler_inbox("carol", bus.agents.carol.id))
    assert(text:find("forwarded receipt source", 1, true), "carol did not read the forwarded mail")
    return original .. "\n" .. bus.agents.butler.id .. "\n" .. bus.agents.carol.id
  ]])
  local original, butler_id, carol_id = ids:match("([^\n]+)\n([^\n]+)\n([^\n]+)")
  assert(original and butler_id and carol_id, "forwarded receipt setup failed: " .. tostring(ids))
  local found = T.eval(string.format([=[
    local simple = assert(remuda._butler_simple_inbox)
    local function hex(value)
      return (value:gsub(".", function(byte) return string.format("%%02x", string.byte(byte)) end))
    end
    local rows = assert(simple.db:query(
      "SELECT message_id, envelope FROM simple_inbox WHERE recipient = ? ORDER BY seq", { hex(%q) }))
    for _, row in ipairs(rows) do
      if row.envelope:find('"receipt_of":"' .. %q .. '"', 1, true) then
        local from = row.envelope:match('"from":(%%b{})') or ""
        return from
      end
    end
    return "missing"
  ]=], butler_id, original))
  T.ok(found ~= "missing", "forwarded-mail receipt was not delivered to the original sender")
  T.ok(found:find('"id":"' .. carol_id .. '"', 1, true), "receipt does not use the reader ULID: " .. found)
  T.ok(found:find('"alias":"carol"', 1, true), "receipt names the envelope to alias, not the reader: " .. found)
  T.ok(not found:find('"alias":"bob"', 1, true), "receipt named the original to alias: " .. found)
end)

-- A renamed/reused display alias must not redirect a receipt notice. The
-- adapter validates by the durable recipient ULID; a stale alias is ignored.
T.test("read_receipt_notice_is_keyed_by_durable_id_not_reused_alias", function()
  local out = T.eval([=[
    local bus = remuda._butler_bus
    local mail = remuda._butler_mail
    local adapter = assert(remuda._butler_read_receipts_config.notify)
    local alice = assert(bus.agents.alice)
    local alice_id = alice.id
    local bob_id = assert(bus.agents.bob).id
    local function address(id, alias)
      return { host = "local", id = id, alias = alias, session = alias, kind = "codex", leader = "" }
    end
    local sender = address(alice_id, "alice")
    local reader = address(bob_id, "bob")
    local function receipt(text)
      return assert(mail.queue(reader, sender, text, "Read receipt"))
    end
    remuda._butler_done = remuda._butler_done or {}
    remuda._butler_done.alice = { id = alice_id }
    local first = receipt("Read receipt: bob fetched one")
    adapter(first, sender)
    local seen_first = bus.notice_seen[alice_id] and bus.notice_seen[alice_id][first.id] == true
    local done_first = remuda._butler_done.alice == nil

    bus.agents.alice = nil
    alice.alias, alice.session_name = "alice-new", "alice-new"
    bus.agents["alice-new"] = alice
    bus.identity_ids[alice_id].alias = "alice-new"
    local other_id = "01ZZZZZZZZZZZZZZZZZZZZZZZZ"
    bus.agents.alice = { id = other_id, alias = "alice", session_name = "alice", kind = "codex" }
    remuda._butler_done["alice-new"] = { id = alice_id }
    remuda._butler_done.alice = { id = other_id }
    local stale = address(alice_id, "alice")
    local second = receipt("Read receipt: bob fetched two")
    adapter(second, stale)
    local seen_renamed = bus.notice_seen[alice_id] and bus.notice_seen[alice_id][second.id] == true
    local other_seen = bus.notice_seen[other_id]
    local done_renamed = remuda._butler_done["alice-new"] == nil
    local done_other = remuda._butler_done.alice ~= nil

    bus.agents["alice-new"] = nil
    local third = receipt("Read receipt: bob fetched three")
    adapter(third, stale)
    local ended_seen = bus.notice_seen[alice_id] and bus.notice_seen[alice_id][third.id] == true
    local done_other_after = remuda._butler_done.alice ~= nil
    return table.concat({ tostring(seen_first), tostring(done_first), tostring(seen_renamed),
      tostring(other_seen == nil), tostring(done_renamed), tostring(done_other),
      tostring(not ended_seen), tostring(done_other_after) }, "|")
  ]=])
  T.eq(out, "true|true|true|true|true|true|true|true",
    "receipt notice must resolve the current target by durable id: " .. tostring(out))
end)
