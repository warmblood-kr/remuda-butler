-- Guard slice 3, PR-B2 (#339): a grant applies only to the session it was made for and the sessions below it, by core's caller identity.
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
    remuda._t_guard = function(args) return remuda._butler_command_run('guard', args, {kind='session', session='butler'}) end
    -- A relay stand-in: every approval post is counted, none is answered.
    remuda._t_posts = 0
    remuda.pending = function(opts)
      local r = {}
      function r:resolve() end
      return r
    end
    remuda._t_attach = function()
    remuda.butler.approval.attach({ approvals = remuda.json.object({}) }, function() return true end,
      function(text, _, cb) remuda._t_posts = remuda._t_posts + 1; remuda._t_text = (remuda._t_text or "") .. text .. "\n"; if cb then cb({ event_id = '$p' .. remuda._t_posts }) end; return {} end)
    end
    remuda._t_attach()
    -- One hook call: the reply text ('' or ALLOW; a pending request is shown as 'pending').
    remuda._t_call = function(over)
      local payload = remuda.json.encode({ hook_event_name = over.event or 'PermissionRequest', tool_name = over.tool or 'WebFetch',
        tool_input = over.input or { url = 'https://example.com/x' }, cwd = over.cwd or '/tmp', grant_id = over.grant_id })
      local r = remuda._butler_command_run('guard', { 'guard' }, { stdin = payload, env =
        { REMUDA_BUTLER_AGENT_ALIAS = 'ss-a', REMUDA_BUTLER_AGENT_KIND = over.kind or 'claude' } })
      if type(r) == 'table' then return 'pending' end
      return tostring(r)
    end
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
    .. " local g = remuda.butler.guard_grants; g._uses, g._limited, g._clock = {}, {}, { high = 0 };"
    .. " remuda.butler.guard_approval._limits = { agent = {}, hour = {}, denies = {} }; remuda._t_attach()"):format(name))
  T.eval("remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','approvals','on'}); remuda._t_guard({'guard','grants','on'})")
  if not no_grant then
    T.eq(T.eval("return (remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'ss-a', event = '$ev1' }))"), "g001", "grant")
  end
end
local function call(over) return T.eval("return remuda._t_call(" .. (over or "{}") .. ")") end
local function lines() return T.eval("return remuda._t_lines()") end
local function count(text, needle) local n = 0; for _ in text:gmatch(needle) do n = n + 1 end; return n end
-- A small tree on the bus: tl leads ta and tb; tc is ta's member. Core's caller identity is stubbed per call.
local function tree()
  T.eval([[local agents = remuda._butler_bus.agents
    for alias, a in pairs({ tl = { 'U-TL', 'butler' }, ta = { 'U-TA', 'tl' }, tb = { 'U-TB', 'tl' }, tc = { 'U-TC', 'ta' } }) do
      agents[alias] = { id = a[1], parent = a[2], alias = alias, session_name = 's-' .. alias, children = {} }
    end
    remuda.caller = function() return remuda._t_who end]])
end
local function untree() T.eval("local a = remuda._butler_bus.agents; a.tl, a.ta, a.tb, a.tc = nil, nil, nil, nil; remuda.caller = nil") end
local function as(alias) T.eval(("remuda._t_who = { kind = 'session', session = 's-%s' }"):format(alias)) end

T.test("a grant held by a session applies to it and the sessions below it, not to a sibling or its leader", function()
  fresh("h-tree", true)
  tree()
  T.eq(T.eval("return (remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'U-TA', event = '$ev1' }))"), "g001", "grant held by ta")
  as("ta"); T.expect(has(call(), ALLOW), "the holder")
  as("tc"); T.expect(has(call(), ALLOW), "its member")
  as("tb"); T.expect(not has(call(), ALLOW), "a sibling asks")
  as("tl"); T.expect(not has(call(), ALLOW), "its leader asks")
  T.eval("remuda._t_who = { kind = 'outside' }"); T.expect(not has(call(), ALLOW), "outside any session asks")
  T.eval("remuda._t_who = { kind = 'unknown' }"); T.expect(not has(call(), ALLOW), "unknown asks")
  T.eval("remuda._t_who = { kind = 'session', session = 's-nobody' }"); T.expect(not has(call(), ALLOW), "a session Butler does not know asks")
  untree()
  T.eq(count(lines(), '"event":"grant_used"'), 2, "two uses", "ok - tree")
end)

