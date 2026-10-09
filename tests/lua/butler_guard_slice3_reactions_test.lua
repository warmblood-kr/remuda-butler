-- Guard slice 3, PR4: the owner's reactions on Butler's approval post (check = once, cycle = standing grant,
-- cross = deny). The relay is faked as in guard_slice1: a recording post function; the owner gate is tested in
-- tests/butler_matrix_relay.lua.
local started
local function start_butler()
  -- Installed once: a second install makes the daemon reload the mod, which would drop the approval state.
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
    remuda._t_posts, remuda._t_replies = {}, {}
    remuda.pending = function(opts)
      local r = { opts = opts }
      function r:resolve(code, out, err) self.done, self.code, self.out = true, code, out end
      remuda._t_replies[#remuda._t_replies + 1] = r
      return r
    end
    -- A relay stand-in: posts are recorded and acknowledged with an event id.
    remuda._t_attach = function()
      remuda._t_state = { approvals = remuda.json.object({}) }
      remuda._t_posts = {}
      remuda.butler.approval.attach(remuda._t_state, function() return true end, function(text, relation, cb)
        local post = { text = text, relation = relation }
        remuda._t_posts[#remuda._t_posts + 1] = post
        post.event_id = '$p' .. #remuda._t_posts
        if cb then cb({ event_id = post.event_id }) end
        return {}
      end)
    end
    remuda._t_perm = function(over)
      local payload = remuda.json.encode({ hook_event_name = 'PermissionRequest', tool_name = over.tool or 'WebFetch',
        tool_input = over.input, cwd = over.cwd or '/p/w', session_id = 's1' })
      local before = #remuda._t_replies
      remuda._butler_command_run('guard', { 'guard' }, { kind = 'session',
        session = 's-ssa', stdin = payload })
      if #remuda._t_replies > before then return #remuda._t_replies end
      return 0
    end
    remuda._t_event = function(n)
      local seen = 0
      for _, p in ipairs(remuda._t_posts) do
        if not p.relation then seen = seen + 1; if seen == n then return p.event_id end end
      end
    end
    remuda._t_count = function() local n = 0; for _, p in ipairs(remuda._t_posts) do if not p.relation then n = n + 1 end end; return n end
    remuda._t_answer = function(n, verdict, who)
      return remuda.butler.approval.answer(remuda._t_event(n), verdict, who or '@owner:x', '$r' .. n)
    end
    remuda._t_grants = function() return #remuda.butler.guard_grants.active() end
    -- The calling session by core's caller identity (a grant offer needs one; holders: enforce_holder).
    remuda._butler_bus.agents['t-ssa'] = { id = 'U-SSA', parent = 'butler', alias = 't-ssa', kind = 'claude', session_name = 's-ssa', children = {} }
    remuda._butler_bus.agents['ss-a'] = nil -- keep this session uniquely registered
    remuda.caller = function() return { kind = 'session', session = 's-ssa' } end
    return 'ok'
  ]])
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end
local ALLOW = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
local DENY = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":'
  .. '{"behavior":"deny","message":"Denied by the owner via Butler"}}}'
local function reply_out(n) return T.eval(("local r = remuda._t_replies[%d]; return r.done and ('done:' .. r.out) or 'waiting'"):format(n)) end
local function guard(...) return T.eval(("return remuda._butler_command_run('guard', {'guard', %s}, {kind='session', session = 'butler', instance_id = _inst('butler')})"):format(
  table.concat((function(t) for i, v in ipairs(t) do t[i] = string.format("%q", v) end return t end)({ ... }), ", "))) end
-- Guard and approvals on, a fresh data dir and a fresh relay stand-in; grants on unless told otherwise.
local function on(name, grants)
  start_butler()
  T.eval(("remuda._t_dir('%s'); remuda._t_attach()"):format(name))
  T.eval("local g = remuda.butler.guard_approval; g._limits = { agent = {}, hour = {}, denies = {} }; g._exp = { tracked = {}, due = {}, checked = 0 }; remuda.butler.guard_grants.now = nil")
  guard("on"); guard("approvals", "on")
  guard("grants", grants == false and "off" or "on")
end
local function fetch(url, alias)
  return tonumber(T.eval(("return remuda._t_perm({ input = { url = %q }, alias = %q })"):format(url, alias or "ss-a")))
end
-- The nth request post, and the last thread reply.
local function post(n)
  return T.eval(("local seen = 0; for _, p in ipairs(remuda._t_posts) do if not p.relation then seen = seen + 1; if seen == %d then return p.text end end end"):format(n))
end
local function note() return T.eval("local last; for _, p in ipairs(remuda._t_posts) do if p.relation then last = p.text end end; return last") end
local function answer(n, verdict, who)
  return T.eval(("local ok, why = remuda._t_answer(%d, %q, %s); return tostring(ok) .. ' ' .. tostring(why)")
    :format(n, verdict, who and string.format("%q", who) or "nil"))
end
local function grants() return tonumber(T.eval("return remuda._t_grants()")) end

T.test("the post offers the standing grant (resolved scope, absolute expiry) only with the switch on", function()
  on("r-offer", false)
  fetch("https://Example.com/x")
  T.expect(not has(post(1), "🔄") and has(post(1), "React ✅ to allow this one call, ❌ to deny."), "switch off, post unchanged: " .. post(1))
  guard("grants", "on")
  fetch("https://Example.com/x")
  for _, piece in ipairs({ "🔄", "  grant:    net example.com until 20", "(about 60 min)", "ceiling T2" }) do
    T.expect(has(post(2), piece), "post lacks " .. piece .. ": " .. post(2))
  end
  fetch("rm -rf /x")
  T.expect(not has(post(2), "agent-supplied"), "no agent text unless supplied")
  T.expect(true, "", "ok - offer")
end)

