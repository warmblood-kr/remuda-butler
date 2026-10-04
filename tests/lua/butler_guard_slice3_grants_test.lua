-- Guard slice 3, PR3: the grant store, `guard grants`, the grants switch, grant_id from the store, push diff check.
local function start_butler()
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
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end

T.test("clearing the guard-unaudited marker appends a switch line that records it; an unwritable line keeps the marker", function()
  start_butler()
  T.eval("remuda._t_dir('g3p3-marker'); remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','deny','on'})")
  T.eval([[local gp = remuda.butler.guard_policy
    remuda.process.run({ argv = { 'chmod', '400', gp.log_path() } })
    local real = io.stderr; io.stderr = { write = function() end }
    remuda._t_guard({'guard','off'}); io.stderr = real
    remuda.process.run({ argv = { 'chmod', '600', gp.log_path() } })]])
  T.expect(has(T.eval("return remuda._t_guard({'guard','status'})"), "NOT audited"), "marker set by the unaudited off")
  T.eval("remuda._t_guard({'guard','on'})")
  local lines = T.eval("return remuda._t_lines()")
  local note; for l in lines:gmatch("[^\n]+") do if has(l, "earlier off NOT audited:") then note = l end end
  T.expect(note and has(note, '"event":"switch"') and has(note, '"class":"other"'), "no switch line records the marker: " .. lines)
  T.expect(not has(T.eval("return remuda._t_guard({'guard','status'})"), "NOT audited"), "marker cleared after the note")
  -- the note cannot be written: the marker stays
  T.eval([[local gp = remuda.butler.guard_policy
    local f = io.open(remuda._butler_guard_dir .. '/guard-unaudited', 'w'); f:write('x\n'); f:close()
    local real, calls = io.open, 0
    io.open = function(path, mode)
      if path == gp.log_path() and mode == 'a' then calls = calls + 1; if calls == 2 then return nil, 'boom' end end
      return real(path, mode)
    end
    remuda._t_ok = pcall(gp.append, { session = 's', event = 'switch', summary = 'x' })
    io.open = real]])
  T.expect(has(T.eval("return remuda._t_guard({'guard','status'})"), "NOT audited"), "marker kept when its note cannot be written")
  T.expect(true, "", "ok - marker note")
end)

T.test("a failed switch write after an unaudited off clears the marker: no off took effect", function()
  start_butler()
  T.eval("remuda._t_dir('g3p3-offfail'); remuda._t_guard({'guard','on'})")
  T.eval([[local gp = remuda.butler.guard_policy
    os.remove(remuda._butler_guard_dir .. '/guard-observe'); remuda.mkdir(remuda._butler_guard_dir .. '/guard-observe') -- a directory where the switch belongs
    remuda.process.run({ argv = { 'chmod', '400', gp.log_path() } })
    local real = io.stderr; io.stderr = { write = function() end }
    pcall(remuda._t_guard, {'guard','off'}); io.stderr = real
    remuda.process.run({ argv = { 'chmod', '600', gp.log_path() } })]])
  local status = T.eval("return remuda._t_guard({'guard','status'})")
  T.expect(not has(status, "NOT audited"), "a switch that never turned off must not warn of an unaudited off: " .. status,
    "ok - failed set clears marker")
end)

local function ev(code)
  return T.eval("local ok, v = pcall(function() " .. code .. " end); return (ok and 'ok:' or 'err:') .. tostring(v)")
end
-- A scratch tree: ROOT/real/sub, ROOT/link -> real, ROOT/other. Sets G (the grants module) and ROOT.
local function tree(name)
  T.eval("remuda._t_dir(" .. string.format("%q", name) .. ")")
  T.eval("remuda.butler.guard_grants.insensitive = function() return false end") -- the fold has its own test
  return T.eval([[
    local root = remuda._butler_guard_dir .. '/tree'
    remuda.process.run({ argv = { 'sh', '-c', 'mkdir -p ' .. root .. '/real/sub ' .. root .. '/other && ln -s real ' .. root .. '/link' } })
    remuda._t_root = remuda.fs.realpath(root)
    return remuda._t_root
  ]])
end

