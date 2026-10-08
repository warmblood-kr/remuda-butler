T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "60" } end
  remuda._butler_launch("codex", "reused")
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

T.test("a_capability_from_an_ended_member_does_not_resolve_to_an_alias_replacement", function()
  local previous = T.eval([[
    local agent = remuda._butler_bus.agents.reused
    remuda._butler_bus.tokens[agent.token] = "reused" -- a live row carried over from an alias-valued image
    return agent.id .. "\n" .. agent.token .. "\n"
      .. remuda._butler_identity.caller_name({ env = {}, capability = agent.token })
  ]])
  local old_id, old_token, first_name = previous:match("([^\n]+)\n([^\n]+)\n([^\n]+)")
  T.ok(old_id and old_token, "the first launch did not record its identity and capability")
  T.eq(first_name, "reused", "the live capability did not resolve to its member")

  T.eval('return remuda.close("reused")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus.agents.reused == nil'):match("^%s*true%s*$") ~= nil
  end, 5, "first member exit")
  T.eval('return remuda._butler_launch("codex", "reused")')

  local replacement = T.eval([[
    local agent = remuda._butler_bus.agents.reused
    return agent.id .. "\n" .. agent.token .. "\n"
      .. tostring(remuda._butler_identity.caller_name({ env = {}, capability = ]] .. string.format("%q", old_token) .. [[ }))
  ]])
  local new_id, new_token, stale_name = replacement:match("([^\n]+)\n([^\n]+)\n([^\n]+)")
  T.ok(new_id and new_token and new_id ~= old_id and new_token ~= old_token,
    "alias reuse did not create a new identity and capability")
  T.eq(stale_name, "nil", "the ended member's capability resolved to the replacement")

  local refused = T.eval([[
    local bus = remuda._butler_bus
    local function snapshot()
      local messages, inboxes = 0, 0
      for _ in pairs(bus.messages) do messages = messages + 1 end
      for _, rows in pairs(bus.inboxes) do inboxes = inboxes + #rows end
      return messages .. ":" .. inboxes
    end
    local before = snapshot()
    local ok = pcall(remuda._butler_identity.caller_agent,
      { env = {}, capability = ]] .. string.format("%q", old_token) .. [[ })
    return tostring(not ok) .. ":" .. tostring(before == snapshot())
  ]])
  T.eq(refused, "true:true", "a refused stale capability must have no mailbox effects")
  local native = T.eval([[
    local cap = ]] .. string.format("%q", new_token) .. [[
    local identity = remuda._butler_identity
    return table.concat({ tostring(identity.caller_name({ kind = "unknown", capability = cap })),
      tostring(identity.caller_name({ kind = "service", capability = cap })),
      tostring(identity.caller_name({ kind = "session", session = "unregistered", capability = cap })),
      tostring(identity.caller_name({ kind = "session", env = { REMUDA_BUTLER_AGENT_ID = "reused" }, capability = cap })) }, ":")
  ]])
  T.eq(native, "nil:nil:nil:nil",
    "capabilities and environment ids must not override a native unknown, service, or unregistered caller")

  local message_id = T.eval([[
    return remuda._butler_send("butler", "reused", "replacement private message"):match("^queued (%S+)")
  ]])
  T.eval([[
    remuda.tool { name = "butler_test_caller_probe", about = "Report the caller shape for a transport regression.", run = function(_, caller)
      return table.concat({ tostring(caller and caller.kind), tostring(caller and caller.session),
        tostring(caller and caller.capability) }, ":")
    end }
  ]])
  local observed = T.mcp_call("butler_test_caller_probe", {}, old_token)
  local caller_shape = observed.result and observed.result.content and observed.result.content[1].text or ""
  T.eq(caller_shape, "nil:nil:" .. old_token,
    "the actual MCP bridge sends only its saved capability after the member exits")
  local before = T.eval([[
    local bus = remuda._butler_bus
    local messages, inboxes = 0, 0
    for _ in pairs(bus.messages) do messages = messages + 1 end
    for _, rows in pairs(bus.inboxes) do inboxes = inboxes + #rows end
    return messages .. ":" .. inboxes
  ]])
  local reply = T.mcp_call("butler_forward", { message_id = message_id, to = "butler" }, old_token)
  local transport = reply.result and reply.result.content and reply.result.content[1].text
    or reply.error and reply.error.message or "MCP returned no content"
  T.ok(transport:find("unknown caller", 1, true) ~= nil,
    "an MCP bridge retaining only the ended capability must be refused: " .. transport)
  local after = T.eval([[
    local bus = remuda._butler_bus
    local messages, inboxes = 0, 0
    for _ in pairs(bus.messages) do messages = messages + 1 end
    for _, rows in pairs(bus.inboxes) do inboxes = inboxes + #rows end
    return messages .. ":" .. inboxes
  ]])
  T.eq(after, before, "refusing the ended bridge must not forward or deliver any mail")
