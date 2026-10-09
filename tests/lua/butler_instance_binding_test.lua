-- PR B of the instance binding (design-instance-binding-B.md): the instance id RETURNED by remuda.new
-- (core #654) is the only thing a member or root is bound to; admission compares and re-checks it.
-- These tests are written before the code: until the binding lands most of them fail on purpose.
-- Fakes live in the child daemon (remuda._t): a registry behind remuda.new/ls/capture/close, so a test
-- can make the returned id differ from the observed row, or make a candidate fail.
-- Every refusal asserts zero effects (mail, tokens, roster, approve_text requests, launches, closes).
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
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

T.eval([=[
  local t = {}
  remuda._t = t
  t.real = { new = remuda.new, ls = remuda.ls, close = remuda.close, capture = remuda.capture, key = remuda.key }
  -- A fake core registry. o.ids: ids handed out in order; o.no_id: new returns only the name (older core);
  -- o.on_new(w, name, n, id): runs after the row exists, to replace/kill it.
  function t.world(o)
    local w = { rows = {}, ids = o.ids or {}, spawns = 0, closed = {}, screens = {}, no_id = o.no_id, on_new = o.on_new }
    t.w = w
    remuda.new = function(name)
      w.spawns = w.spawns + 1
      local id = table.remove(w.ids, 1) or ("ID" .. w.spawns)
      w.rows[name] = { name = name, alive = true, instance_id = id }
      if w.on_new then w.on_new(w, name, w.spawns, id) end
      if w.no_id then return name end
      return name, id
    end
    remuda.ls = function(...)
      local out = {}
      for _, r in ipairs(t.real.ls(...)) do if not w.rows[r.name] then out[#out + 1] = r end end
      for _, r in pairs(w.rows) do out[#out + 1] = { name = r.name, alive = r.alive, instance_id = r.instance_id } end
      return out
    end
    remuda.capture = function(name) if w.rows[name] then return w.screens[name] or "" end return t.real.capture(name) end
    remuda.close = function(name)
      w.closed[#w.closed + 1] = name
      if w.rows[name] then w.rows[name].alive = false; return true end
      return t.real.close(name)
    end
    remuda.key = function(name, ...) if w.rows[name] then return true end return t.real.key(name, ...) end
    return w
  end
  function t.restore()
    remuda.new, remuda.ls, remuda.close, remuda.capture, remuda.key =
      t.real.new, t.real.ls, t.real.close, t.real.capture, t.real.key
    t.w = nil
  end
  -- A member launched through the fake core has no real session: drop it from the roster instead of closing.
  function t.forget(name)
    local bus, a = remuda._butler_bus, remuda._butler_bus.agents[name]
    if a then bus.tokens[a.token] = nil; bus.agents[name] = nil end
  end
  function t.count(tbl) local n = 0; for _ in pairs(tbl) do n = n + 1 end; return n end
  function t.tool(name)
    for k, v in pairs(remuda.tools) do if k == name or (type(v) == "table" and v.name == name) then return v end end
  end
  function t.route(name, args, caller)
    local ok, err = pcall(t.tool(name).run, args, caller)
    return ok and "ok" or ("err:" .. tostring(err))
  end
  -- Everything a refused call must leave alone.
  function t.snap()
    local bus, n = remuda._butler_bus, { 0, 0, 0, 0 }
    for _ in pairs(bus.messages) do n[1] = n[1] + 1 end
    for _ in pairs(bus.objects) do n[2] = n[2] + 1 end
    for _, rows in pairs(bus.mail_delivered) do for _ in pairs(rows) do n[3] = n[3] + 1 end end
    for _, rows in pairs(bus.inboxes) do n[4] = n[4] + #rows end
    local reads = 0
    for _, rows in pairs(bus.mail_read or {}) do for _ in pairs(rows) do reads = reads + 1 end end
    return table.concat(n, ":") .. ":" .. reads .. ":" .. bus.next .. ":tokens=" .. t.count(bus.tokens)
      .. ":agents=" .. t.count(bus.agents) .. ":new=" .. (t.new_calls or 0) .. ":close=" .. (t.close_calls or 0)
      .. ":approve=" .. (remuda.butler.approve_text._test_request_count or 0)
  end
  -- Stub the effect points so a wrongly admitted launch/close/approval is counted, not performed.
  function t.guard_effects()
    t.new_calls, t.close_calls = 0, 0
    local feature = remuda.butler.approve_text
    feature._test_request_count = 0
    t.saved = { new = remuda.new, close = remuda.close, request = feature.request, allowed = feature.target_session_allowed }
    remuda.new = function() t.new_calls = t.new_calls + 1; error("launch blocked by the test", 0) end
    remuda.close = function() t.close_calls = t.close_calls + 1; return true end
    feature.target_session_allowed = function() return true end
    feature.request = function() feature._test_request_count = feature._test_request_count + 1; return "x" end
  end
  function t.unguard_effects()
    local feature = remuda.butler.approve_text
    remuda.new, remuda.close, feature.request, feature.target_session_allowed =
      t.saved.new, t.saved.close, t.saved.request, t.saved.allowed
  end
  function t.agent(name)
    local a = remuda._butler_bus.agents[name]
    local rec = a and remuda._butler_bus.tokens[a.token]
    return a, type(rec) == "table" and rec or nil
  end
]=])

local function quote(value) return string.format("%q", value) end
local function trim(text) return (text:gsub("%s+$", "")) end
local function ev(code) return trim(T.eval(code)) end
local function launch(name)
  T.eval("return remuda._butler_launch('codex', " .. quote(name) .. ")")
  T.wait_until(function() return ev("return tostring(remuda._butler_bus.agents[" .. quote(name) .. "] ~= nil)") == "true" end,
    5, name .. " registered")
end
local function gone(name)
  T.wait_until(function() return ev("return tostring(remuda._butler_bus.agents[" .. quote(name) .. "] == nil)") == "true" end,
    8, name .. " exit")
end
local function bound(name) -- agent row id : capability record id
  return ev("local a, r = remuda._t.agent(" .. quote(name) .. "); return tostring(a and a.instance_id) .. ':' .. tostring(r and r.instance_id)")
end
-- A caller as the pinned core builds it for a bridge running inside a session.
local function snapshot_literal(session, instance)
  return "{ kind = 'session', session = " .. quote(session) .. (instance and (", instance_id = " .. quote(instance)) or "") .. " }"
end
local function admitted(session, instance)
  return ev("local ok, who = pcall(remuda._butler_identity.caller_agent, " .. snapshot_literal(session, instance)
    .. "); return ok and who or 'refused'")
end

T.test("pinned_core_new_returns_name_and_instance_id", function() -- regression guard for the CORE_REF bump
  T.eq(ev([[
    local name, id = remuda.new('pin-probe', { 'sleep', '30' })
    local live
    for _, r in ipairs(remuda.ls()) do if r.name == name and r.alive then live = r.instance_id end end
    remuda.close(name)
    return tostring(name == 'pin-probe' and type(id) == 'string' and id ~= '' and id == live)]]), "true",
    "remuda.new must return the name and the spawned session's instance id")
end)

T.test("same_name_replacement_cannot_reuse_the_old_capability_row", function()
  launch("swap")
  local old = ev("return remuda._butler_bus.agents.swap.instance_id")
  T.eval("return remuda.close('swap')"); gone("swap")
  launch("swap")
  local new = ev("return remuda._butler_bus.agents.swap.instance_id")
  T.ok(old ~= "nil" and new ~= "nil" and old ~= new, "a replacement under the same name must be a new instance")
  T.eq(admitted("swap", new), "swap", "the replacement's own instance must be admitted")
  T.eval("remuda._t.guard_effects()")
  local before = ev("return remuda._t.snap()")
  T.eq(admitted("swap", old), "refused", "the ended instance's snapshot must not reuse the replacement's row")
  T.eq(ev("return remuda._t.route('butler_send', { to = 'butler', text = 'stale' }, " .. snapshot_literal("swap", old) .. ")"):sub(1, 3),
    "err", "a send by the ended instance must be refused")
  T.eq(ev("return remuda._t.snap()"), before, "the refused stale instance must have zero effects")
  T.eval("remuda._t.unguard_effects()")
end)

T.test("a_session_snapshot_must_carry_the_bound_instance_id", function()
  launch("snap")
  local id = ev("return remuda._butler_bus.agents.snap.instance_id")
  T.eq(admitted("snap", id), "snap", "the bound instance must be admitted")
  T.eq(ev("return remuda._butler_caller_principal.resolve(" .. snapshot_literal("snap", "OTHER") .. ").tag"), "unidentified",
    "a snapshot with another instance id must be unidentified")
  T.eq(ev("return remuda._butler_caller_principal.resolve(" .. snapshot_literal("snap") .. ").tag"), "unidentified",
    "a session snapshot without an instance id must be unidentified")
  T.eval("return remuda.close('snap')"); gone("snap")
end)

T.test("the_bound_id_is_the_returned_one_never_the_observed_one", function()
  T.eval("remuda._t.world { ids = { 'RETURNED' }, on_new = function(w, name) w.rows[name].instance_id = 'OBSERVED' end }")
  local ok, err = pcall(launch, "ret")
  local seen = ev("local a, r = remuda._t.agent('ret'); return tostring(a and a.instance_id) .. ':' .. tostring(r and r.instance_id)")
  T.eval("remuda._t.restore()")
  T.ok(ok, tostring(err))
  T.ok(not seen:find("OBSERVED", 1, true), "the observed ls id must never be bound, got " .. seen)
  T.eval("remuda._t.forget('ret')")
end)

T.test("a_core_returning_no_instance_id_leaves_the_member_unbound_and_legacy_visible", function()
  T.eval("remuda._t.world { ids = { 'OBS-X' }, no_id = true }")
  local ok, err = pcall(launch, "legacy")
  local seen = bound("legacy")
  T.eval("remuda._t.restore()")
  T.ok(ok, tostring(err))
  T.eq(seen, "nil:nil", "no returned id: no ls fallback, the row and capability stay unbound")
  T.eq(admitted("legacy", "OBS-X"), "legacy", "an unbound member stays visible by name (legacy mode, no isolation claim)")
  T.eval("remuda._t.forget('legacy')")
end)

-- The chooser, driven directly. CHOOSE runs two fake kinds against the fake core registry.
local function choose(kinds, setup)
  T.eval(string.format([[
    local t = remuda._t
    remuda._butler_readiness_timeout = 1
    remuda._butler_test_force_launch_probe = { chtest = true }
    for _, kind in ipairs(%s) do
      remuda._butler_agent_builders[kind] = function() return { 'x' } end
      remuda._butler_agent_startup[kind] = { ready = function(screen) return screen:find('READY', 1, true) ~= nil end }
    end
    %s
    t.done = nil
    remuda._butler_chooser.choose(%s, { name = 'chtest', argv = { 'x' }, env = function() return {} end,
      spec = function() return {} end }, function(name, kind, attempts, instance_id)
        t.done = { name = name, kind = kind, attempts = attempts, instance_id = instance_id, argc = select('#', name, kind, attempts, instance_id) }
      end)
  ]], "{" .. table.concat(kinds, ",") .. "}", setup, "{" .. table.concat(kinds, ",") .. "}"))
  T.wait_until(function() return ev("return tostring(remuda._t.done ~= nil)") == "true" end, 10, "chooser done")
  return ev("local d = remuda._t.done; return tostring(d.name) .. ':' .. tostring(d.kind) .. ':' .. tostring(d.instance_id) .. ':' .. #remuda._t.w.closed")
end
local function chooser_reset()
  T.eval("remuda._t.restore(); remuda._butler_test_force_launch_probe = nil; remuda._butler_readiness_timeout = nil")
end

T.test("chooser_failed_candidate_id_is_never_bound", function()
  T.eval("remuda._t.world { ids = { 'I1', 'I2' }, on_new = function(w, name, n) w.screens[name] = n == 1 and 'booting' or 'READY' end }")
  local result = choose({ "'fx1'", "'fx2'" }, "")
  chooser_reset()
  T.eq(result, "chtest:fx2:I2:1", "the ready second candidate must supply its own id (4th argument); the first was closed once")
end)

T.test("chooser_ready_unverified_binds_its_own_id", function()
  T.eval("remuda._t.world { ids = { 'I1' }, on_new = function(w, name) w.screens[name] = '' end }")
  local result = choose({ "'fx1'" }, "")
  local attempt = ev("return remuda._t.done.attempts[1].reason")
  chooser_reset()
  T.eq(attempt, "ready_unverified")
  T.eq(result:match("^[^:]+:[^:]+:([^:]+)"), "I1", "a ready_unverified candidate is a live row we spawned: it binds its own id")
end)

T.test("chooser_replacement_during_readiness_is_not_ready_and_never_closed", function()
  -- new returned I1, but the row under that name now belongs to another instance.
  T.eval("remuda._t.world { ids = { 'I1' }, on_new = function(w, name) w.rows[name].instance_id = 'REPLACEMENT'; w.screens[name] = 'READY' end }")
  local result = choose({ "'fx1'" }, "")
  chooser_reset()
  T.eq(result, "nil:nil:nil:0", "a row with another id is not this candidate: not ready, and the replacement is not closed")
end)

T.test("finish_with_a_bound_row_that_is_gone_installs_no_token", function()
  T.eval("remuda._t.world { ids = { 'GONE' }, on_new = function(w, name) w.rows[name].alive = false end }")
  local before = ev("return remuda._t.count(remuda._butler_bus.tokens)")
  pcall(function() T.eval("return remuda._butler_launch('codex', 'ghost')") end)
  local after = ev("return remuda._t.count(remuda._butler_bus.tokens) .. ':' .. tostring(remuda._butler_bus.agents.ghost)")
  T.eval("remuda._t.restore()")
  T.eq(after, before .. ":nil", "a launch whose bound row already exited must install no token and no roster row")
end)

local function root_respawn(observed)
  -- Two root candidates: the first times out (R1), the second is ready (R2). OBSERVED, when given, replaces R2's row id in ls.
  T.eval("remuda._t.observed = " .. (observed and quote(observed) or "nil"))
  T.eval([[
    local t = remuda._t
    remuda._butler_readiness_timeout = 1
    remuda._butler_candidate_order = { 'fx1', 'fx2' }
    remuda._butler_argv = nil
    for _, kind in ipairs({ 'fx1', 'fx2' }) do
      remuda._butler_agent_builders[kind] = function() return { 'sleep', '60' } end
      remuda._butler_agent_startup[kind] = { ready = function(screen) return screen:find('READY', 1, true) ~= nil end }
    end
    remuda._butler_test_force_launch_probe = { [remuda._butler_name] = true }
    t.root_tokens_before = remuda._butler_bus.agents.butler.token
    t.world { ids = { 'R1', 'R2' }, on_new = function(w, name, n) w.screens[name] = n == 1 and 'booting' or 'READY'; if n == 2 and t.observed then w.rows[name].instance_id = t.observed end end }
    pcall(t.real.close, remuda._butler_name) -- a previous respawn may have left only a fake row
  ]])
  T.wait_until(function()
    return ev([[local root = remuda._butler_bus.agents.butler
      return tostring(root.token ~= remuda._t.root_tokens_before and remuda._butler_start_pending == false)]]) == "true"
  end, 20, "root respawn through two candidates")
  local result = ev([[
    local bus, root = remuda._butler_bus, remuda._butler_bus.agents.butler
    local rec = bus.tokens[root.token]
    local butler_tokens = 0
    for token in pairs(bus.tokens) do if token:match('^butler%-') then butler_tokens = butler_tokens + 1 end end
    remuda._butler_session_exited(remuda._butler_name, { instance_id = 'R1' }) -- late exit of the failed candidate
    return table.concat({ tostring(root.instance_id), tostring(rec and rec.instance_id), butler_tokens,
      tostring(bus.tokens[root.token] == rec), tostring(bus.agents.butler == root) }, ':')
  ]])
  T.eval([[
    remuda._t.restore(); remuda._butler_test_force_launch_probe = nil; remuda._butler_readiness_timeout = nil
    remuda._butler_candidate_order = nil; remuda._butler_argv = { 'sh', '-c', 'sleep 60' }
  ]])
  return result
end

T.test("root_respawn_binds_the_winning_candidates_id", function() -- regression guard until the binding exists
  T.eq(root_respawn(nil), "R2:R2:1:true:true", "the final root token must hold the winner's id; the failed candidate's id and token are gone")
end)

T.test("root_respawn_never_binds_an_observed_id", function()
  local result = root_respawn("OBSERVED")
  T.ok(not result:find("OBSERVED", 1, true), "the root must not bind the id observed in ls instead of the returned one: " .. result)
end)


T.test("stale_exit_uses_the_bound_instance_without_asking_ls", function()
  launch("stale")
  T.eval("local a, r = remuda._t.agent('stale'); a.instance_id, r.instance_id = 'BOUND', 'BOUND'")
  T.eval("remuda._t.ls_calls = 0; remuda._t.real_ls = remuda.ls; remuda.ls = function() remuda._t.ls_calls = remuda._t.ls_calls + 1; error('ls unavailable', 0) end")
  T.eval("remuda._butler_session_exited('stale', { instance_id = 'OLD', reason = 'exited' })")
  local kept = ev("local a, r = remuda._t.agent('stale'); return tostring(a ~= nil and r ~= nil) .. ':' .. remuda._t.ls_calls")
  T.eval("remuda.ls = remuda._t.real_ls")
  T.eq(kept, "true:0", "an exit for another instance than the bound one is stale: ignored, with no ls call")
  T.eval("remuda._butler_session_exited('stale', { instance_id = 'BOUND', reason = 'exited' })")
  T.eq(ev("return tostring(remuda._butler_bus.agents.stale == nil)"), "true", "an exit by the bound instance is processed as today")
  T.eval("pcall(remuda.close, 'stale')") -- the simulated exit left the real session running
  launch("stale")
  T.eval("remuda._butler_session_exited('stale', { reason = 'exited' })")
  T.eq(ev("return tostring(remuda._butler_bus.agents.stale == nil)"), "true", "an exit without an instance id falls back to today's behavior")
  T.eval("return remuda.close('stale')")
end)

T.test("mutating_routes_refuse_when_caller_live_raises", function()
  launch("liveness")
  -- The snapshot and the bound id agree, but no such instance is live: core's _caller_live raises.
  T.eval("local a, r = remuda._t.agent('liveness'); a.instance_id, r.instance_id = 'NOT-LIVE', 'NOT-LIVE'")
  T.eval("remuda._t.guard_effects()")
  local before = ev("return remuda._t.snap()")
  local caller = snapshot_literal("liveness", "NOT-LIVE")
  for name, args in pairs({
    butler_send = { to = "butler", text = "x" }, butler_reply = { to = "butler", text = "x" },
    butler_forward = { message_id = "m", to = "butler" },
    butler_approve_text = { session = "butler", text = "prepared" },
    butler_launch = { kind = "codex", name = "nolaunch" },
    butler_delegate = { name = "nodelegate", task = "t", kind = "codex" },
    butler_close = { name = "butler" },
  }) do
    local args_literal = (function()
      local parts = {}
      for k, v in pairs(args) do parts[#parts + 1] = k .. " = " .. quote(v) end
      return "{ " .. table.concat(parts, ", ") .. " }"
    end)()
    local result = ev("return remuda._t.route(" .. quote(name) .. ", " .. args_literal .. ", " .. caller .. ")")
    T.ok(result:sub(1, 3) == "err", name .. " was admitted although _caller_live raises: " .. result)
    T.eq(ev("return remuda._t.snap()"), before, name .. " must have zero effects when _caller_live raises")
  end
  -- read-only routes compare the instance but do not need liveness
  T.ok(ev("return remuda._t.route('butler_inbox', {}, " .. caller .. ")") == "ok", "a read-only route needs only the compare")
  T.eval("remuda._t.unguard_effects()")
  T.eval("return remuda.close('liveness')")
end)

T.test("strict_lua_override_refuses_unbound_members", function()
  T.eval("remuda._t.world { ids = { 'OBS' }, no_id = true }")
  local ok, err = pcall(launch, "strictlua")
  T.eval("remuda._t.restore()")
  T.ok(ok, tostring(err))
  T.eq(admitted("strictlua", "OBS"), "strictlua", "default: an unbound member keeps legacy access")
  T.eval("remuda._butler_strict_instance_binding = true")
  local strict = admitted("strictlua", "OBS")
  T.eval("remuda._butler_strict_instance_binding = nil")
  T.eq(strict, "refused", "strict switch (Lua override): an unbound member is refused")
  T.eval("remuda._t.forget('strictlua')")
end)

T.test("root_adopted_after_reload_keeps_its_bound_id_only_if_token_and_row_agree", function()
  -- the respawn tests leave only fake root rows: wait for Butler to start a real root again
  T.wait_until(function()
    return ev("for _, r in ipairs(remuda.ls()) do if r.name == remuda._butler_name and r.alive and remuda._butler_selected_agent then return 'yes' end end return 'no'") == "yes"
  end, 30, "a real root session")
  local live = ev("for _, r in ipairs(remuda.ls()) do if r.name == remuda._butler_name and r.alive then return r.instance_id end end return 'none'")
  local function adopt(row_id, token_id)
    T.eval(string.format([[
      local root = remuda._butler_bus.agents.butler
      root.instance_id, remuda._butler_bus.tokens[root.token].instance_id = %s, %s
      remuda._butler_reconcile() -- live session + selected agent: the adoption branch, no chooser
    ]], row_id and quote(row_id) or "nil", token_id and quote(token_id) or "nil"))
    return ev("local root = remuda._butler_bus.agents.butler; return tostring(root.instance_id) .. ':' .. tostring(remuda._butler_bus.tokens[root.token].instance_id)")
  end
  T.eq(adopt(live, live), live .. ":" .. live, "agreeing token record and live row keep the bound id")
  T.eq(adopt("R1", "R2"), "nil:nil", "disagreeing token record and row: unbound")
  T.eq(adopt("STALE", "STALE"), "nil:nil", "record and row agree with each other but not with the live row: unbound")
end)

T.test("adopted_members_stay_unbound_and_never_bind_an_observed_id", function() -- regression guard: adoption never binds
  T.eval("remuda._t.world { ids = { 'OBS-LEAD', 'OBS-CHILD' }, no_id = true }")
  local ok, err = pcall(function() launch("lead"); T.eval("return remuda._butler_launch('codex', 'child', nil, 'lead')") end)
  T.wait_until(function() return ev("return tostring(remuda._butler_bus.agents.child ~= nil)") == "true" end, 5, "child")
  -- a pre-upgrade member: no bound id on the row or the capability
  T.eval("local a, r = remuda._t.agent('child'); a.instance_id, r.instance_id = nil, nil")
  T.eval("local lead = remuda._butler_bus.agents.lead; remuda._butler_adopt_members('lead', lead)")
  local seen = bound("child")
  T.eq(ev("return tostring(remuda._butler_bus.agents.child.parent)"), "butler", "the exited lead's member is handed to the root")
  T.eval("remuda._t.restore()")
  T.ok(ok, tostring(err))
  T.eq(seen, "nil:nil", "adoption must not bind an observed ls id")
  T.eq(admitted("child", "OBS-CHILD"), "child", "an adopted, unbound member stays legacy-visible")
  T.eval("remuda._t.forget('child')")
  T.eval("remuda._butler_bus.agents.lead = nil")
end)

T.test("doctor_lists_unbound_members_and_only_when_there_are_some", function()
  local function doctor() return ev("return tostring(remuda._butler_command_run('doctor', { 'doctor' }))") end
  T.eval([[
    for alias, a in pairs(remuda._butler_bus.agents) do a.instance_id = a.instance_id or 'X' end
    remuda._t.state_before = remuda._t.snap()
  ]])
  T.ok(not doctor():find("not instance-bound", 1, true), "no unbound member: no line")
  launch("unb1"); launch("unb2")
  T.eval([[
    for alias, a in pairs(remuda._butler_bus.agents) do a.instance_id = 'X' end
    remuda._butler_bus.agents.unb1.instance_id, remuda._butler_bus.agents.unb2.instance_id = nil, nil
  ]])
  local before = ev("return remuda._t.snap()")
  T.ok(doctor():find("2 members not instance-bound: relaunch to bind", 1, true), "doctor must count unbound members: " .. doctor())
  T.eq(ev("return remuda._t.snap()"), before, "doctor is read-only")
  T.eval("return remuda.close('unb1')"); T.eval("return remuda.close('unb2')")
end)
