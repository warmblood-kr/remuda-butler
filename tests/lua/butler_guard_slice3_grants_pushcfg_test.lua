-- Guard slice 3, PR3 (push config half): git config that redirects a push, and the CI path list.
local function start_butler(no_register)
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
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
      return remuda._butler_command_run('guard', {'guard'}, { stdin = stdin, env =
        { REMUDA_BUTLER_AGENT_ALIAS = 'ss-a', REMUDA_BUTLER_AGENT_KIND = 'claude' } })
    end
    remuda._t_lines = function()
      local out, f = {}, io.open(gp.log_path(), 'r')
      if not f then return '' end
      for l in f:lines() do out[#out + 1] = l end
      f:close(); return table.concat(out, '\n')
    end
    remuda._t_guard = function(args, caller) return remuda._butler_command_run('guard', args, caller or {}) end
    return 'ok'
  ]])
  if not no_register then T.eval("remuda.butler.guard_grants.register(function(add) remuda._t_add = add end)") end
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

-- Review fixes (SEC on #384). A bare repo + clone with one pushed commit; returns work dir, a shell runner and the hook helpers.
local function git_fixture(name)
  start_butler()
  local root = tree(name)
  local g = T.eval([[
    local script = table.concat({ 'set -e', 'cd ' .. remuda._t_root,
      'git init -q --bare remote.git', 'git clone -q remote.git work 2>/dev/null', 'cd work',
      'git config user.email t@t; git config user.name t', 'echo a > a; git add a; git commit -q -m a',
      'git push -q -u origin HEAD 2>/dev/null' }, '\n')
    local r = remuda.process.run({ argv = { 'sh', '-c', script } })
    return tostring(r.code) .. ' ' .. tostring(r.stderr)]])
  T.expect(g:match("^0"), "git fixture: " .. g)
  local work = root .. "/work"
  local function sh(script) return T.eval(("local r = remuda.process.run({ argv = { 'sh', '-c', %q } }); return tostring(r.code)"):format("set -e; cd " .. work .. "; " .. script)) end
  T.eval("remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','grants','on'})")
  T.eval("remuda._t_add({ class = 'git', scope = " .. string.format("%q", work)
    .. ", ceiling = 'T2', holder = 'ss-a', event = '$ev1', ttl = 3600 })")
  return work, sh
end
local function grant_for(command, cwd)
  return T.eval(("return tostring(remuda.butler.guard_grants.match('Bash', { command = %q }, %q))"):format(command, cwd))
end

T.test("round 3: a push to remote.pushDefault or branch.<b>.pushRemote is no grant (git pushes there, not to the upstream)", function()
  local work, sh = git_fixture("g3p3-pushremote")
  T.eq(sh("git init -q --bare ../second.git; git remote add second ../second.git; git push -q second HEAD 2>/dev/null"), "0", "second remote")
  T.eq(sh("mkdir -p .github/workflows; echo x > .github/workflows/ci.yml; git add .; git commit -q -m ci; git push -q 2>/dev/null"), "0", "CI change reaches origin only")
  T.eq(grant_for("git push", work), "g001", "baseline: the upstream already has it, so a plain push is covered")
  T.eq(sh("git config remote.pushDefault second"), "0", "pushDefault")
  T.eq(grant_for("git push", work), "nil", "pushDefault redirects the push: no grant")
  T.eq(sh("git config --unset remote.pushDefault; git config branch.$(git symbolic-ref --short HEAD).pushRemote second"), "0", "pushRemote")
  T.eq(grant_for("git push", work), "nil", "branch pushRemote redirects the push: no grant", "ok - push remote")
end)

T.test("round 3 item 9: a bare git push is no grant when config redirects or rewrites it", function()
  local work, sh = git_fixture("g3p3-pushcfg")
  T.eq(grant_for("git push", work), "g001", "baseline covered")
  for _, cfg in ipairs({ "remote.origin.mirror true", "remote.origin.pushurl ../elsewhere.git", "url.x.insteadOf origin", "url.x.pushInsteadOf ../remote.git",
    "push.recurseSubmodules on-demand" }) do
    T.eq(sh("git config " .. cfg), "0", "set " .. cfg)
    T.eq(grant_for("git push", work), "nil", "no grant: " .. cfg)
    T.eq(sh("git config --unset-all " .. cfg:match("^%S+")), "0", "unset " .. cfg)
  end
  T.eq(grant_for("git push", work), "g001", "covered again once the config is clean", "ok - push config")
end)

T.test("SHOULD a: scripts, Makefile and justfile called by CI are CI paths", function()
  start_butler()
  local got = T.eval([[local g = remuda.butler.guard_grants
    local out = {}
    for _, n in ipairs({ 'scripts/release.sh', 'Makefile', 'makefile', 'justfile', 'Justfile', 'GNUmakefile', 'docs/scripts/x', 'src/a.lua' }) do
      out[#out + 1] = tostring(g.touches_ci({ n })) end
    return table.concat(out, ',')]])
  T.eq(got, "true,true,true,true,true,true,true,false", "scripts/, Makefile and justfile are T3 (a scripts/ segment at any depth)", "ok - ci scripts")
end)