T.test("only the cycle reaction creates a grant, once, and it also allows the call", function()
  on("r-create")
  local n = fetch("https://example.com/x")
  T.eq(reply_out(n), "waiting", "hook waits")
  T.eq(answer(1, "grant"), "true nil", "the cycle reaction is accepted")
  T.eq(reply_out(n), "done:" .. ALLOW, "and allows this call")
  T.eq(grants(), 1, "one grant")
  local list = guard("grants")
  T.expect(has(list, "g001  net  example.com  ceiling T2  holder U-SSA") and has(list, "event $r1"), "list: " .. list)
  T.eq(answer(1, "grant"), "nil Already answered.", "a second cycle reaction is consumed")
  T.eq(answer(1, "approve"), "nil Already answered.", "so is a later check")
  T.eq(grants(), 1, "still one grant")
  local lines = T.eval("return remuda._t_lines()")
  T.expect(has(lines, '"event":"grant_created"') and has(lines, '"grant_id":"g001"'), "audit: " .. lines)
  T.expect(has(note(), "Standing grant g001"), "thread note: " .. note(), "ok - create")
end)

T.test("check and cross create nothing", function()
  on("r-none")
  local a, b = fetch("https://example.com/a"), fetch("https://example.com/b")
  T.eq(answer(1, "approve"), "true nil", "check")
  T.eq(answer(2, "deny"), "true nil", "cross")
  T.eq(reply_out(a), "done:" .. ALLOW, "once allows")
  T.eq(reply_out(b), "done:" .. DENY, "deny denies")
  T.eq(grants(), 0, "no grant from check or cross")
  T.expect(true, "", "ok - check and cross")
end)

T.test("no grant when the switch went off, the call is not grantable, or the owner is the terminal", function()
  on("r-gate")
  local n = fetch("https://example.com/x")
  guard("grants", "off")
  T.eq(answer(1, "grant"), "nil Standing grants are off.", "switch off at reaction time")
  T.eq(reply_out(n), "waiting", "the request stays open")
  T.expect(has(note(), "Standing grants are off."), "the owner is told: " .. note())
  guard("grants", "on")
  local m = fetch("https://example.com/y")
  T.eq(answer(2, "grant", "operator (terminal)"), "nil A guarded tool call can only be approved by the owner in its live Matrix thread.", "terminal")
  local k = tonumber(T.eval("return remuda._t_perm({ tool = 'Bash', input = { command = 'rm -rf /x' } })"))
  T.expect(not has(post(3), "🔄"), "an ungrantable call is not offered a grant: " .. post(3))
  T.eq(answer(3, "grant"), "nil No standing grant is offered for this request.", "grant reaction without an offer")
  T.eq(answer(3, "approve"), "true nil", "the request stayed open")
  T.eq(grants(), 0, "nothing created")
  T.eq(reply_out(m), "waiting", "terminal refusal leaves the request waiting")
  T.expect(reply_out(k) ~= nil, "", "ok - gates")
end)

T.test("a forged store line is no grant: an unknown event, or a real reaction reused for another scope or id", function()
  on("r-forge")
  fetch("https://example.com/x")
  T.eq(answer(1, "grant"), "true nil", "a real grant")
  T.eval([[local g = remuda.butler.guard_grants
    local f = assert(io.open(remuda.butler.guard_policy.dir() .. '/guard-grants.jsonl', 'a'))
    local t = g.time()
    for _, e in ipairs({ { 'g002', 'evil.test', '$nope' }, { 'g003', 'evil.test', '$r1' }, { 'g004', 'example.com', '$r1' } }) do
      f:write(remuda.json.encode({ id = e[1], class = 'net', scope = e[2], ceiling = 'T2', holder = 'ss-a', event = e[3],
        written = t, expires = t + 3000 }), '\n')
    end
    f:close()]])
  T.eq(grants(), 1, "only the grant the owner's reaction made")
  local ids = T.eval("local out = {}; for _, g in ipairs(remuda.butler.guard_grants.active()) do out[#out + 1] = g.id end; return table.concat(out, ',')")
  T.eq(ids, "g001", "forged lines are not active")
  local function m(url) return T.eval(("return tostring(remuda.butler.guard_grants.match('WebFetch', { url = %q }, '/'))"):format(url)) end
  T.eq(m("https://evil.test/"), "nil", "a forged line allows nothing")
  T.eq(m("https://example.com/"), "g001", "control: the real grant covers its host")
  T.eq(T.eval("return tostring(remuda.butler.guard_grants.verified)"), "nil", "the real cross-check is in force")
  T.expect(true, "", "ok - forged line")
end)

T.test("a refused registration is logged loudly and no reaction then creates a grant", function()
  on("r-loud")
  -- A reload of the approval module alone: the grant module already handed its add out.
  T.eval("remuda.exec('butler/guard_approval')")
  T.expect(has(T.eval("return remuda._t_lines()"), '"event":"grant_register_refused"'), "audit: " .. T.eval("return remuda._t_lines()"))
  fetch("https://example.com/x")
  T.eq(answer(1, "grant"), "nil Standing grants cannot be created: the reaction handler is not registered.", "refused")
  T.eq(grants(), 0, "nothing created")
  T.eval("remuda.exec('butler/guard_grants'); remuda.exec('butler/guard_approval')") -- back to a registered handler
  fetch("https://example.com/y")
  T.eq(answer(2, "grant"), "true nil", "a clean reload registers again", "ok - loud refusal")
end)
