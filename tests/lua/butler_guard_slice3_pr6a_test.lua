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

local function deny(tool, input) return T.eval(("return tostring(remuda.butler.guard_policy.deny_reason(%q, %s, { home = '/h' }))"):format(tool, input)) end

T.test("guard stats counts owner_line_refused and grants_unfreeze_failed by name", function()
  start_butler()
  T.eval("local d = os.getenv('XDG_DATA_HOME') .. '/r-stats6'; remuda.mkdir(d); remuda._butler_guard_dir = d")
  T.eval("remuda._butler_command_run('guard', {'guard', 'on'}, {kind='session', session='butler'})")
  for _, e in ipairs({ "owner_line_refused", "grants_unfreeze_failed" }) do
    T.eval(("remuda.butler.guard_policy.observe(%q, 's', 'claude', 'x')"):format(e))
  end
  local out = T.eval("return remuda._butler_command_run('guard', {'guard', 'stats'}, {})")
  T.expect(has(out, "event owner_line_refused: 1") and has(out, "event grants_unfreeze_failed: 1"), "by name:\n" .. out)
  T.expect(not has(out, "event other"), "none as other:\n" .. out, "ok - stats")
end)

T.test("text deny sees a here-doc or piped body that names the grant store", function()
  start_butler()
  T.eq(deny("Bash", "{ command = \"remuda lua /dev/stdin <<'EOF'\\nremuda.butler.guard_grants.add()\\nEOF\" }"), "Butler grant store", "here-doc")
  T.eq(deny("Bash", "{ command = \"printf 'guard_grants' | remuda lua /dev/stdin\" }"), "Butler grant store", "pipe")
  T.eq(deny("Bash", "{ command = 'git diff' }"), "nil", "git diff")
  T.eq(deny("Bash", "{ command = 'rg guard_grants packages' }"), "nil", "rg", "ok - heredoc deny")
end)

T.test("script markers are read only at the verb: a message that says run is not a script", function()
  start_butler()
  T.eq(deny("Bash", "{ command = 'remuda send NAME please run the guard_grants test' }"), "nil", "send ... run")
  T.eq(deny("Bash", "{ command = \"remuda run 'guard_grants'\" }"), "Butler grant store", "run is the verb")
  T.eq(deny("Bash", "{ command = \"remuda -s srv lua -e guard_grants\" }"), "Butler grant store", "option before verb", "ok - verb only")
end)

T.test("every remuda option that takes a value is skipped to find the verb", function()
  start_butler()
  for _, o in ipairs({ "-s", "-c", "--server", "--config", "--runtime-dir", "--socket", "--data-home" }) do
    T.eq(deny("Bash", ("{ command = 'remuda %s /x lua guard_grants' }"):format(o)), "Butler grant store", o .. " VALUE")
  end
  for _, o in ipairs({ "--server", "--config", "--runtime-dir", "--socket", "--data-home" }) do
    T.eq(deny("Bash", ("{ command = 'remuda %s=/x lua guard_grants' }"):format(o)), "Butler grant store", o .. "=VALUE")
  end
  T.eq(deny("Bash", "{ command = 'remuda --socket /x send NAME run guard_grants' }"), "nil", "still a message", "ok - option values")
end)
