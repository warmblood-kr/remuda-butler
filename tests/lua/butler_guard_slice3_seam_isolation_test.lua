-- #431: these tests install only the production artifact, even with the real legacy flag set.
T.child_env = { REMUDA_BUTLER_TEST = "1" }

T.test("production ignores every seam on direct load, first activation, re-evaluation and rollback", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  -- Agent-callable MCP evaluation before Butler's first lifecycle activation.
  local early_ok, early = pcall(T.mcp_eval, [[
    local getenv = os.getenv
    os.getenv = function(k) if k == 'REMUDA_BUTLER_TEST' then return '1' end return getenv(k) end
    local hits = 0
    local ok, err = pcall(function()
      local root = getenv('XDG_DATA_HOME') .. '/remuda/mods/butler/packages/butler/'
      dofile(root .. 'guard_policy.lua'); dofile(root .. 'guard_grants.lua')
      local g, p = remuda.butler.guard_grants, remuda.butler.guard_policy
      local function fake() hits = hits + 1; return 1 end
      g.now, g.insensitive, g.verified, g.git_budget_s, p.now = fake, fake, fake, 20, fake
      assert(math.abs(g.time() - os.time()) < 5 and math.abs(p.time() - os.time()) < 5)
      g.canonical(getenv('XDG_DATA_HOME') .. '/MixedCase')
      assert(hits == 0, 'pre-first MCP selected a field')
    end)
    os.getenv = getenv
    if not ok then error(err, 0) end
    return 'pre-first MCP'
  ]])
  local cli = T.eval([[
    local root = os.getenv('XDG_DATA_HOME') .. '/remuda/mods/butler/packages/butler/'
    local failures = {}
    local function check(label, fn)
      local ok, err = pcall(fn)
      if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
    end
    local function forged(value, fn)
      local getenv = os.getenv
      os.getenv = function(key)
        if key == 'REMUDA_BUTLER_TEST' then return value end
        return getenv(key)
      end
      local ok, err = pcall(fn)
      os.getenv = getenv
      if not ok then error(err, 0) end
    end
    local function poison()
      local g, p = remuda.butler.guard_grants, remuda.butler.guard_policy
      local hits = { now = 0, insensitive = 0, verified = 0, policy = 0 }
      g.now = function() hits.now = hits.now + 1; return os.time() + 1000 end
      g.insensitive = function() hits.insensitive = hits.insensitive + 1; return true end
      g.verified = function() hits.verified = hits.verified + 1; return true end
      g.git_budget_s = 20
      p.now = function() hits.policy = hits.policy + 1; return 1790000000 end
      return hits
    end
    local function ignored(label)
      local g, p = remuda.butler.guard_grants, remuda.butler.guard_policy
      local hits = poison()
      local dir = os.getenv('XDG_DATA_HOME') .. '/seam-isolation'
      remuda.mkdir(dir); remuda._butler_guard_dir = dir
      local f = assert(io.open(dir .. '/guard-grants.jsonl', 'w'))
      local t = os.time()
      -- Both current and shifted-clock records lack the required real approval.
      for i, offset in ipairs({ 0, 1000 }) do
        f:write(remuda.json.encode { id = 'g00' .. i, class = 'net', scope = 'a.test', ceiling = 'T2',
          holder = 'h', event = '$missing', written = t + offset, expires = t + offset + 100 }, '\n')
      end
      f:close()
      local active = #g.active()
      local gt, pt = g.time(), p.time()
      g.canonical(dir .. '/MixedCase')
      for seam, count in pairs(hits) do
        check(label .. '/' .. seam, function() assert(count == 0, 'selected injected field') end)
      end
      check(label .. '/approval', function() assert(active == 0, 'accepted unapproved record') end)
      check(label .. '/clocks', function()
        assert(math.abs(gt - os.time()) < 5 and math.abs(pt - os.time()) < 5, 'clock differs')
      end)
      -- The ordinary process/time collaborators are stubbed and restored in this evaluation.
      local run, time, enabled, active_fn, high = remuda.process.run, os.time, p.grants_enabled, g.active, g._clock.high
      local ok, err = pcall(function()
        local clock, calls = 1000, 0
        os.time = function() return clock end
        p.grants_enabled = function() return true end
        g.active = function() return { { id = 'g001', class = 'git', scope = '/work/repo' } } end
        remuda.process.run = function(o)
          assert(o.timeout == 2, 'command timeout changed')
          calls = calls + 1; clock = 1002
          return { code = 0, stdout = 'refs/heads/feat' }
        end
        for _, method in ipairs({ 'match', 'offer' }) do
          clock, calls = 1000, 0
          g._clock.high = 0
          g[method]('Bash', { command = 'git push' }, '/work/repo', 'push')
          check(label .. '/' .. method, function() assert(calls == 1, 'budget widened: ' .. calls) end)
        end
      end)
      remuda.process.run, os.time, p.grants_enabled, g.active = run, time, enabled, active_fn
      g._clock.high = high
      if not ok then error(err, 0) end
    end
    -- Before Butler's lifecycle entry has ever activated; direct installed-file loads.
    for _, value in ipairs({ false, '0', '1' }) do
      forged(value or nil, function()
        dofile(root .. 'guard_policy.lua'); dofile(root .. 'guard_grants.lua')
      end)
      ignored('pre-first/direct/' .. tostring(value))
    end
    remuda._butler_argv = { 'sh', '-c', 'sleep 60' }
    remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1
    forged('1', function() remuda.exec('butler') end)
    ignored('first activation')
    for _, value in ipairs({ false, '0', '1' }) do
      poison() -- old public fields survive module re-evaluation and must remain inert
      forged(value or nil, function()
        remuda.exec('butler/guard_policy'); remuda.exec('butler/guard_grants')
      end)
      ignored('native re-evaluation/' .. tostring(value))
    end
    forged('1', function() remuda.reload('butler') end)
    ignored('reload')
    local emit = remuda.emit
    remuda.emit = function(event, ...)
      if event == 'butler-start' then error('431 failed candidate') end
      return emit(event, ...)
    end
    local ok, err = pcall(function() forged('1', function() remuda.reload('butler') end) end)
    remuda.emit = emit
    assert(not ok and tostring(err):find('431 failed candidate', 1, true), 'rollback not exercised')
    ignored('rollback')
    remuda._431_ignored = function(label)
      local before = #failures
      ignored(label)
      assert(#failures == before, table.concat(failures, '\n', before + 1))
    end
    return #failures == 0 and 'ok' or table.concat(failures, '\n')
  ]])
  local mcp_ok, mcp = pcall(T.mcp_eval, [[
    local getenv = os.getenv
    os.getenv = function(k) if k == 'REMUDA_BUTLER_TEST' then return '1' end return getenv(k) end
    local ok, err = pcall(function()
      remuda.exec('butler/guard_policy'); remuda.exec('butler/guard_grants')
    end)
    os.getenv = getenv
    if not ok then error(err, 0) end
    remuda._431_ignored('MCP re-evaluation')
    assert(math.abs(remuda.butler.guard_grants.time() - os.time()) < 5)
    assert(math.abs(remuda.butler.guard_policy.time() - os.time()) < 5)
    return 'MCP production clocks'
  ]])
  T.eq(cli, "ok", 'CLI production matrix; MCP=' .. tostring(mcp))
  T.ok(early_ok and early:find('pre-first MCP', 1, true), tostring(early))
  T.ok(mcp_ok and mcp:find('MCP production clocks', 1, true), tostring(mcp))
end)