T.test("the alias in the env names nothing: a forged alias of the holder asks", function()
  fresh("h-forged", true)
  tree()
  T.eq(T.eval("return (remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'U-TA', event = '$ev1' }))"), "g001", "grant held by ta")
  as("tb") -- the env still says ss-a (the stand-in), and could say ta: only core's caller identity counts
  T.expect(not has(call(), ALLOW), "tb asks")
  untree()
  T.expect(not has(call(), ALLOW), "no caller identity at all asks", "ok - forged")
end)

T.test("the post names the holder from core's caller identity and the 🔄 grant is held by that session", function()
  fresh("h-make", true)
  tree()
  as("ta")
  T.eval("remuda._t_text = ''") -- every post of the request (HOME and the lounge copy)
  local first = tonumber(T.eval("return remuda._t_posts")) + 1
  T.eq(call(), "pending", "a post")
  local text = T.eval("return remuda._t_text")
  T.expect(has(text, "  holder:   ta and the sessions below it"), "holder line: " .. text)
  T.expect(has(text, "every call in this scope by that session and the sessions below it"), "reaction line: " .. text)
  T.eq(T.eval(("return tostring(remuda.butler.approval.answer('$p%d', 'grant', '@owner:x', '$r1'))"):format(first)), "true", "granted")
  local store = T.eval("local f = io.open(remuda.butler.guard_policy.dir() .. '/guard-grants.jsonl'); local s = f:read('a'); f:close(); return s")
  T.expect(has(store, '"holder":"U-TA"'), "held by ta's id: " .. store)
  T.eval("remuda.butler.guard_grants.verified = nil") -- the real cross-check against Butler's record of the reaction
  as("tc"); T.expect(has(call(), ALLOW), "its member")
  as("tb"); T.expect(not has(call(), ALLOW), "a sibling asks")
  -- the store line moved to another holder by hand: Butler's record of the reaction does not vouch for it
  T.eval("local p = remuda.butler.guard_policy.dir() .. '/guard-grants.jsonl'; local f = io.open(p); local s = f:read('a'); f:close(); f = io.open(p, 'w'); f:write((s:gsub('U%-TA', 'U-TB'))); f:close()")
  T.expect(not has(call(), ALLOW), "a hand-moved holder is no grant")
  T.eval("remuda.butler.guard_grants.verified = function() return true end")
  T.eval("remuda.caller = nil")
  T.eval("remuda._t_text = ''")
  T.eq(call("{ input = { url = 'https://other.example/' } }"), "pending", "a post without a caller identity")
  T.expect(not has(T.eval("return remuda._t_text"), "grant:"), "offers no grant")
  untree()
  T.eq(count(lines(), '"event":"grant_used"'), 1, "one use", "ok - make")
end)

T.test("the identity is taken once at hook entry: a caller that changes during the audit wait does not move the grant", function()
  fresh("h-entry", true)
  tree()
  T.eq(T.eval("return (remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'U-TA', event = '$ev1' }))"), "g001", "grant held by ta")
  -- The hook's own audit line (the first append) is where it can wait on the lock; core's answer changes there.
  local flip = [[local gp = remuda.butler.guard_policy; local real = gp.append; local n = 0
    gp.append = function(r) n = n + 1; if n == 1 then remuda._t_who = { kind = 'session', session = 's-%s' } end; return real(r) end
    remuda._t_unflip = function() gp.append = real end]]
  as("ta"); T.eval(flip:format("tb"))
  T.expect(has(call(), ALLOW), "entered as ta: allowed")
  T.eval("remuda._t_unflip()")
  as("tb"); T.eval(flip:format("ta")); T.eval("remuda._t_text = ''")
  T.eq(call(), "pending", "entered as tb: asks")
  T.expect(has(T.eval("return remuda._t_text"), "  holder:   tb and the sessions below it"), "the post offers tb's grant")
  T.eval("remuda._t_unflip()")
  untree()
  T.eq(count(lines(), '"event":"grant_used"'), 1, "one use", "ok - entry")
end)
