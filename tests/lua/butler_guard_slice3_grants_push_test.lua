-- Guard slice 3, PR3 (push half): the grant's push diff check against the remote ref, the plain-push whitelist and git config that redirects a push.
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

T.test("a push under a grant is checked against the remote ref: CI/workflow paths are T3 (no grant), no diff falls back", function()
  start_butler()
  local root = tree("g3p3-push")
  local g = T.eval([[
    local root = remuda._t_root
    local script = table.concat({
      'set -e', 'cd ' .. root,
      'git init -q --bare remote.git', 'git clone -q remote.git work 2>/dev/null', 'cd work',
      'git config user.email t@t; git config user.name t', 'echo a > a; git add a; git commit -q -m a',
      'git push -q -u origin HEAD 2>/dev/null',
    }, '\n')
    local r = remuda.process.run({ argv = { 'sh', '-c', script } })
    return tostring(r.code) .. ' ' .. tostring(r.stderr)]])
  T.expect(g:match("^0"), "git fixture: " .. g)
  local work = root .. "/work"
  local function sh(script) return T.eval(("local r = remuda.process.run({ argv = { 'sh', '-c', %q } }); return tostring(r.code)"):format("set -e; cd " .. work .. "; " .. script)) end
  T.eval("remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','grants','on'})")
  T.eval("remuda._t_add({ class = 'git', scope = " .. string.format("%q", work)
    .. ", ceiling = 'T2', holder = 'ss-a', event = '$ev1', ttl = 3600 })")
  local PUSH = ([[{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push"},"cwd":%q}]]):format(work)
  local function last_line() local l; for x in T.eval("return remuda._t_lines()"):gmatch("[^\n]+") do l = x end; return l end
  T.eq(sh("echo b > b; git add b; git commit -q -m b"), "0", "commit b")
  T.eval(("remuda._t_hook(%q)"):format(PUSH))
  T.expect(has(last_line(), '"class":"push"') and has(last_line(), '"grant_id":"g001"'), "a plain push is covered: " .. last_line())
  T.eq(sh("mkdir -p .github/workflows; echo x > .github/workflows/ci.yml; git add .; git commit -q -m ci"), "0", "commit ci")
  T.eval(("remuda._t_hook(%q)"):format(PUSH))
  T.expect(has(last_line(), '"grant_id":"-"'), "a push touching .github/workflows is T3, no grant: " .. last_line())
  T.eq(sh("git push -q 2>/dev/null; git checkout -q -b fresh; echo c > c; git add c; git commit -q -m c"), "0", "new branch")
  T.eval(("remuda._t_hook(%q)"):format(PUSH))
  T.expect(has(last_line(), '"grant_id":"-"'), "no upstream: the diff cannot be computed, fall back to the tier: " .. last_line())
  T.eval(("remuda._t_hook(%q)"):format(PUSH:gsub(work, root .. "/nonexistent")))
  T.expect(has(last_line(), '"grant_id":"-"'), "an unreadable repo falls back too", "ok - push diff")
  local names = T.eval("return tostring(remuda.butler.guard_grants.touches_ci({ 'src/a.lua', 'docs/.github/workflows/x.yml' }))"
    .. " .. tostring(remuda.butler.guard_grants.touches_ci({ '.gitlab-ci.yml' })) .. tostring(remuda.butler.guard_grants.touches_ci({ 'src/a.lua' }))")
  T.eq(names, "falsetruefalse", "the CI path list is anchored at the repo root")
end)

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

T.test("MUST 1: diff_names runs git with repo config neutralised and no optional locks", function()
  start_butler()
  local seen = T.eval([[local real = remuda.process.run
    local got
    remuda.process.run = function(o) got = o; return { code = 0, stdout = '' } end
    remuda.butler.guard_grants.diff_names('/w')
    remuda.process.run = real
    return table.concat(got.argv, ' ')]])
  for _, want in ipairs({ "GIT_OPTIONAL_LOCKS=0", "-c core.fsmonitor=false", "-c core.hooksPath=/dev/null", "--no-pager", "--no-ext-diff",
    "--no-textconv", "--no-renames", "--name-only", "-z" }) do
    T.expect(has(seen, want), "diff argv missing '" .. want .. "': " .. seen)
  end
  T.expect(true, "", "ok - diff_names hardened")
end)

T.test("MUST 2: a move of a workflow out of .github lists the source path, so the push gets no grant", function()
  local work, sh = git_fixture("g3p3-rename")
  T.eq(sh("mkdir -p .github/workflows; echo x > .github/workflows/ci.yml; git add .; git commit -q -m ci; git push -q 2>/dev/null"), "0", "push ci")
  T.eq(sh("mkdir docs; git mv .github/workflows/ci.yml docs/ci.yml; git commit -q -m mv"), "0", "move out of .github")
  local names = T.eval("return table.concat(remuda.butler.guard_grants.diff_names(" .. string.format("%q", work) .. "), ',')")
  T.expect(has(names, ".github/workflows/ci.yml"), "the source path of a rename is listed: " .. names)
  T.eq(grant_for("git push", work), "nil", "a move out of the CI tree is T3", "ok - rename")
end)

T.test("MUST 4: a push is covered only as exactly `git push [remote [current-branch]]`", function()
  local work, sh = git_fixture("g3p3-whitelist")
  T.eq(sh("echo b > b; git add b; git commit -q -m b"), "0", "commit b")
  local branch = T.eval(("local r = remuda.process.run({ argv = { 'git', '-C', %q, 'rev-parse', '--abbrev-ref', 'HEAD' } }); return (r.stdout:gsub('%%s', ''))"):format(work))
  for _, ok in ipairs({ "git push", "git push origin", "git push origin " .. branch }) do
    T.eq(grant_for(ok, work), "g001", "covered: " .. ok)
  end
  for _, bad in ipairs({ "pushd /x && git push", "GIT_DIR=/x git push", "env -C /x git push", "git push origin evil:main", "git push origin " .. branch .. ":main",
    "git push --all", "git push --mirror", "git push --delete origin " .. branch, "git push origin +" .. branch, "git push --force", "git push -f",
    "git push --tags", "git push origin other", "git push; echo x", "git push && echo x", "git push | cat", "git push `id`", "git push $(id)",
    "git push > f", "git push (x)", "git push\nid", "cd /x && git push", "git -C /x push", "git push --force-with-lease" }) do
    T.eq(grant_for(bad, work), "nil", "no grant: " .. bad:gsub("\n", "\\n"))
  end
  T.expect(true, "", "ok - push whitelist")
end)

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