T.test("the grants switch is off by default, audited, and classed like guard on/off (weaken, owner-only)", function()
  start_butler()
  T.eval("remuda._t_dir('g3p3-switch')")
  T.expect(has(T.eval("return remuda._t_guard({'guard','grants','status'})"), "guard grants: off"), "default off")
  T.eval("remuda._t_guard({'guard','grants','on'}, {env={REMUDA_BUTLER_AGENT_ALIAS='lead-1'}})")
  T.expect(has(T.eval("return remuda._t_guard({'guard','grants','status'})"), "guard grants: on"), "switched on")
  T.expect(has(T.eval("return remuda._t_lines()"), '"summary":"guard grants on"'), "switch change is audited")
  local out = T.eval([[local gp = remuda.butler.guard_policy
    local function c(cmd) return gp.classify('Bash', { command = cmd }, { home = '/h' }) end
    local function d(cmd) return tostring(gp.deny_reason('Bash', { command = cmd }, { home = '/h' })) end
    return table.concat({ c('remuda butler guard grants on'), c('remuda -s x butler guard grants off'),
      c('remuda butler guard grants'), c('remuda butler guard grants status'),
      d('remuda butler guard grants on'), d('remuda butler guard grants'), d('remuda butler guard grants status') }, ' ')]])
  T.eq(out, "weaken weaken other other Butler owner control nil nil", "classification and deny")
  T.expect(ev("return remuda._t_guard({'guard','grants','bogus'})"):find("^err:") ~= nil, "bad verb refused", "ok - grants switch")
end)

T.test("one canonicalisation: nearest-existing-ancestor realpath, no ./.., case-fold only on a case-insensitive volume", function()
  start_butler()
  local root = tree("g3p3-canon")
  local function canon(p) return T.eval("return tostring(remuda.butler.guard_grants.canonical(" .. string.format("%q", p) .. "))") end
  T.eq(canon(root .. "/link/sub"), root .. "/real/sub", "a symlink resolves to its target")
  T.eq(canon(root .. "/real/new/deeper/file"), root .. "/real/new/deeper/file", "a missing tail is appended to the real ancestor")
  T.eq(canon(root .. "/link/new/f"), root .. "/real/new/f", "the ancestor is resolved through the symlink")
  T.eq(canon(root .. "/real/nope/../x"), "nil", "a .. in the missing tail is refused")
  T.eq(canon(root .. "/real/nope/./x"), "nil", "a . in the missing tail is refused")
  T.eq(canon("relative/path"), "nil", "a relative path yields no grant")
  T.eq(canon(""), "nil", "empty yields none")
  T.eval("remuda.butler.guard_grants.insensitive = function() return true end")
  T.eq(canon(root .. "/real/New"), (root .. "/real/new"):lower(), "case-folded on a case-insensitive volume")
  T.eval("remuda.butler.guard_grants.insensitive = function() return false end")
  T.eq(canon(root .. "/real/New"), root .. "/real/New", "case kept on a case-sensitive volume")
  T.eval("remuda.butler.guard_grants.insensitive = nil")
  local folded = T.eval("return tostring(remuda.fs.realpath('" .. root .. "/REAL') ~= nil)") == "true"
  T.eq(canon(root .. "/real/New"), folded and (root .. "/real/new"):lower() or root .. "/real/New", "the real probe folds exactly when the volume is case-insensitive")
  T.expect(true, "", "ok - canonical")
end)

T.test("scope patterns: whole-segment * below a fixed prefix only; resolved when stored", function()
  start_butler()
  local root = tree("g3p3-scope")
  local function scope(class, p)
    return T.eval("local r, why = remuda.butler.guard_grants.scope(" .. string.format("%q, %q", class, p) .. "); return tostring(r)")
  end
  for _, bad in ipairs({ "*", "/*", "/*/x", root .. "/rx-*", root .. "/t1*", root .. "/*x/y", root .. "/a?b", root .. "/[ab]",
    root .. "/real/../other", root .. "/./x", "rel/*", "" }) do
    T.eq(scope("writable", bad), "nil", "refused: " .. bad)
  end
  T.eq(scope("writable", root .. "/link/*"), root .. "/real/*", "the fixed prefix is resolved, the * kept")
  T.eq(scope("writable", root .. "/link"), root .. "/real", "a plain directory scope is resolved")
  T.eq(scope("net", "Example.COM."), "example.com", "host: lowercased, no trailing dot")
  for _, bad in ipairs({ "*", "*.example.com", "ex*.com", "1.2.3.4", "[::1]", "a@b.com", "http://a.com", "a.com/x", "" }) do
    T.eq(scope("net", bad), "nil", "net refused: " .. bad)
  end
  T.eq(scope("net", "example.com:8443"), "example.com:8443", "a non-default port is its own scope")
  T.eq(scope("frob", root), "nil", "unknown class refused", "ok - scope")
end)

