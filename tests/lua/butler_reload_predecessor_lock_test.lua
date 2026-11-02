-- `remuda reload` (remuda#713): the new daemon boots Butler while the daemon it
-- replaced can still hold this home's locks. Butler waits for that predecessor
-- (socket handed over by a reload AND holder pid == this daemon's parent) and
-- stands by for any other holder, as before.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 10, "Butler root start")

-- Runs claim_after_reload against scripted claim answers; restores the guard.
local function run(case)
  return T.eval([[
    local guard = remuda.butler.guard
    local saved = { claim = guard.claim, reload = guard.handed_by_reload, parent = guard.parent_pid,
      wait = guard.predecessor_wait_s }
    local case = ]] .. case .. [[
    local claims, probes = 0, 0
    guard.claim = function()
      claims = claims + 1
      local answer = case.claims[math.min(claims, #case.claims)]
      if answer == "owner" then return { owner = true, guarded = true, handles = {} } end
      return { owner = false, guarded = true, held = true, pid = answer }
    end
    guard.handed_by_reload = function() return case.reload end
    guard.parent_pid = function() probes = probes + 1; return case.parents[math.min(probes, #case.parents)] end
    guard.predecessor_wait_s = case.wait or 5
    local ok, state = pcall(guard.claim_after_reload, {})
    guard.claim, guard.handed_by_reload, guard.parent_pid = saved.claim, saved.reload, saved.parent
    guard.predecessor_wait_s = saved.wait
    if not ok then return "error " .. tostring(state) end
    return (state.owner and "owner" or ("held:" .. tostring(state.pid))) .. " claims=" .. claims
  ]])
end

T.test("a_reload_predecessor_is_waited_for_then_replaced", function()
  T.eq(run('{ reload = true, parents = { "4242" }, claims = { "4242", "4242", "owner" } }'), "owner claims=3")
end)

T.test("a_predecessor_that_exits_before_the_probe_is_replaced_at_once", function()
  -- The probe already sees init (1) as the parent; the second claim gets the lock.
  T.eq(run('{ reload = true, parents = { "1" }, claims = { "4242", "owner" } }'), "owner claims=2")
end)

T.test("a_holder_that_is_not_the_parent_is_not_waited_for", function()
  T.eq(run('{ reload = true, parents = { "777", "777" }, claims = { "4242" } }'), "held:4242 claims=2")
end)

T.test("without_a_reload_handover_any_holder_means_standby", function()
  T.eq(run('{ reload = false, parents = { "4242" }, claims = { "4242", "owner" } }'), "held:4242 claims=1")
end)

T.test("a_predecessor_that_never_lets_go_is_given_up_on", function()
  local out = run('{ reload = true, wait = 0.3, parents = { "4242" }, claims = { "4242" } }')
  T.ok(out:match("^held:4242 claims=%d+$"), "bounded wait ends held: " .. out)
end)

T.test("this_daemon_answers_both_probes", function()
  -- A harness daemon was not reloaded: no handover, and a parent pid in digits.
  local out = T.eval([[
    local guard = remuda.butler.guard
    return tostring(guard.handed_by_reload()) .. " " .. tostring(guard.parent_pid() ~= nil)
  ]])
  T.eq(out, "false true")
end)
