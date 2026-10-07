-- Guard slice 3, PR-B (#339): a git grant allows a plain push of a feature branch at PermissionRequest; CI paths, compounds and main ask.
local started
local function start_butler()
  -- Installed once per file: a second install reloads the mod (the harness gives a file 20 s in all).
  if started then return end
  started = true
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
    remuda._t_lines = function()
      local out, f = {}, io.open(gp.log_path(), 'r')
      if not f then return '' end
      for l in f:lines() do out[#out + 1] = l end
      f:close(); return table.concat(out, '\n')
    end
    remuda._t_guard = function(args) return remuda._butler_command_run('guard', args, {}) end
    -- A relay stand-in: every approval post is counted, none is answered.
    remuda._t_posts = 0
    remuda.pending = function(opts)
      local r = {}
      function r:resolve() end
      return r
    end
    remuda.butler.approval.attach({ approvals = remuda.json.object({}) }, function() return true end,
      function(_, _, cb) remuda._t_posts = remuda._t_posts + 1; if cb then cb({ event_id = '$p' .. remuda._t_posts }) end; return {} end)
    -- One hook call: the reply text ('' or ALLOW; a pending request is shown as 'pending').
    remuda._t_call = function(over)
      local payload = remuda.json.encode({ hook_event_name = over.event or 'PermissionRequest', tool_name = over.tool or 'WebFetch',
        tool_input = over.input or { url = 'https://example.com/x' }, cwd = over.cwd or '/tmp', grant_id = over.grant_id })
      local r = remuda._butler_command_run('guard', { 'guard' }, { stdin = payload, env =
        { REMUDA_BUTLER_AGENT_ALIAS = 'ss-a', REMUDA_BUTLER_AGENT_KIND = over.kind or 'claude' } })
      if type(r) == 'table' then return 'pending' end
      return tostring(r)
    end
    -- The calling session by core's caller identity: a grant held by U-SSA covers it (holders: enforce_holder).
    remuda._butler_bus.agents['t-ssa'] = { id = 'U-SSA', parent = 'butler', alias = 't-ssa', session_name = 's-ssa', children = {} }
    remuda.caller = function() return { kind = 'session', session = 's-ssa' } end
    return 'ok'
  ]])
  -- A fresh load of the store hands `add` to the test; the approval cross-check is its own test (guard_slice3_reactions).
  T.eval("remuda.exec(\"butler/guard_grants\"); remuda.butler.guard_grants.verified = function() return true end;"
    .. " remuda.butler.guard_grants.register(function(add, controls) remuda._t_add, remuda._t_controls = add, controls end)")
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end
local ALLOW = '"behavior":"allow"'
-- A fresh data dir with guard, approvals and grants on, and one net grant g001 for example.com.
local function fresh(name, no_grant)
  start_butler()
  T.eval(("remuda._t_dir(%q); remuda.butler.guard_policy.now = nil; remuda.butler.guard_grants.now = nil;"
    .. " local g = remuda.butler.guard_grants; g._uses, g._limited, g._clock = {}, {}, { high = 0 }"):format(name))
  T.eval("remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','approvals','on'}); remuda._t_guard({'guard','grants','on'})")
  if not no_grant then
    T.eq(T.eval("return (remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'U-SSA', event = '$ev1' }))"), "g001", "grant")
  end
end
local function call(over) return T.eval("return remuda._t_call(" .. (over or "{}") .. ")") end
local function lines() return T.eval("return remuda._t_lines()") end
local function count(text, needle) local n = 0; for _ in text:gmatch(needle) do n = n + 1 end; return n end
-- A repo with a bare remote, on branch feat with its upstream, and a git grant g001 on the working tree.
local function git_fixture(name)
  fresh(name, true)
  -- an asking call goes no further than the grant check: the approval post probes git again to offer a grant
  T.eval("remuda.butler.guard_approval.maybe_request = function() end")
  local work = T.eval([[
    local root = remuda._butler_guard_dir .. '-tree' -- beside the data dir: the data dir is a protected scope
    local script = table.concat({ 'set -e', 'mkdir -p ' .. root, 'cd ' .. root,
      'git init -q --bare remote.git', 'git clone -q remote.git work 2>/dev/null', 'cd work',
      'git config user.email t@t; git config user.name t', 'echo a > a; git add a; git commit -q -m a',
      'git branch -q -M feat; git push -q -u origin feat 2>/dev/null' }, '\n')
    local r = remuda.process.run({ argv = { 'sh', '-c', script } })
    assert(r.code == 0, tostring(r.stderr))
    return (remuda.fs.realpath(root .. '/work'))]])
  local function sh(script) return T.eval(("local r = remuda.process.run({ argv = { 'sh', '-c', %q } }); return tostring(r.code)"):format("set -e; cd " .. work .. "; " .. script)) end
  T.eval("remuda.butler.guard_grants.insensitive = function() return false end") -- the fold has its own test
  -- These real-Git controls use the existing test subject budget; production and budget tests keep 2s.
  T.eval("remuda.butler.guard_grants.git_budget_s = 20")
  local added = T.eval("local id, why = remuda._t_add({ class = 'git', scope = " .. string.format("%q", work) .. ", ceiling = 'T2', holder = 'U-SSA', event = '$ev1' }); return tostring(id or why)")
  T.eq(added, "g001", "git grant")
  return work, sh
end
local function push(work, command) return call(("{ tool = 'Bash', input = { command = %q }, cwd = %q }"):format(command or "git push", work)) end

T.test("a plain push of a feature branch is allowed and audited; CI paths, a compound and main ask", function()
  local work, sh = git_fixture("p-push")
  T.eq(sh("echo b >> a; git commit -q -am b"), "0", "commit")
  T.expect(has(push(work), ALLOW), "plain push allowed")
  T.expect(lines():match('"event":"grant_used","tool":"Bash","class":"push"[^\n]*"grant_id":"g001"') ~= nil, "audited")
  T.expect(not has(push(work, "git push && echo x"), ALLOW), "a compound asks")
  -- the scope is the payload cwd; a leading cd (the only way to push from elsewhere in one command) is a compound
  for _, c in ipairs({ "cd " .. work .. " && git push", "cd " .. work .. "; git push" }) do T.expect(not has(push(work, c), ALLOW), c) end
  for _, path in ipairs({ ".github/workflows/x.yml" }) do -- scripts/, Makefile and the rest: grants_push, at match level
    T.eq(sh("mkdir -p $(dirname " .. path .. "); echo x > " .. path .. "; git add -A; git commit -q -m ci"), "0", "commit " .. path)
    T.expect(not has(push(work), ALLOW), "touches " .. path)
    T.eq(sh("git reset -q --hard HEAD~1"), "0", "drop it")
  end
  T.eq(sh("git branch -q -M main; git push -q -u origin main 2>/dev/null; echo m >> a; git commit -q -am m"), "0", "on main")
  T.expect(not has(push(work), ALLOW), "main asks")
  T.eq(count(lines(), '"event":"grant_used"'), 1, "one use", "ok - push")
end)
