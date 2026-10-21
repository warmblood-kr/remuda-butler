-- After `remuda reload` (remuda#713) a member's MCP bridge still presents the
-- old image's capability. For a row taken back from roster.json, Butler binds
-- that token once, on the first call that core attributes to the row's own
-- session instance. Everything else with an unknown token stays refused.
local repo = assert(os.getenv("REMUDA_LUA_REPO"))
T.install_mod("butler", repo)
T.eval('remuda._reload_test_core = { key = remuda.key, type_text = remuda.type_text, send = remuda.send, close = remuda.close }')
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 100"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
T.eval('return remuda.exec("butler")')
local function truthy(code) return T.eval(code):match("^%s*true%s*$") ~= nil end
T.wait_until(function()
  return truthy('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil'
    .. ' and remuda._butler_bus.agents.butler.instance_id ~= nil')
end, 10, "Butler root start")
T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_launch("codex", "alice")
  remuda._butler_launch("codex", "bob")
]], os.getenv("XDG_DATA_HOME") .. "/projects"))
T.wait_until(function()
  return truthy('local a = remuda._butler_bus.agents return a.alice ~= nil and a.bob ~= nil')
end, 10, "members registered")
-- The tokens the members' bridges were started with, kept across the reload.
T.eval([[remuda._reload_test_tokens = { alice = remuda._butler_bus.agents.alice.token,
  bob = remuda._butler_bus.agents.bob.token }]])
T.eval([[
  for word, fn in pairs(remuda._reload_test_core) do remuda[word] = fn end
  local names = {}
  for key in pairs(remuda) do
    if type(key) == "string" and (key:match("^_butler") or key == "butler") then names[#names + 1] = key end
  end
  for _, key in ipairs(names) do remuda[key] = nil end
  remuda._butler_argv = {"sh", "-c", "sleep 100"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1
  remuda.reload("butler")
]])
T.wait_until(function()
  return truthy('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.alice ~= nil and not remuda._butler_launching')
end, 10, "Butler after the fresh image")

-- name(session, instance-of-which-session, token-of-which-member) through identity.caller_name.
local function name(session, instance_of, token_of, kind)
  return T.eval(string.format([[
    local inst
    for _, row in ipairs(remuda.ls()) do if row.name == %q then inst = row.instance_id end end
    local token = remuda._reload_test_tokens[%q] or %q
    local caller = { kind = %s, session = %q, instance_id = inst, capability = token }
    return tostring(remuda._butler_identity.caller_name(caller))
  ]], instance_of, token_of, token_of, kind and string.format("%q", kind) or "nil", session))
end

T.test("doctor_names_members_waiting_for_a_re_bind", function()
  local doctor = T.eval("return table.concat(remuda._butler_doctor.render(remuda._butler_doctor.probe()), '\\n')")
  T.ok(doctor:find("MCP tools not re-bound yet: alice, bob", 1, true), "doctor lists both: " .. doctor)
end)

T.test("an_unknown_token_from_another_instance_or_session_stays_refused", function()
  T.eq(name("alice", "bob", "alice", "session"), "nil", "alice's session with bob's instance")
  T.eq(name("outsider", "alice", "alice", "session"), "nil", "an unregistered session")
  T.eq(name("alice", "alice", "alice", nil), "nil", "a capability-only caller (no core attribution)")
  T.eq(T.eval("return tostring(remuda._butler_bus.tokens[remuda._reload_test_tokens.alice])"), "nil",
    "nothing was bound by a refused call")
end)

T.test("the_old_token_is_bound_on_the_first_attributed_call", function()
  T.eq(name("alice", "alice", "alice", "session"), "alice", "alice's own bridge is admitted")
  T.eq(name("alice", "alice", "alice", "session"), "alice", "and stays admitted")
  T.eq(T.eval([[local r = remuda._butler_bus.tokens[remuda._reload_test_tokens.alice]
    local a = remuda._butler_bus.agents.alice
    return tostring(r.id == a.id and r.instance_id == a.instance_id and r.instance_binding == 1)]]), "true",
    "the record is bound to alice's instance")
  -- One re-bind per row: a second unknown token from the same session is refused.
  T.eq(name("alice", "alice", "a-second-token", "session"), "nil", "a second token is refused")
  -- A tool call through the MCP path works with the re-bound token.
  local inbox = T.eval([[
    local inst
    for _, row in ipairs(remuda.ls()) do if row.name == "alice" then inst = row.instance_id end end
    local tool = remuda.tools.butler_inbox
    local ok, out = pcall(tool.run, {}, { kind = "session", session = "alice", instance_id = inst,
      capability = remuda._reload_test_tokens.alice })
    return tostring(ok) .. "|" .. tostring(out)
  ]])
  T.ok(inbox:find("^true|") and inbox:find("Welcome to Butler", 1, true), "butler_inbox over MCP: " .. inbox:sub(1, 200))
end)

T.test("the_re_bind_is_logged_by_name_only", function()
  local out = T.eval([[
    local snap = remuda._butler_diagnostics.snapshot()
    local text = remuda.json.encode(snap)
    local n = 0
    for _ in text:gmatch("capability_rebound") do n = n + 1 end
    return n .. "|" .. tostring(text:find(remuda._reload_test_tokens.alice, 1, true) ~= nil)
  ]])
  T.eq(out, "1|false", "one diagnostics row, no token value")
  local doctor = T.eval("return table.concat(remuda._butler_doctor.render(remuda._butler_doctor.probe()), '\\n')")
  T.ok(doctor:find("MCP tools not re-bound yet: bob", 1, true), "doctor now lists only bob: " .. doctor)
end)

T.test("a_member_launched_after_the_reload_never_re_binds", function()
  T.eval([[remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
    remuda._butler_launch("codex", "carol")]])
  T.wait_until(function() return truthy('return remuda._butler_bus.agents.carol ~= nil') end, 10, "carol")
  T.eq(name("carol", "carol", "carol-forged-token", "session"), "nil", "a non-adopted row keeps its own capability")
end)

T.test("the_re_bound_token_ends_with_the_member", function()
  T.eval('remuda.close("alice")')
  T.wait_until(function() return truthy('return remuda._butler_bus.agents.alice == nil') end, 10, "alice exit")
  T.eq(T.eval("return tostring(remuda._butler_bus.tokens[remuda._reload_test_tokens.alice])"), "nil",
    "exit revokes the re-bound token")
end)
