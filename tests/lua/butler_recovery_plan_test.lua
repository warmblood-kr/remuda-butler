-- The explicit replacement decision against a real child daemon: it names the
-- exact instance, reuses the logical identity, and changes nothing. Run through
-- tests/lua_tests.sh.
local repo = assert(os.getenv("REMUDA_LUA_REPO"))
local started

local function start_butler()
  if started then return end
  started = true
  T.install_mod("butler", repo)
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "Butler root start")
end

-- One image, one moment: the registry row and the durable roster row.
local function root_state()
  local text = T.eval([[
    local row
    for _, item in ipairs(remuda.ls()) do
      if item.name == "butler" then row = item end
    end
    local entry
    for _, item in ipairs(remuda._butler_roster.load()) do
      if item.alias == "butler" then entry = item end
    end
    return table.concat({
      row and row.instance_id or "",
      tostring(row and row.alive),
      entry and entry.instance_id or "",
      entry and entry.id or "",
      entry and entry.cwd or "",
      entry and entry.kind or "",
    }, "|")
  ]])
  local fields = {}
  for field in (text .. "|"):gmatch("(.-)|") do fields[#fields + 1] = field end
  return { instance = fields[1], alive = fields[2], roster_instance = fields[3],
    id = fields[4], cwd = fields[5], kind = fields[6] }
end

-- Call the pure decision with the daemon's own registry and roster.
local function decide(name, instance, over)
  over = over or ""
  return T.eval(("return (function()\n"
    .. "  local plan, why = remuda._butler_session_recovery.decide({\n"
    .. "    name = %q, instance_id = %q, %s\n"
    .. "    rows = remuda.ls(), roster = remuda._butler_roster.load() })\n"
    .. "  if not plan then return 'REFUSED|' .. tostring(why and why.code) .. '|' .. tostring(why and why.text) end\n"
    .. "  return table.concat({ 'PLAN', plan.instance_id, plan.id, plan.alias, plan.agent,\n"
    .. "    plan.cwd, tostring(plan.declared_unreachable), tostring(plan.leader) }, '|')\n"
    .. "end)()"):format(name, instance, over))
end

local function fields(text)
  local out = {}
  for field in (text .. "|"):gmatch("(.-)|") do out[#out + 1] = field end
  return out
end

T.test("the decision names the exact instance and reuses the identity", function()
  start_butler()
  local state = root_state()
  assert(state.instance ~= "", "the root has a registry instance")
  T.eq(state.roster_instance, state.instance,
    "the roster binds the root to the live instance: " .. tostring(state.roster_instance)
      .. " vs " .. tostring(state.instance))
  -- The root's roster row has no cwd today (it is launched in the daemon's),
  -- so the decision refuses instead of inventing one; an explicit --workdir
  -- stands in for it, exactly as the operator would supply it.
  local refused = fields(decide("butler", state.instance, "unreachable = true,"))
  T.eq(refused[1], "REFUSED", "a missing workdir is refused, not guessed")
  T.eq(refused[2], "workdir_missing", "the refusal code names the missing field")
  local out = fields(decide("butler", state.instance, 'unreachable = true, workdir = "/srv/butler",'))
  T.eq(out[1], "PLAN", "the decision produced a plan: " .. tostring(out[3]))
  T.eq(out[2], state.instance, "the plan carries the exact instance")
  T.eq(out[3], state.id, "the plan reuses the durable id")
  T.eq(out[4], "butler", "the logical alias is unchanged")
  T.eq(out[5], state.kind, "the agent kind comes from the roster")
  T.eq(out[6], "/srv/butler", "the explicit workdir stands in for the missing one")
  T.eq(out[7], "true", "the operator's declaration is recorded")
  T.eq(out[8], "nil", "the root has no leader")
end)

T.test("the plan states the identity it keeps and the losses it cannot avoid", function()
  local state = root_state()
  local text = T.eval(("return (function()\n"
    .. "  local plan = assert(remuda._butler_session_recovery.decide({\n"
    .. "    name = 'butler', instance_id = %q, unreachable = true, workdir = '/srv/butler',\n"
    .. "    rows = remuda.ls(), roster = remuda._butler_roster.load() }))\n"
    .. "  return remuda._butler_session_recovery.render(plan)\n"
    .. "end)()"):format(state.instance))
  T.ok(text:find('Replace "butler"', 1, true) ~= nil, "the plan names the target")
  T.ok(text:find("instance  " .. state.instance, 1, true) ~= nil, "the plan carries the fence")
  T.ok(text:find("id        " .. state.id, 1, true) ~= nil, "the plan shows the reused id")
  T.ok(text:find("memory    unchanged", 1, true) ~= nil, "memory is unchanged")
  T.ok(text:find("mail      unchanged", 1, true) ~= nil, "mail is unchanged")
  T.ok(text:find("screen and scrollback", 1, true) ~= nil, "the losses are stated")
  T.ok(text:find("not proven dead", 1, true) ~= nil, "no death claim")
  T.ok(text:find("no kill and no launch", 1, true) ~= nil, "the plan performs nothing")
end)

T.test("a different instance, a missing declaration and an unknown name are refused", function()
  local state = root_state()
  local mismatch = fields(decide("butler", "not-" .. state.instance, 'unreachable = true, workdir = "/srv/butler",'))
  T.eq(mismatch[1], "REFUSED", "a mismatched instance is refused")
  T.eq(mismatch[2], "instance_mismatch", "the refusal code names the fence")
  T.ok(tostring(mismatch[3]):find("runs as instance", 1, true) ~= nil,
    "the refusal names the real instance: " .. tostring(mismatch[3]))

  local undeclared = fields(decide("butler", state.instance, 'workdir = "/srv/butler",'))
  T.eq(undeclared[1], "REFUSED", "no --unreachable is refused")
  T.eq(undeclared[2], "declaration_required", "the refusal asks for the declaration")

  local absent = fields(decide("no-such-session", "x", "unreachable = true,"))
  T.eq(absent[1], "REFUSED", "an unknown name is refused")
  T.eq(absent[2], "no_session", "the refusal says the session is absent")
end)

T.test("deciding changes nothing: the root is still the same live instance", function()
  local before = root_state()
  decide("butler", before.instance, 'unreachable = true, workdir = "/srv/butler",')
  local after = root_state()
  T.eq(after.instance, before.instance, "the instance is unchanged")
  T.eq(after.alive, "true", "the root is still alive")
  T.eq(after.id, before.id, "the durable id is unchanged")
end)
