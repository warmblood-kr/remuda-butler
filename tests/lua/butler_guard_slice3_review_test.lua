-- Guard slice 3, PR4 review round (SEC on #387): audit events counted by name, test seams only under a test
-- flag, approval records kept at least as long as the longest grant.
local started
local function start_butler()
  if started then return end
  started = true
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 5, "Butler root start")
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end

T.test("guard stats counts the grant events by name, not as other", function()
  start_butler()
  T.eval("local d = os.getenv('XDG_DATA_HOME') .. '/r-stats'; remuda.mkdir(d); remuda._butler_guard_dir = d")
  T.eval("remuda._butler_command_run('guard', {'guard', 'on'}, {})")
  for _, e in ipairs({ "approval_limited", "grant_created", "grant_refused", "grant_register_refused" }) do
    T.eval(("remuda.butler.guard_policy.observe(%q, 's', 'claude', 'x')"):format(e))
  end
  local out = T.eval("return remuda._butler_command_run('guard', {'guard', 'stats'}, {})")
  for _, e in ipairs({ "approval_limited", "grant_created", "grant_refused", "grant_register_refused" }) do
    T.expect(has(out, "event " .. e .. ": 1"), e .. " counted by name:\n" .. out)
  end
  T.expect(not has(out, "event other"), "none counted as other:\n" .. out, "ok - stats events")
end)
