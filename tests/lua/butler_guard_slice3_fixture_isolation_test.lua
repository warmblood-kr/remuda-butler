-- #431: no fixture is installed or auto-selected by a normal production install.
T.test("normal installed package excludes fixture hooks and production entry accepts no injection", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eq(T.eval([[
    local root = os.getenv('XDG_DATA_HOME') .. '/remuda/mods/butler'
    assert(io.open(root .. '/tests/lib/guard_subject.lua', 'r') == nil, 'fixture bundled')
    local function inspect(path)
      assert(not path:find('subject') and not path:find('fixture') and not path:find('/tests/'),
        'installed hook: ' .. path)
      local dir, entries = pcall(remuda.list_dir, path)
      if dir then for _, name in ipairs(entries) do inspect(path .. '/' .. name) end; return end
      local f = assert(io.open(path, 'r'))
      local source = f:read('a'); f:close()
      assert(not source:find('tests/lib', 1, true), 'production searches for test hooks')
      if path:match('/guard_grants.lua$') or path:match('/guard_policy.lua$') then
        assert(not source:find('TEST_MODE', 1, true), 'shipped mode selector')
        assert(not source:find('seam(', 1, true), 'shipped field selector')
        assert(not source:find('git_budget_s', 1, true), 'shipped budget hook')
      end
    end
    inspect(root .. '/packages')
    local hooks = { now = function() return 1 end, verified = function() return true end,
      insensitive = function() return true end, git_budget_s = 20 }
    remuda.exec('butler/guard_policy', hooks); remuda.exec('butler/guard_grants', hooks)
    remuda.butler.guard_grants.now = hooks.now
    remuda.butler.guard_policy.now = hooks.now
    assert(math.abs(remuda.butler.guard_grants.time() - os.time()) < 5)
    assert(math.abs(remuda.butler.guard_policy.time() - os.time()) < 5)
    return 'ok'
  ]]), "ok")
end)

T.test("explicit subject restores the loader on errors and native production loads replace its functions", function()
  T.eval('remuda._431_native_exec = remuda.exec')
  T.install_guard_subject('butler', assert(os.getenv('REMUDA_LUA_REPO')))
  T.eq(T.eval([[
    remuda.exec('butler/guard_policy'); remuda.exec('butler/guard_grants')
    local g, p = remuda.butler.guard_grants, remuda.butler.guard_policy
    g.now = function() return 1790000000 end; p.now = g.now
    assert(g.time() == 1790000000 and p.time() == 1790000000, 'explicit subject was not loaded')
    local root = os.getenv('XDG_DATA_HOME') .. '/remuda/mods/butler/packages/butler/'
    dofile(root .. 'guard_policy.lua'); dofile(root .. 'guard_grants.lua')
    g, p = remuda.butler.guard_grants, remuda.butler.guard_policy -- policy replaces its table on load
    assert(math.abs(g.time() - os.time()) < 5 and math.abs(p.time() - os.time()) < 5,
      'native production retained a test closure')
    return 'ok'
  ]]), 'ok')
  local ok, err = pcall(T.eval, "error('431 subject cleanup')")
  T.ok(not ok and tostring(err):find('431 subject cleanup', 1, true), 'error control')
  T.ok(T.mcp_eval([[
    assert(remuda.exec == remuda._431_native_exec, 'subject loader leaked past evaluation')
    return 'restored'
  ]]):find('restored', 1, true), 'loader restored after error')
end)
