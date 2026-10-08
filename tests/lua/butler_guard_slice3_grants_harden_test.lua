-- Guard slice 3, PR-A (#339): grant matching hardened, still no allow path: protected branches and tags, push.followTags. The class gate, grant_id and the git budget are in grants_gate_test (own file: the harness gives a file 20s in all).
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
      return remuda._butler_command_run('guard', {'guard'}, { kind = 'session', session = 's-ssa', stdin = stdin, env =
        { REMUDA_BUTLER_AGENT_ALIAS = 'ss-a', REMUDA_BUTLER_AGENT_KIND = 'claude' } })
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
  -- These real-Git controls use the existing test subject budget; production and budget tests keep 2s.
  T.eval("remuda.butler.guard_grants.git_budget_s = 20")
  return T.eval([[
    local root = remuda._butler_guard_dir .. '-tree' -- beside the data dir: the data dir is a protected scope
    remuda.process.run({ argv = { 'sh', '-c', 'mkdir -p ' .. root .. '/real/sub ' .. root .. '/other && ln -s real ' .. root .. '/link' } })
    remuda._t_root = remuda.fs.realpath(root)
    return remuda._t_root
  ]])
end


local function git_fixture(name)
  start_butler()
  local root = tree(name)
  local g = T.eval([[
    local script = table.concat({ 'set -e', 'cd ' .. remuda._t_root,
      'git init -q --bare remote.git', 'git clone -q remote.git work 2>/dev/null', 'cd work',
      'git config user.email t@t; git config user.name t', 'echo a > a; git add a; git commit -q -m a',
      'git branch -q -M feat; git push -q -u origin feat 2>/dev/null' }, '\n')
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
local function grant_for(command, cwd, class)
  return T.eval(("return tostring(remuda.butler.guard_grants.match('Bash', { command = %q }, %q, %s))"):format(command, cwd, class and string.format("%q", class) or "nil"))
end

T.test("a push of main/master/trunk gets no grant (bare and named), a feature branch still does", function()
  local work, sh = git_fixture("g3a-protected")
  T.eq(sh("echo b >> a; git commit -q -am b"), "0", "commit")
  T.eq(grant_for("git push", work), "g001", "control: feature branch, bare push")
  T.eq(grant_for("git push origin feat", work), "g001", "control: feature branch, named")
  for _, b in ipairs({ "main", "master", "trunk" }) do
    T.eq(sh("git branch -q -M " .. b .. "; git push -q -u origin " .. b .. " 2>/dev/null; echo x >> a; git commit -q -am x"), "0", "on " .. b)
    T.eq(grant_for("git push", work), "nil", "bare push on checked-out " .. b)
    T.eq(grant_for("git push origin " .. b, work), "nil", "git push origin " .. b)
  end
  T.eq(sh("git branch -q -M feat; git tag v1"), "0", "back on feat, a tag")
  T.eq(grant_for("git push origin v1", work), "nil", "a tag is not the checked-out branch", "ok - protected branches")
end)

T.test("push.followTags (set to anything) and a failed probe give no grant", function()
  local work, sh = git_fixture("g3a-follow")
  T.eq(grant_for("git push", work), "g001", "control")
  for _, v in ipairs({ "true", "false" }) do
    T.eq(sh("git config push.followTags " .. v), "0", "set " .. v)
    T.eq(grant_for("git push", work), "nil", "followTags=" .. v)
  end
  T.eq(sh("git config --unset push.followTags"), "0", "unset")
  T.eq(grant_for("git push", work), "g001", "covered again once unset")
  local failed = T.eval(([[local real, g = remuda.process.run, remuda.butler.guard_grants
    remuda.process.run = function(o)
      for _, a in ipairs(o.argv) do if a == 'push.followTags' then return { code = 128, stdout = '' } end end
      return real(o)
    end
    local id = g.match('Bash', { command = 'git push' }, %q)
    remuda.process.run = real
    return tostring(id)]]):format(work))
  T.eq(failed, "nil", "a probe that exits neither 0 nor 1 is no grant", "ok - followTags")
end)

