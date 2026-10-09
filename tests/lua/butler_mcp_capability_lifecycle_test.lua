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
  T.eq(T.eval("return tostring(remuda._butler_bus.tokens[" .. string.format("%q", old_token) .. "])"), "nil",
    "exit must remove the ended member's token record")
  local ended_inbox = T.mcp_call("butler_inbox", {}, old_token)
  T.ok(tostring(ended_inbox.error and ended_inbox.error.message or (ended_inbox.result and ended_inbox.result.content
    and ended_inbox.result.content[1].text)):find("unknown caller", 1, true) ~= nil,
    "an ended member's bridge must not read an inbox")
  local shape = T.eval([[
    local bus = remuda._butler_bus
    local agent = bus.agents.reused
    local record = bus.tokens[agent.token]
    return tostring(type(record) == "table" and record.id == agent.id and record.generation == agent.session_start_marker)
  ]])
  T.eq(shape, "true", "a launch must store {durable id, launch marker}, not an alias string")
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
  T.eq(caller_shape, "outside:nil:" .. old_token,
    "the test bridge is outside any session: core sets kind, the bridge adds only its saved capability")
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
  -- A tokenless harness bridge is now kind=outside, which butler_approve_text maps to the
  -- operator (transitional policy), so approve is checked with a native unknown caller instead.
  local approve = T.eval([[local ok, err = pcall(remuda._butler_identity.caller_agent, { kind = "unknown" }); return tostring(err)]])
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

