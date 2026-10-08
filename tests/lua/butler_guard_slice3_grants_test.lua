-- Guard slice 3, PR3 (store half): the grant store, `guard grants`, the grants switch, grant_id from the store, scopes, URLs.
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

T.test("audit failure refuses guard switches without changing state", function()
  start_butler()
  T.eval("remuda._t_dir('g3p3-auditfail'); remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','deny','on'})")
  T.eval([[local gp, real_open = remuda.butler.guard_policy, io.open
    io.open = function(path, mode)
      if path == gp.log_path() and mode == 'a' then return nil, 'injected append failure' end
      return real_open(path, mode)
    end
    local _, why = pcall(remuda._t_guard, {'guard','off'}); remuda._t_audit_refusal = tostring(why)
    io.open = real_open]])
  local status = T.eval("return remuda._t_guard({'guard','status'})")
  local refusal = T.eval("return remuda._t_audit_refusal")
  T.expect(has(status, "guard: on") and has(status, "deny: on") and has(refusal, "Next:"),
    "failed audit must preserve both switches and advise a retry: " .. refusal .. " / " .. status)
  T.eval([[local fs, real_write = remuda.fs, remuda.fs.write_atomic
    remuda.fs.write_atomic = function(path, ...)
      if path == remuda._butler_guard_dir .. '/guard-observe' then return nil, 'injected state write failure' end
      return real_write(path, ...)
    end
    pcall(remuda._t_guard, {'guard','off'})
    remuda.fs.write_atomic = real_write]])
  status = T.eval("return remuda._t_guard({'guard','status'})")
  T.expect(has(status, "guard: on"), "failed state write must preserve guard on: " .. status,
    "ok - audit and state failures both preserve guard")
end)

local function ev(code)
  return T.eval("local ok, v = pcall(function() " .. code .. " end); return (ok and 'ok:' or 'err:') .. tostring(v)")
end
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

T.test("the grants switch is off by default, audited, and classed like guard on/off (weaken, owner-only)", function()
  start_butler()
  T.eval("remuda._t_dir('g3p3-switch')")
  T.expect(has(T.eval("return remuda._t_guard({'guard','grants','status'})"), "guard grants: off"), "default off")
  T.eval("remuda._t_guard({'guard','grants','on'}, {})")
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

local ADD = [[remuda._t_add({ class = 'writable', scope = %q, ceiling = 'T2', holder = 'ss-a',
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
  T.eq(refused("remuda._t_add({ class = 'writable', scope = '" .. root .. "/other', ceiling = 'T3', holder = 'x', event = '$e', ttl = 60 })"),
    "nil", "T3 ceiling refused")
  T.eq(refused("remuda._t_add({ class = 'writable', scope = '" .. root .. "/other', ceiling = 'T2', holder = 'x', ttl = 60 })"),
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
  T.eq(T.eval("return tostring(remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/real/*")
    .. ", ceiling = 'T2', holder = 'ss-a\\27[2J\\nNext: rm', event = '$ev1', ttl = 3600 }))"), "nil", "control characters refused")
  T.eval("remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/real/*")
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
    gp.match('WebFetch', { url = 'https://example.com/x' }, '/')
    local listed = remuda._t_guard({'guard','grants'})
    io.open = real
    return n .. ' ' .. tostring(listed:find('off', 1, true) ~= nil)]])
  T.eq(opened, "0 true", "no store read while the switch is off", "ok - guard grants list")
end)

T.test("SHOULD b: add prunes expired lines and allocates ids under one lock; a big store does not hide a new grant", function()
  start_butler()
  local root = tree("g3p3-lock")
  T.eval("remuda._t_guard({'guard','grants','on'}); remuda.butler.guard_grants.now = function() return 1790000000 end")
  local file = T.eval("return (remuda.butler.guard_policy.log_path():gsub('guard%-audit%.jsonl$', 'guard-grants.jsonl'))")
  -- core's lock is per process, so a second holder is simulated: a held lock refuses the add and writes nothing
  local add = "remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/other") .. ", ceiling = 'T2', holder = 'a', event = '$e', ttl = 60 })"
  local busy = T.eval("local real = remuda.fs.lock; remuda.fs.lock = function() return nil, 'held' end; local id = " .. add .. "; remuda.fs.lock = real; return tostring(id)")
  T.eq(busy, "nil", "add waits for the lock and refuses when it stays held")
  T.eq(T.eval("local f = io.open(" .. string.format("%q", file) .. "); return tostring(f and f:read('a'))"), "nil", "nothing written under a held lock")
  -- the lock is held across the whole read-prune-write and released after the file is written
  local order = T.eval(("local real, seen = remuda.fs.lock, {}; remuda.fs.lock = function(p) seen.path = p; return { release = function() seen.file = io.open(%q) ~= nil end } end; local id = %s; remuda.fs.lock = real; return seen.path .. ' ' .. tostring(seen.file) .. ' ' .. tostring(id)"):format(file, add))
  T.eq(order, file .. ".lock true g001", "locked on the store's lock file, released after the write")

  T.eq(T.eval("return tostring(remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/other") .. ", ceiling = 'T2', holder = 'a', event = '$e', ttl = 60 }))"), "g002", "next add: g002")
  T.eq(T.eval("return tostring(remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/real") .. ", ceiling = 'T2', holder = 'a', event = '$e', ttl = 60 }))"), "g003", "next add: g003")
  -- 190 KiB (under the read bound) of expired lines in front: the next add prunes them, keeps ids rising and stays visible
  T.eval(([[local f = io.open(%q, 'w')
    for i = 1, 1200 do
      f:write(remuda.json.encode({ id = string.format('g%%03d', i), class = 'writable', scope = %q, ceiling = 'T2', holder = 'h', event = '$e',
        written = 1789000000, expires = 1789003600 }), '\n')
    end
    f:close()]]):format(file, root .. "/other"))
  T.eq(T.eval("return tostring(remuda._t_add({ class = 'writable', scope = " .. string.format("%q", root .. "/real") .. ", ceiling = 'T2', holder = 'a', event = '$e', ttl = 60 }))"),
    "g1201", "ids keep rising past the pruned lines")
  T.eq(T.eval("local out = {}; for _, g in ipairs(remuda.butler.guard_grants.active()) do out[#out+1] = g.id end; return table.concat(out, ',')"), "g1201",
    "the new grant is active, not lost beyond a read window")
  T.expect(tonumber(T.eval("local f = io.open(" .. string.format("%q", file) .. "); local n = #f:read('a'); f:close(); return n")) < 2000, "expired lines were pruned", "ok - add under lock")
end)
