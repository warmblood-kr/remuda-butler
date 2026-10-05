-- Guard slice 3, PR3 review round 2 (SEC delta on #384), push base and remote word. Its own file: the harness gives a file 20s in all.
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

-- Review fixes, round 2 (SEC delta on #384).
local function branch_of(work)
  return T.eval(("local r = remuda.process.run({ argv = { 'git', '-C', %q, 'rev-parse', '--abbrev-ref', 'HEAD' } }); return (r.stdout:gsub('%%s', ''))"):format(work))
end

T.test("R2 MUST 1: the push base is the ref the push updates, not @{upstream}", function()
  local work, sh = git_fixture("g3p3-base")
  local b = branch_of(work)
  -- the CI change sits on origin/other, which becomes the upstream; origin/<b> does not hold it
  T.eq(sh("mkdir -p .github/workflows; echo x > .github/workflows/ci.yml; git add .; git commit -q -m ci; git push -q origin HEAD:refs/heads/other; git branch -q -u origin/other"), "0", "upstream holds the CI change")
  for _, cmd in ipairs({ "git push origin " .. b, "git push origin", "git push" }) do
    T.eq(grant_for(cmd, work), "nil", "no grant (the push would send the CI change to origin/" .. b .. "): " .. cmd)
  end
  -- a 4-word push to a branch whose remote-tracking ref is missing cannot be diffed: the tier asks
  T.eq(sh("git checkout -q -b fresh; echo c > c; git add c; git commit -q -m c"), "0", "fresh branch")
  T.eq(grant_for("git push origin fresh", work), "nil", "no refs/remotes/origin/fresh: no grant")
  -- a clean 4-word push is diffed against refs/remotes/origin/<b>
  T.eq(sh("git checkout -q " .. b .. "; git reset -q --hard origin/" .. b .. "; echo d > d; git add d; git commit -q -m d; git branch -q -u origin/" .. b), "0", "clean again")
  T.eq(grant_for("git push origin " .. b, work), "g001", "a plain push to the tracked branch is covered")
  T.expect(true, "", "ok - push base")
end)

T.test("R2 MUST 1: 2-3 word pushes need the target to equal the upstream (push.default simple)", function()
  local work, sh = git_fixture("g3p3-simple")
  local b = branch_of(work)
  T.eq(sh("echo b > b; git add b; git commit -q -m b"), "0", "commit")
  T.eq(grant_for("git push", work), "g001", "control: upstream is the target")
  T.eq(sh("git push -q origin HEAD:refs/heads/other; git branch -q -u origin/other"), "0", "upstream renamed")
  T.eq(grant_for("git push", work), "nil", "upstream branch name differs from the local one")
  T.eq(grant_for("git push origin", work), "nil", "same for an explicit remote")
  T.eq(sh("git branch -q -u origin/" .. b .. "; git remote add second ../remote.git; git fetch -q second"), "0", "second remote")
  T.eq(grant_for("git push second", work), "nil", "a remote that is not the upstream's")
  T.eq(grant_for("git push origin", work), "g001", "control: upstream remote")
  T.expect(true, "", "ok - simple rule")
end)

T.test("R2 MUST 1: the remote word must be a configured remote, never a path", function()
  local work, sh = git_fixture("g3p3-remoteword")
  T.eq(sh("echo b > b; git add b; git commit -q -m b"), "0", "commit")
  for _, bad in ipairs({ "git push ../remote.git", "git push ../x", "git push ./x", "git push /tmp/x", "git push nope", "git push ../remote.git " .. branch_of(work) }) do
    T.eq(grant_for(bad, work), "nil", "no grant: " .. bad)
  end
  T.eq(grant_for("git push origin", work), "g001", "control: configured remote", "ok - remote word")
end)