local ADD = [[remuda.butler.guard_grants.add({ class = 'writable', scope = %q, ceiling = 'T2', holder = 'ss-a',
  event = '$ev1', ttl = %s })]]

T.test("grant store: ids, TTL cap, ceiling, absolute expiry, fail closed on bad entries, nothing cached", function()
  start_butler()
  local root = tree("g3p3-store")
  T.eval("remuda._t_guard({'guard','grants','on'}); remuda.butler.guard_grants.now = function() return 1790000000 end")
  T.eq(T.eval("return tostring(" .. ADD:format(root .. "/real/*", "3600") .. ")"), "g001", "first id")
  T.eq(T.eval("return tostring(" .. ADD:format(root .. "/other", "nil") .. ")"), "g002", "second id, default TTL")
  local function refused(code) return T.eval("local id, why = " .. code .. "; return tostring(id)") end
  T.eq(refused(ADD:format(root .. "/other", "86401")), "nil", "TTL over 24h refused")
  T.eq(refused(ADD:format(root .. "/other", "0")), "nil", "zero TTL refused")
  T.eq(refused(ADD:format("*", "60")), "nil", "bad scope refused")
  T.eq(refused("remuda.butler.guard_grants.add({ class = 'writable', scope = '" .. root .. "/other', ceiling = 'T3', holder = 'x', event = '$e', ttl = 60 })"),
    "nil", "T3 ceiling refused")
  T.eq(refused("remuda.butler.guard_grants.add({ class = 'writable', scope = '" .. root .. "/other', ceiling = 'T2', holder = 'x', ttl = 60 })"),
    "nil", "no approval event refused")
  local file = T.eval("return (remuda.butler.guard_policy.log_path():gsub('guard%-audit%.jsonl$', 'guard-grants.jsonl'))")
  T.expect(has(T.eval("local f = io.open(" .. string.format("%q", file) .. "); local s = f:read('a'); f:close(); return s"),
    '"expires":1790003600'), "the store holds an absolute expiry")
  -- hostile and stale lines in the file, appended behind the harness's back
  T.eval([[local f = io.open(]] .. string.format("%q", file) .. [[, 'a')
    local function put(t) f:write(remuda.json.encode(t), '\n') end
    local base = { class = 'writable', scope = ']] .. root .. [[/other', ceiling = 'T2', holder = 'h', event = '$e', written = 1790000000, expires = 1790003600 }
    local function with(id, k, v) local t = {}; for a, b in pairs(base) do t[a] = b end; t.id = id; t[k] = v; return t end
    put(with('g010', 'expires', 1789999999))     -- expired
    put(with('g011', 'event', ''))               -- no approval event
    put(with('g012', 'written', 1790000500))     -- written with a clock ahead of now: clock went backwards
    put(with('g013', 'expires', 1790000000 + 86401)) -- TTL over the cap
    put(with('x14', 'class', 'writable'))        -- bad id
    put(with('g015', 'ceiling', 'T3'))           -- T3 excluded
    put(with('g016', 'scope', '*'))              -- bare *
    put(with('g017', 'expires', 'soon'))         -- unparseable time
    f:write('not json\n')
    put(with('g018', 'class', 'frob'))
    f:close()]])
  local ids = T.eval("local out = {}; for _, g in ipairs(remuda.butler.guard_grants.active()) do out[#out+1] = g.id end; return table.concat(out, ',')")
  T.eq(ids, "g001,g002", "only the two valid, unexpired grants are active")
  T.eval("remuda.butler.guard_grants.now = function() return 1790003600 end")
  T.eq(T.eval("return #remuda.butler.guard_grants.active()"), "0", "at the absolute expiry time both grants are gone")
  T.expect(true, "", "ok - store")
end)

