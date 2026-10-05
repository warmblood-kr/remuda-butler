-- Guard slice 3 (SEC on #384, round 4): `remuda` segment classing. A butler verb keeps its higher-risk class
-- even when a later word looks like a script marker (run, -ex).
local function classes(cmds)
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 5, "Butler root start")
  local lit = {}
  for i, c in ipairs(cmds) do lit[i] = string.format("%q", c) end
  return T.eval(([[local gp = remuda.butler.guard_policy
    local r = {}
    for _, c in ipairs({ %s }) do r[#r + 1] = gp.classify('Bash', { command = c }, { home = '/h' }) end
    return table.concat(r, ',')]]):format(table.concat(lit, ", ")))
end

T.test("MUST: a butler verb outranks a trailing script marker; -e/eval before it stay script", function()
  local out = classes({ "remuda butler guard off run", "remuda butler matrix leave ROOM -ex", "remuda butler approve ID run",
    "remuda butler close run", "remuda butler send worker run the tests", "remuda -e 'return 1'", "remuda eval 'return 1'" })
  T.eq(out, "weaken,identity,identity,control,other,script,script", "higher-risk class wins; an ordinary send stays other", "ok - precedence")
end)
