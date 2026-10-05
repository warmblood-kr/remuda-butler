-- Guard slice 3, PR-A (#339), second half: the class gate, grant_id only on allowed calls, KNOWN_EVENT, the git budget. Its own file: the harness gives a file 20s in all.
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

T.test("class gate: only push and net may match; every other class gets no grant", function()
  local work = git_fixture("g3a-class")
  T.eval("remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'ss-a', event = '$ev2', ttl = 3600 })")
  local function fetch(class) return T.eval(("return tostring(remuda.butler.guard_grants.match('WebFetch', { url = 'https://example.com/x' }, '/', %s))"):format(class and string.format("%q", class) or "nil")) end
  T.eq(fetch("net"), "g002", "control: net")
  T.eq(grant_for("git push", work, "push"), "g001", "control: push")
  for _, c in ipairs({ "weaken", "control", "identity", "destroy", "escape", "script", "other", "writable", "git", "" }) do
    T.eq(fetch(c), "nil", "WebFetch as " .. c)
    T.eq(grant_for("git push", work, c), "nil", "push command as " .. c)
  end
  T.eq(T.eval(("return tostring(remuda.butler.guard_grants.match('Write', { file_path = %q }, '/', 'push'))"):format(work .. "/a")), "nil", "a file tool never matches")
  T.eq(grant_for("git push origin && curl x", work), "nil", "a compound command classifies below push", "ok - class gate")
end)

T.test("grant_id stays '-' on hook lines (denied, PreToolUse, PermissionRequest); grant_used and grant_limited are known events", function()
  start_butler()
  tree("g3a-audit")
  T.eval("remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','grants','on'}); remuda._t_guard({'guard','deny','on'})")
  T.eval("remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'ss-a', event = '$ev1', ttl = 3600 })")
  local function hook(event) return ([[{"hook_event_name":%q,"tool_name":"WebFetch","tool_input":{"url":"https://example.com/x"},"cwd":"/"}]]):format(event) end
  local function last_line() local l; for x in T.eval("return remuda._t_lines()"):gmatch("[^\n]+") do l = x end; return l end
  T.eq(T.eval("return tostring(remuda.butler.guard_grants.match('WebFetch', { url = 'https://example.com/x' }, '/'))"), "g001", "control: the grant covers the call")
  T.eval(("remuda._t_hook(%q)"):format(hook("PreToolUse")))
  T.expect(has(last_line(), '"grant_id":"-"'), "PreToolUse: " .. last_line())
  T.eval(("remuda._t_hook(%q)"):format(hook("PermissionRequest")))
  T.expect(has(last_line(), '"grant_id":"-"'), "PermissionRequest (nothing allows yet): " .. last_line())
  T.eval("local gp = remuda.butler.guard_policy; local real = gp.deny_reason; gp.deny_reason = function() return 'test deny' end; _G._t_real_deny = real")
  T.eval(("remuda._t_hook(%q)"):format(hook("PreToolUse")))
  T.eval("remuda.butler.guard_policy.deny_reason = _G._t_real_deny")
  T.expect(has(last_line(), '"event":"deny"') and has(last_line(), '"grant_id":"-"'), "a denied call carries '-': " .. last_line())
  T.eval([[local gp = remuda.butler.guard_policy
    gp.append({ event = 'grant_used', grant_id = 'g001', tool = 'WebFetch', class = 'net' })
    gp.append({ event = 'grant_limited', grant_id = 'g001', tool = 'WebFetch', class = 'net' })]])
  local stats = T.eval("return remuda._t_guard({'guard','stats'})")
  T.expect(has(stats, "event grant_used: 1") and has(stats, "event grant_limited: 1") and not has(stats, "event other"), "stats: " .. stats, "ok - grant_id and events")
end)

-- Runs match('Bash', 'git push') with remuda.process.run counted (and each git call slowed by `slow` seconds); returns "id calls".
local function counted(work, slow)
  return T.eval(([[local real, g = remuda.process.run, remuda.butler.guard_grants
    local n = 0
    remuda.process.run = function(o) n = n + 1; if %d > 0 then real({ argv = { 'sleep', '%d' } }) end; return real(o) end
    local id = g.match('Bash', { command = 'git push' }, %q)
    remuda.process.run = real
    return tostring(id) .. ' ' .. n]]):format(slow, slow, work))
end

T.test("git work is budgeted: with no git grant no git runs; a slow git means no grant", function()
  local work = git_fixture("g3a-budget")
  T.eq(counted(work, 0):match("^g001"), "g001", "control: covered")
  T.eval("local g = remuda.butler.guard_grants; _G._t_active = g.active; g.active = function() return { { id = 'g009', class = 'net', scope = 'example.com' } } end")
  T.eq(counted(work, 0), "nil 0", "only a net grant exists: a push candidate spawns nothing")
  T.eval("remuda.butler.guard_grants.active = _G._t_active")
  local slow = counted(work, 1)
  local id, calls = slow:match("^(%S+) (%d+)$")
  T.eq(id, "nil", "over budget: no grant")
  T.expect(tonumber(calls) <= 4, "git stopped once the budget was spent, calls: " .. slow, "ok - git budget")
end)