end)

T.test("unidentified_MCP_callers_cannot_mutate_mail_or_register_approvals", function()
  T.eval([[
    local feature = remuda.butler.approve_text
    feature._test_original_request = feature.request
    feature._test_original_allowed = feature.target_session_allowed
    feature._test_request_count = 0
    feature.target_session_allowed = function() return true end
    feature.request = function()
      feature._test_request_count = feature._test_request_count + 1
      return "should-not-be-called"
    end
    remuda._butler_inbox_original = remuda._butler_inbox
    remuda._butler_inbox_calls = 0
    remuda._butler_inbox = function()
      remuda._butler_inbox_calls = remuda._butler_inbox_calls + 1
      return "should-not-be-read"
    end
  ]])
  local function snapshot()
    return T.eval([[
      local bus = remuda._butler_bus
      local messages, objects, deliveries = 0, 0, 0
      for _ in pairs(bus.messages) do messages = messages + 1 end
      for _ in pairs(bus.objects) do objects = objects + 1 end
      for _, rows in pairs(bus.mail_delivered) do
        for _ in pairs(rows) do deliveries = deliveries + 1 end
      end
      return table.concat({ tostring(bus.next), tostring(messages), tostring(objects), tostring(deliveries),
        tostring(remuda.butler.approve_text._test_request_count), tostring(remuda._butler_inbox_calls) }, ":")
    ]])
  end
  -- A live member legally named like the old failure sentinel must not authorize failures.
  T.eval([[local bus = remuda._butler_bus
    bus.agents.outside = { id = "OUTSIDE", alias = "outside", session_name = "outside-s", session_start_marker = "M" }
    bus.identity_ids.OUTSIDE = { id = "OUTSIDE", alias = "outside", state = "running" }]])
  local before = snapshot()
  local function text(reply)
    return reply.result and reply.result.content and reply.result.content[1].text
      or reply.error and reply.error.message or "MCP returned no error text"
  end
  local send = text(T.mcp_call("butler_send", { to = "butler", text = "unidentified send" }))
  local reply = text(T.mcp_call("butler_reply", { to = "butler", text = "unidentified reply" }))
  local approve = text(T.mcp_call("butler_approve_text", { session = "reused", text = "unidentified approval" }))
  local inbox = text(T.mcp_call("butler_inbox", {}))
  for label, result in pairs({ send = send, reply = reply, approve = approve, inbox = inbox }) do
    T.ok(result:find("unknown caller", 1, true) ~= nil,
      label .. " accepted an unidentified MCP caller: " .. result)
  end
  T.eq(snapshot(), before, "unidentified MCP mutations must have zero effects")
  T.eval("local bus = remuda._butler_bus; bus.agents.outside, bus.identity_ids.OUTSIDE = nil, nil")
  T.eval([[
    local feature = remuda.butler.approve_text
    feature.request, feature.target_session_allowed = feature._test_original_request, feature._test_original_allowed
    feature._test_original_request, feature._test_original_allowed = nil, nil
    remuda._butler_inbox = remuda._butler_inbox_original
    remuda._butler_inbox_original, remuda._butler_inbox_calls = nil, nil
  ]])
end)

T.test("native_session_attribution_resolves_exactly_one_registration_by_session_name", function()
  local result = T.eval([[
    local bus, identity = remuda._butler_bus, remuda._butler_identity
    local function row(id, session)
      bus.identity_ids[id] = { id = id, alias = id, state = "running" }
      bus.agents[id] = { id = id, alias = id, session_name = session, session_start_marker = "M" }
    end
    row("solo", "solo-native") row("twin1", "twin-native") row("twin2", "twin-native")
    bus.agents.alias_only = { id = "ALIAS", alias = "alias_only", session_name = "other-native", session_start_marker = "M" }
    local cap = { id = "solo", generation = "M" }
    bus.tokens.cap = cap
    local out = {
      tostring(identity.caller_name({ kind = "session", session = "solo-native" })),
      tostring(identity.caller_name({ kind = "session", session = "twin-native", capability = "cap" })),
      tostring(identity.caller_name({ kind = "session", session = "alias_only" })),
    }
    for _, k in ipairs({ "solo", "twin1", "twin2", "alias_only" }) do bus.agents[k], bus.identity_ids[k] = nil, nil end
    bus.tokens.cap = nil
    return table.concat(out, ":")
  ]])
  T.eq(result, "solo:nil:nil", "native attribution must be the unique session_name match, never an alias or a capability rescue")
end)