T.test("guard grants lists active grants for the operator, sanitised; with the switch off nothing reads the store", function()
  start_butler()
  local root = tree("g3p3-list")
  T.eval("remuda.butler.guard_grants.now = nil")
  T.expect(has(T.eval("return remuda._t_guard({'guard','grants'})"), "off"), "off says so")
  T.eval("remuda._t_guard({'guard','grants','on'})")
  T.expect(has(T.eval("return remuda._t_guard({'guard','grants'})"), "no active grants"), "empty store")
  -- control characters in holder or event are refused at add and make a stored entry no grant
  T.eq(T.eval("return tostring(remuda.butler.guard_grants.add({ class = 'writable', scope = " .. string.format("%q", root .. "/real/*")
    .. ", ceiling = 'T2', holder = 'ss-a\\27[2J\\nNext: rm', event = '$ev1', ttl = 3600 }))"), "nil", "control characters refused")
  T.eval("remuda.butler.guard_grants.add({ class = 'writable', scope = " .. string.format("%q", root .. "/real/*")
    .. ", ceiling = 'T2', holder = 'ss-a', event = '$ev1', ttl = 3600 })")
  local out = T.eval("return remuda._t_guard({'guard','grants'})")
  for _, want in ipairs({ "g001", "writable", root .. "/real/*", "T2", "ss-a", "expires" }) do
    T.expect(has(out, want), "list missing '" .. want .. "':\n" .. out)
  end
  T.expect(not out:find("[\1-\9\11-\31]"), "control bytes reached the terminal: " .. out)
  T.expect(select(2, out:gsub("\n", "")) <= 2, "one line per grant plus a header: " .. out)
  -- switch off: the store is not opened at all
  T.eval("remuda._t_guard({'guard','grants','off'})")
  local opened = T.eval([[local gp, real, n = remuda.butler.guard_grants, io.open, 0
    io.open = function(p, ...) if tostring(p):find('guard%-grants%.jsonl') then n = n + 1 end; return real(p, ...) end
    gp.match('Write', { file_path = ']] .. root .. [[/real/x' }, '/')
    local listed = remuda._t_guard({'guard','grants'})
    io.open = real
    return n .. ' ' .. tostring(listed:find('off', 1, true) ~= nil)]])
  T.eq(opened, "0 true", "no store read while the switch is off", "ok - guard grants list")
end)

local function write_hook(path) return ([[{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":%q,"grant_id":"g999"},"cwd":"/"}]]):format(path) end

T.test("grant_id in audit lines comes from the store: the covering grant, '-' when off, outside, or agent-supplied", function()
  start_butler()
  local root = tree("g3p3-audit")
  T.eval("remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','grants','on'})")
  T.eval("remuda.butler.guard_grants.add({ class = 'writable', scope = " .. string.format("%q", root .. "/real/*")
    .. ", ceiling = 'T2', holder = 'ss-a', event = '$ev1', ttl = 3600 })")
  local function last_line() local l; for x in T.eval("return remuda._t_lines()"):gmatch("[^\n]+") do l = x end; return l end
  T.eval(("remuda._t_hook(%q)"):format(write_hook(root .. "/real/sub/f.txt")))
  T.expect(has(last_line(), '"grant_id":"g001"'), "covered write: " .. last_line())
  T.eval(("remuda._t_hook(%q)"):format(write_hook(root .. "/link/sub/f.txt")))
  T.expect(has(last_line(), '"grant_id":"g001"'), "a symlink into the scope resolves into it: " .. last_line())
  T.eval(("remuda._t_hook(%q)"):format(write_hook(root .. "/other/f.txt")))
  T.expect(has(last_line(), '"grant_id":"-"'), "outside the scope, and an agent-supplied grant_id is ignored: " .. last_line())
  T.eval("remuda.process.run({ argv = { 'sh', '-c', 'ln -s ../other " .. root .. "/real/leak' } })")
  T.eval(("remuda._t_hook(%q)"):format(write_hook(root .. "/real/leak/f.txt")))
  T.expect(has(last_line(), '"grant_id":"-"'), "a symlink that leaves the scope is outside it: " .. last_line())
  T.eval(("remuda._t_hook(%q)"):format(write_hook(root .. "/real/x/../../other/f")))
  T.expect(has(last_line(), '"grant_id":"-"'), "a .. in the path yields no grant: " .. last_line())
  T.eval("remuda._t_guard({'guard','grants','off'})")
  T.eval(("remuda._t_hook(%q)"):format(write_hook(root .. "/real/sub/f.txt")))
  T.expect(has(last_line(), '"grant_id":"-"'), "switch off: no grant applies: " .. last_line(), "ok - grant_id from store")
end)

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
  T.eval("remuda.butler.guard_grants.add({ class = 'git', scope = " .. string.format("%q", work)
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
