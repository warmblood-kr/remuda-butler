-- Production ignores the field even if code reaches the table without spelling its literal module name.
T.child_env = { REMUDA_BUTLER_TEST = "0" }

T.test("production always uses the 2s git budget, regardless of injected value or spelling", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eq(T.eval([[
    remuda.exec('butler/guard_policy')
    remuda.exec('butler/guard_grants')
    local g, gp = remuda.butler['guard_' .. 'grants'], remuda.butler.guard_policy
    local run, time = remuda.process.run, os.time
    local active, enabled, budget = g.active, gp.grants_enabled, g.git_budget_s
    local ok, err = pcall(function()
      local clock, calls, elapsed = 1000, 0, 0
      os.time = function() return clock end
      gp.grants_enabled = function() return true end
      g.active = function() return { { id = 'g001', class = 'git', scope = '/work/repo' } } end
      remuda.process.run = function(o)
        assert(o.timeout == 2, 'production command timeout is 2s')
        calls = calls + 1
        if calls == 1 then clock = clock + elapsed end
        if o.argv[4] == 'symbolic-ref' then return { code = 0, stdout = 'refs/heads/feat' } end
        return { code = 1, stdout = '' } -- unset config, so no upstream/no grant
      end
      for _, method in ipairs({ 'match', 'offer' }) do
        local function probe(seconds)
          clock, calls, elapsed = 1000, 0, seconds
          assert(g[method]('Bash', { command = 'git push' }, '/work/repo', 'push') == nil,
            'missing upstream fails closed')
          return calls
        end
        g.git_budget_s = nil
        assert(probe(1) == 8 and probe(2) == 1, method .. ': unset production default')
        for _, value in ipairs({ math.huge, 1e300, 1, 20, 60, 0, -1, 61, -math.huge, 0/0, '2', 'bad', true, false, {} }) do
          g.git_budget_s = value
          assert(probe(1) == 8, method .. ': production override cannot shorten the 2s budget')
          assert(probe(2) == 1, method .. ': production override cannot lengthen the 2s budget')
        end
        g.git_budget_s = nil
        assert(probe(1) == 8 and probe(2) == 1, method .. ': reset production default')
      end
    end)
    remuda.process.run, os.time = run, time
    g.active, gp.grants_enabled, g.git_budget_s = active, enabled, budget
    if not ok then error(err, 0) end
    return 'ok'
  ]]), "ok", "production ignores the field")
end)
