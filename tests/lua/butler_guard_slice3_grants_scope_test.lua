-- Guard slice 3, PR3 (scope half): grant_id in audit lines, URL hosts, protected scopes, bidi escaping, no agent path to add, eval/script classing.
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
  return T.eval([[
    local root = remuda._butler_guard_dir .. '-tree' -- beside the data dir: the data dir is a protected scope
    remuda.process.run({ argv = { 'sh', '-c', 'mkdir -p ' .. root .. '/real/sub ' .. root .. '/other && ln -s real ' .. root .. '/link' } })
    remuda._t_root = remuda.fs.realpath(root)
    return remuda._t_root
  ]])
end

T.test("MUST 3: a URL with a backslash, whitespace, control char or userinfo gets no net grant", function()
  start_butler()
  tree("g3p3-host")
  T.eval("remuda._t_guard({'guard','grants','on'}); remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'ss-a', event = '$ev1', ttl = 3600 })")
  local function fetch(url) return T.eval(("return tostring(remuda.butler.guard_grants.match('WebFetch', { url = %q }, '/'))"):format(url)) end
  T.eq(fetch("https://example.com/x"), "g001", "a plain URL is covered")
  for _, bad in ipairs({ "https://example.com\\@evil.com/", "https://evil.com\\.example.com/", "https://example.com@evil.com/",
    "https://evil.com@example.com/", "https://u:p@example.com/", "https://example.com/a b", "https://example.com/\ta", "https://exa\1mple.com/" }) do
    T.eq(fetch(bad), "nil", "no grant: " .. bad:gsub("%c", "?"))
  end
  T.expect(true, "", "ok - host_of")
end)

T.test("SHOULD c: shallow roots and protected directories are refused as scopes", function()
  start_butler()
  local root = tree("g3p3-protected")
  local home = T.eval("return remuda.butler.guard_grants.canonical(os.getenv('HOME'))")
  local data = T.eval("return remuda.butler.guard_grants.canonical(remuda.butler.guard_policy.dir())")
  local function scope(p) return T.eval("return tostring((remuda.butler.guard_grants.scope('writable', " .. string.format("%q", p) .. ")))") end
  for _, bad in ipairs({ "/", "/Users", "/Users/*", "/home", home, home .. "/*", home .. "/.ssh", home .. "/.ssh/*", home .. "/.claude/x",
    home .. "/.config", home .. "/.config/remuda", home .. "/.config/remuda/*", data, data .. "/sub", root .. "/real/.git/hooks",
    root .. "/real/*/.git/config", root .. "/real/.git/hooks/x", root .. "/*/.ssh" }) do
    T.eq(scope(bad), "nil", "refused: " .. bad)
  end
  T.eq(scope(root .. "/real/*"), root .. "/real/*", "an ordinary scope still resolves")
  T.expect(true, "", "ok - protected scopes")
end)

T.test("round 3 item 10: .git followed by hooks, config or config.worktree at any later depth is protected", function()
  start_butler()
  local root = tree("g3p3-gitdeep")
  local function scope(p) return T.eval("return tostring((remuda.butler.guard_grants.scope('writable', " .. string.format("%q", p) .. ")))") end
  for _, bad in ipairs({ root .. "/real/.git/modules/s/hooks", root .. "/real/.git/modules/s/hooks/x", root .. "/real/.git/modules/s/config",
    root .. "/real/.git/config.worktree", root .. "/real/.git/worktrees/w/config.worktree" }) do
    T.eq(scope(bad), "nil", "refused: " .. bad)
  end
  T.eq(scope(root .. "/real/.git/modules/s/objects"), root .. "/real/.git/modules/s/objects", "other .git paths still resolve", "ok - deep git")
end)

T.test("SHOULD e: guard grants escapes bidi overrides in holder, event and scope", function()
  start_butler()
  local root = tree("g3p3-bidi")
  T.eval("remuda._t_guard({'guard','grants','on'})")
  T.eval("remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/real/*")
    .. ", ceiling = 'T2', holder = 'ss\226\128\174a', event = '$ev\226\129\166x', ttl = 3600 })")
  local out = T.eval("return remuda._t_guard({'guard','grants'})")
  T.expect(has(out, "g001"), "grant listed: " .. out)
  T.expect(not out:find("\226\128[\142\143\168-\174]") and not out:find("\226\129[\166-\175]"), "a bidi override reached the terminal: " .. out)
  T.expect(has(out, "\\u202E") and has(out, "\\u2066"), "overrides shown escaped: " .. out, "ok - bidi")
end)

T.test("SHOULD f: an agent cannot reach guard_grants.add through run_script or remuda eval", function()
  start_butler()
  local code = "remuda.butler.guard_grants.add({ class = 'writable', scope = '/x/y', ceiling = 'T2', holder = 'a', event = '$e' })"
  local out = T.eval(([[local gp = remuda.butler.guard_policy
    local bash = 'remuda eval ' .. string.format('%%q', %q)
    local nested = "sh -c 'remuda eval \"remuda.butler.guard_grants.add{}\"'"
    return table.concat({ tostring(gp.deny_reason('mcp__remuda__run_script', { code = %q }, { home = '/h' })),
      tostring(gp.deny_reason('Bash', { command = bash }, { home = '/h' })),
      tostring(gp.deny_reason('Bash', { command = nested }, { home = '/h' })),
      gp.classify('Bash', { command = 'remuda eval "return 1"' }, { home = '/h' }) }, '|')]]):format(code, code))
  T.eq(out, "Butler grant store|Butler grant store|Butler grant store|script", "denied by text, and eval is a script", "ok - no agent path to add")
end)


T.test("round 3 item 11: remuda -e/--eval with an attached value, `remuda lua|exec|repl` and `remuda run` are scripts", function()
  start_butler()
  local out = T.eval([[local gp = remuda.butler.guard_policy
    local r = {}
    for _, c in ipairs({ "remuda -e'return 1'", 'remuda -ereturn1', "remuda --eval=return1", "remuda --evalx 1", "remuda lua x.lua", "remuda exec x", "remuda repl",
      "remuda run x", "remuda --server s run x", "remuda x.lua", "remuda /tmp/x.lua a b", "remuda ls", "remuda butler status" }) do
      r[#r + 1] = gp.classify('Bash', { command = c }, { home = '/h' }) end
    return table.concat(r, ',')]])
  T.eq(out, "script,script,script,script,script,script,script,script,script,other,other,other,other", "attached -e/--eval, lua/exec/repl and run (starts a command) are scripts; a bare .lua word is not", "ok - eval forms")
end)
