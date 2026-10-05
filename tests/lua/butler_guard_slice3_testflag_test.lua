-- Guard slice 3, PR5 SEC: the grant-store test seams follow the process env captured at module load
-- (REMUDA_BUTLER_TEST=1, set by the harness for the child), never the mutable remuda._butler_test field.
-- This file runs the child in production mode: the env flag is off.
T.child_env = { REMUDA_BUTLER_TEST = "0" }
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

T.test("setting remuda._butler_test later does not switch the grant-store seams on", function()
  start_butler()
  T.eval([[local gg, d = remuda.butler.guard_grants, os.getenv('XDG_DATA_HOME') .. '/r-flag'
    remuda.mkdir(d); remuda._butler_guard_dir = d
    local t = os.time()
    local f = io.open(d .. '/guard-grants.jsonl', 'w')
    f:write(remuda.json.encode({ id = 'g001', class = 'net', scope = 'a.test', ceiling = 'T2', holder = 'h', event = '$e',
      written = t + 990, expires = t + 1100 }), '\n')
    f:close()
    remuda._butler_test = true
    gg.verified = function() return true end
    gg.now = function() return t + 1000 end
    gg.insensitive = function() return true end]])
  T.eq(T.eval("return #remuda.butler.guard_grants.active()"), "0", "a hand-written line is no grant, flag and seams or not")
  T.eq(T.eval("return tostring(math.abs(remuda.butler.guard_grants.time() - os.time()) < 5)"), "true", "the clock seam is ignored")
  T.expect(true, "", "ok - flag captured at load")
end)

T.test("command text naming the test flag or its env var is denied like the grant store", function()
  start_butler()
  local out = T.eval([[local gp = remuda.butler.guard_policy
    local function d(tool, input) return tostring(gp.deny_reason(tool, input, { home = '/h' })) end
    return table.concat({ d('mcp__remuda__run_script', { code = 'remuda._butler_test = true' }),
      d('mcp__remuda__run_script', { code = 'return os.getenv("REMUDA_BUTLER_TEST")' }),
      d('Bash', { command = 'REMUDA_BUTLER_TEST=1 remuda butler guard grants' }),
      d('Bash', { command = "remuda eval 'remuda._butler_test = true'" }) }, '|')]])
  T.eq(out, "Butler grant store|Butler grant store|Butler grant store|Butler grant store", "all four denied", "ok - text deny")
end)

T.test("SHOULD c: plain reads that mention the grant store or the test flag are not denied; code and data-dir writes are", function()
  start_butler()
  local out = T.eval([[local gp = remuda.butler.guard_policy
    local function d(tool, input) return tostring(gp.deny_reason(tool, input, { home = '/h' })) end
    local data = gp.dir() or '/x/butler'
    return table.concat({
      d('Bash', { command = 'git diff packages/butler/guard_grants.lua' }),
      d('Bash', { command = 'rg guard_grants packages' }),
      d('Bash', { command = 'rg _butler_test tests' }),
      d('Bash', { command = 'grep -n REMUDA_BUTLER_TEST docs/butler.md' }),
      d('Bash', { command = 'remuda -e "remuda.butler.guard_grants.add{}"' }),
      d('Bash', { command = "remuda lua -e 'remuda._butler_test = true'" }),
      d('mcp__remuda__run_script', { code = 'return remuda.butler.guard_grants' }),
      d('Bash', { command = 'echo x >> ' .. data .. '/guard-grants.jsonl' }) }, '|')]])
  T.eq(out, "nil|nil|nil|nil|Butler grant store|Butler grant store|Butler grant store|Protected settings or directory write",
    "reads pass, code and data writes are denied", "ok - text deny scope")
end)
