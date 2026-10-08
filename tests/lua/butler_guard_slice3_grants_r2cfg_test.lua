-- Guard slice 3, PR3 review round 2 (SEC delta on #384), push config and git cwd. Its own file: the harness gives a file 20s in all.
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
-- Review fixes (SEC on #384). A bare repo + clone with one pushed commit; returns work dir, a shell runner and the hook helpers.
local function git_fixture(name)
  start_butler()
  local root = tree(name)
  local g = T.eval([[
    local script = table.concat({ 'set -e', 'cd ' .. remuda._t_root,
      'git init -q --bare remote.git', 'git clone -q remote.git work 2>/dev/null', 'cd work',
      'git config user.email t@t; git config user.name t', 'echo a > a; git add a; git commit -q -m a',
      'git branch -q -M feat; git push -q -u origin HEAD 2>/dev/null' }, '\n')
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

T.test("R2 MUST 1: remote.<r>.push or push.default matching/nothing means no grant", function()
  local work, sh = git_fixture("g3p3-pushcfg")
  T.eq(sh("echo b > b; git add b; git commit -q -m b"), "0", "commit")
  T.eq(sh("git config remote.origin.push 'refs/heads/*:refs/heads/elsewhere'"), "0", "remote.origin.push set")
  for _, cmd in ipairs({ "git push", "git push origin", "git push origin " .. branch_of(work) }) do T.eq(grant_for(cmd, work), "nil", "remote.push set: " .. cmd) end
  T.eq(sh("git config --unset remote.origin.push"), "0", "unset")
  for _, mode in ipairs({ "matching", "nothing" }) do
    T.eq(sh("git config push.default " .. mode), "0", "push.default " .. mode)
    T.eq(grant_for("git push", work), "nil", "push.default " .. mode)
  end
  T.eq(sh("git config push.default simple"), "0", "simple")
  T.eq(grant_for("git push", work), "g001", "control: simple is covered", "ok - push config")
end)

T.test("R2 MUST 2: a git grant does not cover a protected cwd", function()
  local work, sh = git_fixture("g3p3-gitcwd")
  T.eq(sh("mkdir -p sub/.claude; echo b > sub/.claude/b; git add -f .; git commit -q -m b"), "0", "commit")
  T.eq(grant_for("git push", work), "g001", "control")
  T.eq(grant_for("git push", work .. "/sub/.claude"), "nil", "cwd under .claude", "ok - git cwd protected")
end)

