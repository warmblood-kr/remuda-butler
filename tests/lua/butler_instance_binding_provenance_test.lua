-- SEC #473 MUSTs 1-4 for the instance binding (PR B). Written before the fix: each test must fail on the
-- production it follows, for the reason named in its comment.
--   MUST 1: a binding exists only if it was taken from a remuda.new return (marker `instance_binding = 1` on the row
--           AND on its token record); PR A's observation-only fields are cleared on upgrade.
--   MUST 2: a proven root binding survives a same-head reload through init; anything else is cleared.
--   MUST 3: a supplied capability record must carry the matching id on the enforcing native-session path.
--   MUST 4: file-permission attribution uses the caller function captured at load, under pcall.
-- Every refusal asserts zero effects (mail, read-state, tokens, roster, approve_text requests, launches, closes).
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")
-- A reload rebuilds the agent builders: set the fake member command again after every init.
local function member_setup()
  T.eval(string.format([[
    remuda.butler.project_home(%q)
    remuda._butler_agent_builders.codex = function() return { "sleep", "60" } end
  ]], os.getenv("XDG_DATA_HOME") .. "/projects"))
end
member_setup()

T.eval([=[
  local t = {}
  remuda._t = t
  t.real = { new = remuda.new, ls = remuda.ls, close = remuda.close, caller = remuda.caller }
  -- A fake core registry for members that must be launched WITHOUT a returned id (a PR A-like member).
  function t.world(ids)
    local w = { rows = {}, ids = ids }
    t.w = w
    remuda.new = function(name)
      local id = table.remove(w.ids, 1)
      w.rows[name] = { name = name, alive = true, instance_id = id }
      return name -- an older core: the name only
    end
    remuda.ls = function(...)
      local out = {}
      for _, r in ipairs(t.real.ls(...)) do if not w.rows[r.name] then out[#out + 1] = r end end
      for _, r in pairs(w.rows) do out[#out + 1] = { name = r.name, alive = r.alive, instance_id = r.instance_id } end
      return out
    end
  end
  function t.restore() remuda.new, remuda.ls = t.real.new, t.real.ls; t.w = nil end
  function t.count(tbl) local n = 0; for _ in pairs(tbl) do n = n + 1 end; return n end
  function t.tool(name)
    for k, v in pairs(remuda.tools) do if k == name or (type(v) == "table" and v.name == name) then return v end end
  end
  function t.route(name, args, caller)
    local ok, err = pcall(t.tool(name).run, args, caller)
    return ok and "ok" or ("err:" .. tostring(err))
  end
  function t.prove(a, r, row_id, record_id)
    a.instance_id, r.instance_id = row_id, record_id or row_id
    a.instance_binding, r.instance_binding = 1, 1
  end
  function t.agent(name)
    local a = remuda._butler_bus.agents[name]
    local rec = a and remuda._butler_bus.tokens[a.token]
    return a, type(rec) == "table" and rec or nil
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
    local tokens = {}
    for k, v in pairs(bus.tokens) do
      tokens[#tokens + 1] = k .. "=" .. (type(v) == "table" and (tostring(v.id) .. "/" .. tostring(v.instance_id) .. "/" .. tostring(v.instance_binding)) or tostring(v))
    end
    table.sort(tokens)
    local roster = {}
    for k, a in pairs(bus.agents) do roster[#roster + 1] = k .. "=" .. tostring(a.instance_id) .. "/" .. tostring(a.instance_binding) end
    table.sort(roster)
    return table.concat(n, ":") .. ":" .. reads .. ":" .. bus.next .. ":" .. table.concat(tokens, ",") .. ":"
      .. table.concat(roster, ",") .. ":new=" .. (t.new_calls or 0) .. ":close=" .. (t.close_calls or 0)
      .. ":approve=" .. (remuda.butler.approve_text._test_request_count or 0)
  end
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
]=])

local function quote(value) return string.format("%q", value) end
local function ev(code) return (T.eval(code):gsub("%s+$", "")) end
local function launch(name)
  T.eval("return remuda._butler_launch('codex', " .. quote(name) .. ")")
  T.wait_until(function() return ev("return tostring(remuda._butler_bus.agents[" .. quote(name) .. "] ~= nil)") == "true" end,
    5, name .. " registered")
end
local function snapshot_literal(session, instance, capability)
  return "{ kind = 'session', session = " .. quote(session) .. (instance and (", instance_id = " .. quote(instance)) or "")
    .. (capability and (", capability = " .. quote(capability)) or "") .. " }"
end
local function admitted(session, instance, capability)
  return ev("local ok, who = pcall(remuda._butler_identity.caller_agent, " .. snapshot_literal(session, instance, capability)
    .. "); return ok and who or 'refused'")
end
local function tag(session, instance)
  return ev("return remuda._butler_caller_principal.resolve(" .. snapshot_literal(session, instance) .. ").tag")
end
local function bound(name) -- row id : record id
  return ev("local a, r = remuda._t.agent(" .. quote(name) .. "); return tostring(a and a.instance_id) .. ':' .. tostring(r and r.instance_id)")
end
-- Same-head reload through init: the image keeps the bus, main.lua runs again (init sets a fresh session marker).
-- Returns the number of remuda.new calls the reload made (a chooser run would make one).
local function reload()
  local marker = "return remuda._butler_bus.agents.butler.session_start_marker"
  local before = ev(marker)
  T.eval("remuda._t.spawns = 0; local n = remuda.new; remuda._t.unwrapped = n; remuda.new = function(...) remuda._t.spawns = remuda._t.spawns + 1; return n(...) end")
  T.eval('remuda.reload("butler")')
  T.wait_until(function() return ev(marker) ~= before end, 10, "init ran again")
  T.wait_until(function() return ev("return tostring(remuda._butler_launching)") == "nil" end, 10, "reload settled")
  local spawns = ev("return tostring(remuda._t.spawns)")
  T.eval("remuda.new = remuda._t.unwrapped")
  member_setup()
  return tonumber(spawns)
end

T.test("must3_supplied_capability_record_must_carry_the_matching_bound_id", function()
  launch("cap3")
  local id = ev("return remuda._butler_bus.agents.cap3.instance_id")
  local token = ev("return remuda._butler_bus.agents.cap3.token")
  T.ok(id ~= "nil", "a genuinely launched member is bound")
  T.eq(admitted("cap3", id), "cap3", "deliberate tokenless native-session admission stays")
  T.eq(admitted("cap3", id, token), "cap3", "a capability record with the matching id is admitted")
  T.eval("remuda._t.guard_effects()")
  local before = ev("return remuda._t.snap()")
  local cases = {
    { "different", "local c = {}; for k, v in pairs(remuda._t.saved_rec) do c[k] = v end; c.instance_id = 'OTHER'; remuda._butler_bus.tokens[%s] = c" },
    { "nil_id", "local c = {}; for k, v in pairs(remuda._t.saved_rec) do c[k] = v end; c.instance_id = nil; remuda._butler_bus.tokens[%s] = c" },
    { "missing", "remuda._butler_bus.tokens[%s] = nil" },
    { "legacy_string", "remuda._butler_bus.tokens[%s] = 'cap3'" },
    { "legacy_table", "remuda._butler_bus.tokens[%s] = { id = remuda._butler_bus.agents.cap3.id, generation = remuda._butler_bus.agents.cap3.session_start_marker }" },
  }
  for _, case in ipairs(cases) do
    local name, mutate = case[1], case[2]
    T.eval("remuda._t.saved_rec = remuda._butler_bus.tokens[" .. quote(token) .. "]; " .. mutate:format(quote(token)))
    local mutated = ev("return remuda._t.snap()")
    T.eq(admitted("cap3", id, token), "refused", name .. ": a supplied record without the matching id must not count as a capability")
    T.eq(ev("return remuda._t.route('butler_send', { to = 'butler', text = 'x' }, " .. snapshot_literal("cap3", id, token) .. "):sub(1, 3)"),
      "err", name .. ": a send through that record must be refused")
    T.eq(ev("return remuda._t.snap()"), mutated, name .. ": the refusal must leave mail, read-state, tokens, roster, launches and approvals alone")
    T.eval("remuda._butler_bus.tokens[" .. quote(token) .. "] = remuda._t.saved_rec")
    T.eq(ev("return remuda._t.snap()"), before, name .. ": test restored the record")
  end
  T.eval("remuda._t.unguard_effects()")
  T.eval("return remuda.close('cap3')")
end)

T.test("must1_pr_a_observation_fields_are_cleared_on_upgrade_and_never_enforce", function()
  -- PR A shape: row and record hold the id OBSERVED in ls later; the launch returned none, no provenance marker.
  T.eval("remuda._t.world({ 'OBS1' })")
  local ok, err = pcall(launch, "pra")
  T.ok(ok, tostring(err))
  T.eval("local a, r = remuda._t.agent('pra'); a.instance_id, r.instance_id = 'OBS1', 'OBS1'")
  T.eq(bound("pra"), "OBS1:OBS1", "precondition: PR A-shaped populated fields")
  reload()
  T.eval("remuda._t.restore()")
  T.eq(bound("pra"), "nil:nil", "upgrade must clear observation-only bindings from the row AND the token record")
  T.eq(admitted("pra", "ANYTHING"), "pra", "default: the member stays legacy-visible (name checks, no instance compare)")
  T.ok(ev("return tostring(remuda._butler_command_run('doctor', { 'doctor' }))"):find("members not instance-bound", 1, true),
    "doctor must count the cleared member as unbound")
  T.eval("remuda._butler_strict_instance_binding = true")
  local strict = admitted("pra", "OBS1")
  T.eval("remuda._butler_strict_instance_binding = nil")
  T.eq(strict, "refused", "strict: refused until relaunch")
  T.eq(bound("pra"), "nil:nil", "nothing derived from ls became bound by the migration")
  T.eval("local bus = remuda._butler_bus; local a = bus.agents.pra; bus.tokens[a.token] = nil; bus.agents.pra = nil")
end)

T.test("must1_doctor_and_enforcement_share_one_valid_binding_predicate", function()
  launch("pred")
  local function line() return ev("return tostring(remuda._butler_command_run('doctor', { 'doctor' }))"):match("(%d+) members not instance%-bound") or "none" end
  local function enforced(id) return tag("pred", id) end
  local id = ev("return remuda._butler_bus.agents.pred.instance_id")
  local base = line()
  -- an id with no marker (or an empty/non-string id) is neither enforced nor counted as bound
  for _, bad in ipairs({ "a.instance_binding = nil", "a.instance_id = ''", "a.instance_id = 7" }) do
    T.eval("local a = remuda._butler_bus.agents.pred; " .. bad)
    T.eq(tonumber(line() or 0), (tonumber(base) or 0) + 1, bad .. ": doctor must count the member unbound")
    T.eq(enforced("WHATEVER"), "member", bad .. ": and enforcement must treat it as legacy-visible (no instance compare)")
    T.eval("local a = remuda._butler_bus.agents.pred; a.instance_id, a.instance_binding = " .. quote(id) .. ", 1")
  end
  T.eq(enforced("WHATEVER"), "unidentified", "the proven binding is enforced")
  T.eval("return remuda.close('pred')")
end)

T.test("must1_a_proven_member_binding_survives_reload", function() -- guard: the migration must not clear PR B's own bindings
  launch("keep")
  local before = bound("keep")
  T.ok(before:match("^[^:]+:[^:]+$") and not before:find("nil", 1, true), "a genuine launch is bound: " .. before)
  reload()
  T.eq(bound("keep"), before, "a binding taken from the remuda.new return survives a later reload")
  T.eq(admitted("keep", before:match("^[^:]+")), "keep", "and still admits its own instance")
  T.eq(admitted("keep", "OTHER"), "refused", "and still refuses another")
  T.eval("return remuda.close('keep')")
end)

local function root_live_id()
  return ev("for _, r in ipairs(remuda.ls()) do if r.name == remuda._butler_name and r.alive then return r.instance_id end end return 'none'")
end
local function root_state()
  return ev("local root = remuda._butler_bus.agents.butler; local rec = remuda._butler_bus.tokens[root.token]; "
    .. "return tostring(root.instance_id) .. ':' .. tostring(rec and rec.instance_id)")
end
local function root_session() return ev("return remuda._butler_bus.agents.butler.session_name") end

T.test("must2_root_binding_survives_same_head_reload_through_init", function()
  T.wait_until(function()
    return ev("for _, r in ipairs(remuda.ls()) do if r.name == remuda._butler_name and r.alive and remuda._butler_selected_agent then return 'yes' end end return 'no'") == "yes"
  end, 30, "a real root session")
  local live = root_live_id()
  local session = root_session()
  local function prove(row, rec) -- the state a PR B launch leaves: both fields from the return, both marked
    T.eval(string.format([[
      local root = remuda._butler_bus.agents.butler
      local r = remuda._butler_bus.tokens[root.token]
      root.instance_id, r.instance_id = %s, %s
      root.instance_binding, r.instance_binding = 1, 1
    ]], quote(row), quote(rec)))
  end
  local function strip_marker()
    T.eval("local root = remuda._butler_bus.agents.butler; root.instance_binding = nil; remuda._butler_bus.tokens[root.token].instance_binding = nil")
  end
  -- the root as its genuine launch left it (no hand-written state): the binding survives the reload
  T.eq(root_state(), live .. ":" .. live, "precondition: the real root launch bound the returned id")
  T.eq(reload(), 0, "genuine root reload: no chooser run")
  T.eq(root_state(), live .. ":" .. live, "the root's own launch binding must survive the reload")
  -- coherent and proven: kept, enforcing, no chooser run
  prove(live, live)
  local before_token = ev("return remuda._butler_bus.agents.butler.token")
  T.eq(reload(), 0, "valid adoption must not spawn a new chooser candidate")
  T.eq(root_state(), live .. ":" .. live, "a coherent proven binding must survive the reload")
  T.eq(ev("return remuda._butler_bus.agents.butler.token"), before_token, "the root keeps its capability")
  T.eq(tag(session, live), "member", "default: the bound id is admitted")
  T.eq(tag(session, "OTHER"), "unidentified", "enforcing: another instance is refused")
  -- mismatched ids: both cleared, root legacy-visible by default and refused under strict
  prove(live, "OTHER")
  T.eq(reload(), 0, "no new chooser for a mismatched record")
  T.eq(root_state(), "nil:nil", "a mismatched record clears both fields")
  T.eq(tag(session, "ANY"), "member", "default: legacy-visible")
  T.eval("remuda._butler_strict_instance_binding = true")
  local strict = tag(session, live)
  T.eval("remuda._butler_strict_instance_binding = nil")
  T.eq(strict, "unidentified", "strict: refused until relaunch")
  -- PR A shaped (agreeing observation fields, no marker): cleared
  prove(live, live); strip_marker()
  T.eq(reload(), 0, "no new chooser for a PR A-shaped root")
  T.eq(root_state(), "nil:nil", "agreement of two unmarked observation fields is not proof")
  T.eq(tag(session, "ANY"), "member", "default: legacy-visible")
  T.eval("remuda._butler_strict_instance_binding = true")
  strict = tag(session, live)
  T.eval("remuda._butler_strict_instance_binding = nil")
  T.eq(strict, "unidentified", "strict: refused until relaunch")
end)

T.test("must2_adoption_rechecks_the_pair_if_the_record_drifts_after_init", function()
  local live = root_live_id()
  T.eval(string.format([[
    local root = remuda._butler_bus.agents.butler
    remuda._t.prove(root, remuda._butler_bus.tokens[root.token], %s, 'DRIFT')
    remuda._butler_reconcile() -- live session + selected agent: the adoption branch, no chooser
  ]], quote(live)))
  T.eq(root_state(), "nil:nil", "a live row whose record disagrees is not adopted as bound")
end)

T.test("must4_file_attribution_uses_the_caller_captured_at_load_under_pcall", function()
  local path = "/etc/hosts"
  local function attribute() return ev("local p, why = remuda._butler_file_for_caller('" .. path .. "', '--file ', false); return tostring(p) .. '|' .. tostring(why)") end
  local function load_with(fn_source)
    T.eval("remuda.caller = " .. fn_source)
    reload()
  end
  -- captured = outside; a later swap to a refusing caller must not be consulted
  load_with("function() return { kind = 'outside' } end")
  T.eval("remuda.caller = function() return { kind = 'session', session = 'nobody' } end")
  T.eq(attribute(), path .. "|nil", "the caller captured at load decides, not a later remuda.caller")
  -- captured = raising: refuse, even though a permissive caller appears later
  load_with("function() error('caller unavailable', 0) end")
  T.eval("remuda.caller = function() return { kind = 'outside' } end")
  T.ok(attribute():find("^nil|refused:"), "a raising captured caller must refuse: " .. attribute())
  -- captured = absent
  load_with("nil")
  T.eval("remuda.caller = function() return { kind = 'outside' } end")
  T.ok(attribute():find("^nil|refused:"), "an unavailable captured caller must refuse: " .. attribute())
  T.eval("remuda.caller = remuda._t.real.caller")
  reload()
end)

-- MUST 4 remainder: the two other production readers of the core's caller use the same load-time capture.
local function load_caller(fn_source)
  T.eval("remuda.caller = " .. fn_source)
  reload()
end
local function restore_caller()
  T.eval("remuda.caller = remuda._t.real.caller")
  reload()
end

T.test("must4_sandbox_caller_is_agent_uses_the_caller_captured_at_load", function()
  local function is_agent() return ev("return tostring(remuda._butler_sandbox.caller_is_agent())") end
  -- captured = session: a later swap to outside must not turn the agent into a person
  load_caller("function() return { kind = 'session', session = 'x' } end")
  T.eval("remuda.caller = function() return { kind = 'outside' } end")
  T.eq(is_agent(), "true", "the caller captured at load decides (agent), not a later remuda.caller")
  -- captured = outside: a later swap to a session must not make it an agent
  load_caller("function() return { kind = 'outside' } end")
  T.eval("remuda.caller = function() return { kind = 'session', session = 'x' } end")
  T.eq(is_agent(), "false", "the caller captured at load decides (person), not a later remuda.caller")
  -- captured = raising / absent: unavailable keeps the current policy (not an agent); a later caller is not consulted
  load_caller("function() error('caller unavailable', 0) end")
  T.eval("remuda.caller = function() return { kind = 'session', session = 'x' } end")
  T.eq(is_agent(), "false", "a raising captured caller is unavailable; a later session caller is not consulted")
  load_caller("nil")
  T.eval("remuda.caller = function() return { kind = 'session', session = 'x' } end")
  T.eq(is_agent(), "false", "an absent captured caller is unavailable; a later session caller is not consulted")
  restore_caller()
end)

T.test("must4_guard_grants_holders_uses_the_caller_captured_at_load", function()
  local function holders()
    return ev("local h = remuda.butler.guard_grants.holders(); return h and table.concat(h, ',') or 'nil'")
  end
  local function roster()
    T.eval([[remuda._butler_bus.agents.hx = { id = 'U-HX', alias = 'hx', session_name = 's-hx', children = {} }
      remuda._butler_bus.agents.hy = { id = 'U-HY', alias = 'hy', session_name = 's-hy', children = {} }]])
  end
  load_caller("function() return { kind = 'session', session = 's-hx' } end")
  roster()
  T.eval("remuda.caller = function() return { kind = 'session', session = 's-hy' } end")
  T.eq(holders(), "U-HX", "the caller captured at load names the holder, not a later remuda.caller")
  load_caller("function() error('caller unavailable', 0) end")
  roster()
  T.eval("remuda.caller = function() return { kind = 'session', session = 's-hy' } end")
  T.eq(holders(), "nil", "a raising captured caller yields no holder, even with a permissive caller later")
  load_caller("nil")
  roster()
  T.eval("remuda.caller = function() return { kind = 'session', session = 's-hy' } end")
  T.eq(holders(), "nil", "an absent captured caller yields no holder, even with a permissive caller later")
  restore_caller()
end)
