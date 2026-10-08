-- Guard slice 3, PR3 review round 2 (SEC delta on #384), protected targets, eval classing, store bound, registration. Its own file: the harness gives a file 20s in all.
local function start_butler(no_register)
  T.install_guard_subject("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 5, "Butler root start")
  T.eval([[
    local gp = remuda.butler.guard_policy
    remuda._t_dir = function(name)
      local d = os.getenv('XDG_DATA_HOME') .. '/' .. name
      remuda.mkdir(d); remuda._butler_guard_dir = d; return d
    end
    remuda._t_hook = function(stdin)
      return remuda._butler_command_run('guard', {'guard'}, { kind = 'session', session = 's-ssa', stdin = stdin })
    end
    remuda._t_lines = function()
      local out, f = {}, io.open(gp.log_path(), 'r')
      if not f then return '' end
      for l in f:lines() do out[#out + 1] = l end
      f:close(); return table.concat(out, '\n')
    end
    remuda._t_guard = function(args, caller) caller = caller or {}; caller.kind = 'session'; caller.session = 'butler'; return remuda._butler_command_run('guard', args, caller) end
    return 'ok'
  ]])
  -- Butler's own load handed `add` to the owner-reaction handler; a fresh load of the store module hands it to the test.
  -- The store trusts Butler's approval record (tested in guard_slice3_reactions); these tests are about the store.
  if not no_register then T.eval("remuda.exec(\"butler/guard_grants\"); remuda.butler.guard_grants.verified = function() return true end; remuda.butler.guard_grants.register(function(add) remuda._t_add = add end)") end
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end

-- A scratch tree: ROOT/real/sub, ROOT/link -> real, ROOT/other. Sets G (the grants module) and ROOT.
local function tree(name)
  T.eval("remuda._t_dir(" .. string.format("%q", name) .. ")")
  T.eval("remuda.butler.guard_grants.insensitive = function() return false end") -- the fold has its own test
  return T.eval([[
    local root = remuda._butler_guard_dir .. '-tree' -- beside the data dir: the data dir is a protected scope
    remuda.process.run({ argv = { 'sh', '-c', 'mkdir -p ' .. root .. '/real/sub ' .. root .. '/other && ln -s real ' .. root .. '/link' } })
    remuda._t_root = remuda.fs.realpath(root)
    return remuda._t_root
  ]])
end
T.test("R2 MUST 2: a push from a protected place gets no grant even under a broad scope", function()
  start_butler()
  tree("g3p3-target")
  local home = T.eval("return remuda.butler.guard_grants.canonical(os.getenv('HOME'))")
  T.eval("remuda._t_guard({'guard','grants','on'})")
  T.eq(T.eval("return tostring(remuda._t_add({ class = 'git', scope = " .. string.format("%q", home .. "/projects/*")
    .. ", ceiling = 'T2', holder = 'ss-a', event = '$ev1', ttl = 3600 }))"), "g001", "a broad scope under the home is allowed")
  -- a fake git that finds a clean plain push on a feature branch, so only the cwd decides
  T.eval([[remuda._t_real_run = remuda.process.run
    remuda.process.run = function(o)
      local a = o.argv
      if a[1] == 'env' then return { code = 0, stdout = '' } end -- the diff
      if a[1] ~= 'git' then return remuda._t_real_run(o) end
      local sub, key = a[4], a[#a]
      if sub == 'symbolic-ref' then return key == 'HEAD' and { code = 0, stdout = 'refs/heads/feat\n' } or { code = 1, stdout = '' } end
      if sub == 'remote' then return { code = 0, stdout = 'origin\n' } end
      if key == 'branch.feat.remote' then return { code = 0, stdout = 'origin\n' } end
      if key == 'branch.feat.merge' then return { code = 0, stdout = 'refs/heads/feat\n' } end
      return { code = 1, stdout = '' }
    end]])
  local function w(cwd) return T.eval(("return tostring(remuda.butler.guard_grants.match('Bash', { command = 'git push' }, %q))"):format(cwd)) end
  T.eq(w(home .. "/projects/x/src"), "g001", "control: an ordinary directory is covered")
  T.eq(w(home .. "/projects/srv/x.gitignore/hooks"), "g001", "control: only a segment ending in .git is a git dir")
  local data = T.eval("return remuda.butler.guard_grants.canonical(remuda.butler.guard_policy.dir())")
  for _, bad in ipairs({ home .. "/projects/x/.git/hooks", home .. "/projects/x/.claude", home .. "/projects/x/y/.claude/z",
    home .. "/projects/.ssh", home .. "/projects/x/.CLAUDE", home .. "/projects/srv/x.git/hooks", home .. "/projects/srv/X.GIT/config" }) do
    T.eq(w(bad), "nil", "no grant: " .. bad)
  end
  -- places that are protected by location: the data dir and ~/.config/remuda, under a scope that reaches them
  local lax = T.eval(([[local g = remuda.butler.guard_grants
    local home, data = %q, %q
    local seen = {}
    local real = g.active
    g.active = function() return { { id = 'g777', class = 'git', scope = '/*' } } end
    local function t(p) return tostring(g.match('Bash', { command = 'git push' }, p)) end
    seen[1] = t(data); seen[2] = t(home .. '/.config/remuda/x'); seen[3] = t(home .. '/projects/ok')
    g.active = real
    remuda.process.run = remuda._t_real_run
    return table.concat(seen, ',')]]):format(home, data))
  T.eq(lax, "nil,nil,g777", "the data dir and ~/.config/remuda are protected targets even if a (hand-written) grant covers them", "ok - protected targets")
end)

T.test("R2 SHOULD a: remuda -e and --eval are scripts", function()
  start_butler()
  local out = T.eval([[local gp = remuda.butler.guard_policy
    local function c(cmd) return gp.classify('Bash', { command = cmd }, { home = '/h' }) end
    return table.concat({ c("remuda -e 'return 1'"), c("remuda --eval 'return 1'"), c("remuda -s x -e 'return 1'"), c('remuda ls') }, ',')]])
  T.eq(out, "script,script,script,other", "-e and --eval classify as script", "ok - eval spellings")
end)

T.test("R2 SHOULD c: the store is read through a bound; an oversize file is no grants (fail closed)", function()
  start_butler()
  local root = tree("g3p3-oversize")
  T.eval("remuda._t_guard({'guard','grants','on'}); remuda.butler.guard_grants.now = function() return 1790000000 end")
  local file = T.eval("return (remuda.butler.guard_policy.log_path():gsub('guard%-audit%.jsonl$', 'guard-grants.jsonl'))")
  local function active() return T.eval("return #remuda.butler.guard_grants.active()") end
  local line = ([[{"id":"g001","class":"writable","scope":%q,"ceiling":"T2","holder":"h","event":"$e","written":1790000000,"expires":1790003600}]]):format(root .. "/other")
  local function put(pad) T.eval(("local f = io.open(%q, 'w'); f:write(%q, '\\n', string.rep('x', %d)); f:close()"):format(file, line, pad)) end
  put(1000)
  T.eq(active(), "1", "control: a small store is read")
  put(256 * 1024 + 10)
  T.eq(active(), "0", "an oversize store grants nothing")
  T.eq(T.eval("return tostring(remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/real") .. ", ceiling = 'T2', holder = 'a', event = '$e', ttl = 60 }))"), "nil", "add refuses to extend an oversize store")
  local read = T.eval(("local real, most = io.open, 0; io.open = function(p, ...) local f, e = real(p, ...); if not f or not tostring(p):find('guard%%-grants') then return f, e end; return setmetatable({}, { __index = function(_, k) return function(_, n) if k == 'read' then most = math.max(most, tonumber(n) or math.huge) end; return f[k](f, n) end end }) end; remuda.butler.guard_grants.active(); io.open = real; return most"))
  T.expect(tonumber(read) and tonumber(read) <= 256 * 1024 + 1, "read at most MAX_FILE+1 bytes, asked for " .. tostring(read), "ok - bounded read")
end)

T.test("R2 SHOULD d: Makefile, GNUmakefile and justfile by basename at any depth; any */scripts/ segment", function()
  start_butler()
  local got = T.eval([[local g = remuda.butler.guard_grants
    local out = {}
    for _, n in ipairs({ 'sub/dir/Makefile', 'a/b/GNUmakefile', 'x/justfile', 'pkg/scripts/run.sh', 'a/b/scripts/c/d', 'scripts/x', 'Makefile.bak', 'mscripts/x', 'src/scripts.lua', '.github/workflows/x.yml', 'docs/.github/x.yml' }) do
      out[#out + 1] = tostring(g.touches_ci({ n })) end
    return table.concat(out, ',')]])
  T.eq(got, "true,true,true,true,true,true,false,false,false,true,false", "basename and segment matches", "ok - touches_ci nested")
end)

T.test("R2 SHOULD b: add is not on the module table; one registration hands it to the owner-reaction handler", function()
  start_butler(true)
  local root = tree("g3p3-register")
  -- One eval: a late reload of the mod (the second install) would run Butler's own registration in between.
  local out = T.eval([[remuda.exec("butler/guard_grants") -- a fresh load of the module: the registration is once per load
    local g = remuda.butler.guard_grants
    local r = { tostring(g.add) }
    r[#r + 1] = tostring(pcall(function() return g.add({ class = 'writable', scope = '/x/y', ceiling = 'T2', holder = 'a', event = '$e' }) end))
    r[#r + 1] = tostring(g.register('not a function'))
    r[#r + 1] = tostring(g.register(function(add) remuda._t_add = add end))
    r[#r + 1] = type(remuda._t_add)
    remuda._t_other = nil
    local ok = g.register(function(add) remuda._t_other = add end)
    r[#r + 1] = tostring(ok) .. tostring(remuda._t_other)
    return table.concat(r, ',')]])
  T.eq(out, "nil,false,nil,true,function,nilnil",
    "no add on the table, calling it fails, a non-function does not use the registration, the first handler is handed add, a second gets nothing")
  T.eval("remuda._t_guard({'guard','grants','on'})")
  T.eq(T.eval("return tostring(remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/other") .. ", ceiling = 'T2', holder = 'a', event = '$e', ttl = 60 }))"),
    "g001", "the handed add still works", "ok - register")
end)
