-- The budget seam is an in-process field, independent of the existing grant-store test flag.
T.child_env = { REMUDA_BUTLER_TEST = "0" }

T.test("git budget defaults to 2s, can be shortened/lengthened/reset, and always fails closed", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eq(T.eval([[
    remuda.exec('butler/guard_policy')
    remuda.exec('butler/guard_grants')
    local g, gp = remuda.butler.guard_grants, remuda.butler.guard_policy
    assert(g.git_budget_s == nil, 'no budget override by default')
    local run, time = remuda.process.run, os.time
    local active, canonical, scope, enabled = g.active, g.canonical, g.scope, gp.grants_enabled
    local budget = g.git_budget_s
    local ok, err = pcall(function()
      local clock, calls, elapsed, failure = 1000, 0, 0, nil
      os.time = function() return clock end
      gp.grants_enabled = function() return true end
      g.active = function() return { { id = 'g001', class = 'git', scope = '/work/repo' } } end
      g.canonical = function(p) return p end
      g.scope = function(_, p) return p end
      remuda.process.run = function(o)
        assert(o.timeout == 2, 'per-command timeout must remain 2s with any budget')
        calls = calls + 1
        if calls == 1 then
          clock = clock + elapsed
          if failure == 'throw' then error('git failed') end
          if failure == 'timeout' then return { code = 0, timed_out = true, stdout = 'refs/heads/feat' } end
          if failure == 'exit' then return { code = 128, stdout = '' } end
        end
        local a, key = o.argv, o.argv[#o.argv]
        if a[1] == 'env' then
          if failure == 'diff-timeout' then return { code = 0, timed_out = true, stdout = '' } end
          if failure == 'diff-exit' then return { code = 128, stdout = '' } end
          return { code = 0, stdout = '' }
        end
        if a[4] == 'symbolic-ref' then
          return key == 'HEAD' and { code = 0, stdout = 'refs/heads/feat' } or { code = 1, stdout = '' }
        end
        if a[4] == 'remote' then return { code = 0, stdout = 'origin' } end
        if key == 'branch.feat.remote' then return { code = 0, stdout = 'origin' } end
        if key == 'branch.feat.merge' then return { code = 0, stdout = 'refs/heads/feat' } end
        return { code = 1, stdout = '' }
      end
      for _, method in ipairs({ 'match', 'offer' }) do
        local function probe(seconds, fail)
          clock, calls, elapsed, failure = 1000, 0, seconds, fail
          local result = g[method]('Bash', { command = 'git push' }, '/work/repo', 'push')
          if result then
            if method == 'match' then assert(result == 'g001')
            else assert(result.class == 'git' and result.scope == '/work/repo' and result.ceiling == 'T2') end
          end
          return result
        end
        g.git_budget_s = nil
        assert(probe(1) ~= nil, method .. ': default permits work before 2s')
        assert(calls == (method == 'match' and 12 or 11), 'all probes ran')
        assert(probe(2) == nil and calls == 1, method .. ': default stops at 2s')
        g.git_budget_s = 1
        assert(probe(1) == nil and calls == 1, method .. ': explicit shorter budget')
        g.git_budget_s = 20
        assert(probe(2) ~= nil, method .. ': explicit longer budget')
        assert(probe(20) == nil and calls == 1, method .. ': longer budget still expires')
        for _, fail in ipairs({ 'throw', 'timeout', 'exit', 'diff-timeout', 'diff-exit' }) do
          if method == 'match' or not fail:find('diff', 1, true) then
            assert(probe(0, fail) == nil, method .. ': fail closed on ' .. fail)
          end
        end
        g.git_budget_s = nil
        assert(probe(2) == nil and calls == 1, method .. ': reset restores 2s')
        -- An expired invocation must leave no deadline behind for a standalone diff.
        assert(g.diff_names('/work/repo') ~= nil and calls == 2, 'deadline reset after invocation')
      end
      assert(gp.deny_reason('mcp__remuda__run_script',
        { code = 'remuda.butler.guard_grants.git_budget_s = 20' }, {}) == 'Butler grant store')
      assert(gp.deny_reason('Bash',
        { command = 'remuda -e "remuda.butler.guard_grants.git_budget_s = 20"' }, {}) == 'Butler grant store')
    end)
    remuda.process.run, os.time = run, time
    g.active, g.canonical, g.scope, gp.grants_enabled = active, canonical, scope, enabled
    g.git_budget_s = budget
    if not ok then error(err, 0) end
    return 'ok'
  ]]), "ok", "budget and timeout contract")
end)