T.test("tokenless_MCP_bridge_cannot_reach_operator_only_routes_even_with_approvals_on", function()
  -- Approvals ON with a recording relay stand-in: a tokenless bridge is kind=outside, which
  -- the CLI policy may treat as the operator but no MCP route may.
  T.eval([[
    remuda._butler_matrix_live_config = { approve_text = true, use_messages = false }
    remuda._probe_posts, remuda._probe_state = 0, { approvals = remuda.json.object({}) }
    remuda.butler.approval.attach(remuda._probe_state, function() return true end, function(_, _, done)
      remuda._probe_posts = remuda._probe_posts + 1
      if done then done({ event_id = "$p" .. remuda._probe_posts }) end
      return {}
    end)
  ]])
  local function snapshot()
    return T.eval([[
      local bus, n = remuda._butler_bus, { 0, 0, 0, 0, 0 }
      for _ in pairs(bus.messages) do n[1] = n[1] + 1 end
      for _ in pairs(bus.objects) do n[2] = n[2] + 1 end
      for _, rows in pairs(bus.mail_delivered) do for _ in pairs(rows) do n[3] = n[3] + 1 end end
      for _ in pairs(remuda._probe_state.approvals) do n[4] = n[4] + 1 end
      for _ in pairs(bus.agents) do n[5] = n[5] + 1 end
      return table.concat(n, ":") .. ":" .. bus.next .. ":" .. remuda._probe_posts
    ]])
  end
  local before = snapshot()
  for name, args in pairs({
    butler_approve_text = { session = "butler", text = "tokenless prepared text" },
    butler_send = { to = "butler", text = "x" }, butler_reply = { to = "butler", text = "x" },
    butler_forward = { message_id = "m", to = "butler" }, butler_inbox = {},
    butler_send_to_leader = { text = "x" }, butler_report = { text = "x" },
    butler_launch = { kind = "codex", name = "tokenless" },
    butler_delegate = { name = "tokenless", task = "t", kind = "codex" },
    butler_close = { name = "butler" }, matrix_download = { mxc = "mxc://a/b" },
    matrix_upload = { path = "/etc/hosts" },
  }) do
    local reply = T.mcp_call(name, args)
    local message = reply.error and reply.error.message
      or reply.result and reply.result.content and reply.result.content[1].text or ""
    T.ok(message:find("unknown caller", 1, true) ~= nil, name .. " accepted a tokenless MCP caller: " .. message)
  end
  T.eq(snapshot(), before, "tokenless MCP calls must register no approval and change no state")
  -- Positive control: a registered session still registers a request, asked by that member.
  local registered = T.eval([[
    local tool; for k, v in pairs(remuda.tools) do if k == "butler_approve_text" or (type(v) == "table" and v.name == "butler_approve_text") then tool = v end end
    local session = remuda._butler_bus.agents.butler.session_name
    local ok, id = pcall(tool.run, { session = "butler", text = "member text" }, { kind = "session", session = session })
    return tostring(ok) .. ":" .. remuda._probe_posts
  ]])
  T.eq(registered, "true:1", "a registered member must still be able to register prepared text")
  T.eval("remuda._butler_matrix_live_config = nil")
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

T.test("each_root_launch_gets_a_fresh_capability_and_the_ended_one_is_revoked", function()
  local before = T.eval([[
    local root = remuda._butler_bus.agents.butler
    return root.id .. ":" .. root.token .. ":" .. root.session_start_marker
  ]])
  local id, old_token, old_marker = before:match("([^:]+):(.-):(%S+)$")
  T.eval('return remuda.close("butler")')
  T.wait_until(function()
    return T.eval('return tostring(remuda._butler_bus.agents.butler.token ~= ' .. string.format("%q", old_token)
      .. ' and remuda._butler_start_pending == false)'):match("true") ~= nil
  end, 10, "root respawn with a fresh capability")
  local after = T.eval([[
    local bus, identity = remuda._butler_bus, remuda._butler_identity
    local root = bus.agents.butler
    return table.concat({ root.id, tostring(root.session_start_marker ~= ]] .. string.format("%q", old_marker) .. [[),
      tostring(identity.caller_name({ capability = ]] .. string.format("%q", old_token) .. [[ })),
      tostring(bus.tokens[]] .. string.format("%q", old_token) .. [[]),
      tostring(identity.caller_name({ capability = root.token })) }, ":")
  ]])
  T.eq(after, id .. ":true:nil:nil:butler",
    "the durable root id must survive while the old launch's capability is revoked and the new one resolves")
end)

T.test("a_capability_is_refused_while_the_native_exit_is_pending_or_liveness_is_unknown", function()
  local result = T.eval([[
    local bus, identity = remuda._butler_bus, remuda._butler_identity
    local agent = bus.agents.reused
    local cap = agent.token
    bus.tokens[cap] = { id = agent.id, generation = agent.session_start_marker }
    local real_ls = remuda.ls
    local function with(ls) remuda.ls = ls; local n = tostring(identity.caller_name({ capability = cap })); remuda.ls = real_ls; return n end
    return table.concat({
      with(real_ls), -- the native session is alive: authorized
      with(function() return { { name = agent.session_name, alive = false } } end), -- exit pending in Lua
      with(function() return {} end), -- unknown to the daemon
      with(function() error("ls unavailable") end), -- unknown liveness is refused
    }, ":")
  ]])
  T.eq(result, "reused:nil:nil:nil", "authorization must check native liveness, not only Butler's roster")
end)

T.test("a_token_record_with_any_single_wrong_field_does_not_resolve", function()
  local result = T.eval([[
    local bus, identity = remuda._butler_bus, remuda._butler_identity
    local agent = bus.agents.reused
    local record = bus.tokens[agent.token]
    local good = { id = record.id, generation = record.generation }
    local out = {}
    local function try(label, setup, undo)
      setup(); out[#out + 1] = label .. "=" .. tostring(identity.caller_name({ capability = agent.token })); undo()
    end
    local state, marker = bus.identity_ids[agent.id].state, agent.session_start_marker
    try("id", function() bus.tokens[agent.token] = { id = "OTHER", generation = good.generation } end,
      function() bus.tokens[agent.token] = good end)
    try("generation", function() bus.tokens[agent.token] = { id = good.id, generation = "OTHER" } end,
      function() bus.tokens[agent.token] = good end)
    try("state", function() bus.identity_ids[agent.id].state = "ended" end,
      function() bus.identity_ids[agent.id].state = state end)
    try("same_id_relaunch", function() agent.session_start_marker = "NEW-LAUNCH" end,
      function() agent.session_start_marker = marker end)
    try("row", function() bus.agents.reused = nil end, function() bus.agents.reused = agent end)
    out[#out + 1] = "ok=" .. tostring(identity.caller_name({ capability = agent.token }))
    -- legacy alias-valued entries must be proven by the live row; each guard alone refuses
    local token = agent.token
    local function legacy(label, mutate, restore)
      bus.tokens[token] = "reused"; mutate()
      out[#out + 1] = label .. "=" .. tostring(identity.caller_name({ capability = token }))
        .. "/" .. type(bus.tokens[token]); restore(); bus.tokens[token] = good
    end
    legacy("legacy_token", function() agent.token = "someone-else" end, function() agent.token = token end)
    legacy("legacy_id", function() agent.id = nil end, function() agent.id = good.id end)
    legacy("legacy_marker", function() agent.session_start_marker = nil end, function() agent.session_start_marker = marker end)
    return table.concat(out, ":")
  ]])
  T.eq(result, "id=nil:generation=nil:state=nil:same_id_relaunch=nil:row=nil:ok=reused"
    .. ":legacy_token=nil/string:legacy_id=nil/string:legacy_marker=nil/string")
end)

T.test("tokens_carry_a_random_incarnation_component", function()
  T.eq(T.eval([[
    local a, b = remuda._butler_identity.next_token("x"), remuda._butler_identity.next_token("x")
    return tostring(a:match("^x%-%d+%-%w%w%w%w%w%w%w%w%w%w%-%d+$") ~= nil and a ~= b)
  ]]), "true")
end)

-- PR A of the instance binding (design-instance-binding.md): record the issuing
-- instance at launch. Recording only; nothing compares it yet.
local function ls_instance(name)
  return T.eval('for _, r in ipairs(remuda.ls()) do if r.name == ' .. string.format("%q", name)
    .. ' and r.alive then return r.instance_id end end return "none"')
end

T.test("launch_instance_is_the_one_alive_ls_row_and_never_a_guess", function()
  local result = T.eval([[
    local pick, real, out = remuda._butler_chooser.launch_instance, remuda.ls, {}
    local function with(rows) remuda.ls = rows; local v = tostring(pick("n")); remuda.ls = real; return v end
    local function row(extra) local r = { name = "n", alive = true, instance_id = "I1" }; for k, v in pairs(extra or {}) do r[k] = v end; return r end
    out[#out + 1] = with(function() return { row(), { name = "o", alive = true, instance_id = "X" } } end)
    out[#out + 1] = with(function() return { row({ alive = false, instance_id = "OLD" }), row() } end)
    out[#out + 1] = with(function() return { row(), row({ instance_id = "I2" }) } end) -- replacement raced in
    out[#out + 1] = with(function() return { row({ instance_id = false }) } end)
    out[#out + 1] = with(function() return { row({ instance_id = "" }) } end)
    out[#out + 1] = with(function() return {} end)
    out[#out + 1] = with(function() error("ls unavailable") end)
    return table.concat(out, ",")
  ]])
  T.eq(result, "I1,I1,nil,nil,nil,nil,nil", "an instance is taken only from exactly one alive row that carries one")
end)

T.test("member_launch_records_the_native_instance_id", function()
  -- (an earlier test rewrote the first launch's capability record, so only the row is checked here)
  local id = ls_instance("reused")
  T.ok(id ~= "none" and id ~= "", "core ls must expose the launch's instance_id")
  T.eq((T.eval("return remuda._butler_bus.agents.reused.instance_id"):gsub("%s+$", "")), id, "the agent row must hold the launched instance")
  T.eval('return remuda.close("reused")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus.agents.reused == nil'):match("^%s*true%s*$") ~= nil
  end, 5, "member exit")
  T.eval('return remuda._butler_launch("codex", "reused")')
  local second = T.eval([[
    local bus = remuda._butler_bus
    local a = bus.agents.reused
    return a.instance_id .. ":" .. bus.tokens[a.token].instance_id
  ]])
  local id2 = ls_instance("reused")
  T.ok(id2 ~= id, "a relaunch under the same alias must be a new native instance")
  T.eq(second, id2 .. ":" .. id2, "the relaunch must record its own instance, not the first")
end)

T.test("root_launch_records_instance_and_rotation_replaces_it", function()
  local function root()
    return T.eval([[
      local bus, root = remuda._butler_bus, remuda._butler_bus.agents.butler
      return tostring(root.instance_id) .. ":" .. tostring(bus.tokens[root.token] and bus.tokens[root.token].instance_id)
        .. ":" .. root.token
    ]])
  end
  local function root_ls() return ls_instance(T.eval("return remuda._butler_name"):gsub("%s+$", "")) end
  local id, cap, token = root():match("^([^:]+):([^:]+):(.+)$")
  T.ok(id and id ~= "nil", "the root row must hold its launch instance")
  T.eq(cap, id, "the root capability must hold the same instance")
  T.eq(root_ls(), id, "the recorded root instance must be the native one")
  T.eval('return remuda.close(remuda._butler_name)')
  T.wait_until(function()
    return T.eval('return tostring(remuda._butler_bus.agents.butler.token ~= ' .. string.format("%q", token)
      .. ' and remuda._butler_start_pending == false)'):match("true") ~= nil
  end, 10, "root respawn")
  local id2, cap2 = root():match("^([^:]+):([^:]+):")
  T.ok(id2 and id2 ~= "nil" and id2 ~= id, "a new root launch must record a new instance")
  T.eq(cap2, id2, "the rotated capability must hold the new instance")
  T.eq(root_ls(), id2, "the replaced record must be the native one")
end)

T.test("capability_without_issuing_instance_is_not_recorded_as_bound", function()
  T.eval([[
    local real = remuda.ls
    remuda._test_real_ls = real
    remuda.ls = function() -- a second alive row under the launched name: ambiguous
      local rows = real()
      for _, r in ipairs(rows) do
        if r.name == "dupe" then
          local copy = {}; for k, v in pairs(r) do copy[k] = v end
          copy.instance_id = "OTHER"; rows[#rows + 1] = copy; break
        end
      end
      return rows
    end
    remuda._butler_launch("codex", "dupe")
  ]])
  local seen = T.eval([[
    local bus = remuda._butler_bus
    local a = bus.agents.dupe
    local rec = a and bus.tokens[a.token]
    remuda.ls = remuda._test_real_ls; remuda._test_real_ls = nil
    return table.concat({ tostring(a ~= nil), tostring(a and a.instance_id), tostring(type(rec) == "table" and rec.instance_id),
      tostring(type(rec) == "table" and rec.id == a.id) }, ":")
  ]])
  T.eq(seen, "true:nil:nil:true", "an ambiguous launch must still work, with the instance left unset")
  T.eval('return remuda.close("dupe")')
end)
