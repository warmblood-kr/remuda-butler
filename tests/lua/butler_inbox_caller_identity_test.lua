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
  local env = agent_id and string.format("{ REMUDA_BUTLER_AGENT_ID = %q }", agent_id) or "{}"
  return T.eval([[
    local ok, value = pcall(remuda._butler_command_run, ]] .. string.format("%q", verb)
    .. ", { " .. table.concat(encoded, ", ") .. " }, { env = " .. env .. [[ })
    return (ok and "ok\0" or "error\0") .. tostring(value)
  ]])
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
end)

T.test("ended_member_still_reads_its_own_mail_by_alias_and_a_reused_alias_is_not_its_own", function()
  local ids = T.eval([[
    local bus = remuda._butler_bus
    remuda._butler_launch("codex", "dave")
    local old = bus.agents.dave.id
    remuda._butler_send("butler", "dave", "dave private note")
    bus.agents.dave = nil -- the session ended; identity records stay
    return old
  ]])
  local old_id = ids:match("%S+")
  for _, args in ipairs({ { "inbox", "dave" }, { "inbox" }, { "inbox", old_id } }) do
    local result = call("inbox", args, old_id)
    T.ok(result:match("^ok\0"), "an ended member reads its own inbox (" .. (args[2] or "no-arg") .. "): " .. result)
    if args[2] == "dave" then
      T.ok(result:find("dave private note", 1, true), "own mail shown by alias: " .. result)
    end
  end
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
  T.eq(T.eval("return tostring(remuda._butler_mail.is_unread(" .. string.format("%q", bob_id)
    .. ", " .. string.format("%q", unread_message) .. "))"), "true", "not-yours lookup leaves mail unread")

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
