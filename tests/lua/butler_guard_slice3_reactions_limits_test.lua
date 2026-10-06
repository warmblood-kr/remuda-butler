-- Guard slice 3, PR4: request limits, remembered crosses, the coalesced expiry notice, agent text and git offers.
-- Same relay stand-in as guard_slice3_reactions (its own file: the harness gives a file 20s in all).
-- tests/butler_matrix_relay.lua.
local started
local function start_butler()
  -- Installed once: a second install makes the daemon reload the mod, which would drop the approval state.
  if started then return end
  started = true
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
      remuda._butler_command_run('guard', { 'guard' }, { stdin = payload, env =
        { REMUDA_BUTLER_AGENT_ALIAS = over.alias or 'ss-a', REMUDA_BUTLER_AGENT_KIND = 'claude' } })
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
    remuda._butler_bus.agents['t-ssa'] = { id = 'U-SSA', parent = 'butler', alias = 't-ssa', session_name = 's-ssa', children = {} }
    remuda.caller = function() return { kind = 'session', session = 's-ssa' } end
    return 'ok'
  ]])
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end
local ALLOW = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
local DENY = '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":'
  .. '{"behavior":"deny","message":"Denied by the owner via Butler"}}}'
local function reply_out(n) return T.eval(("local r = remuda._t_replies[%d]; return r.done and ('done:' .. r.out) or 'waiting'"):format(n)) end
local function guard(...) return T.eval(("return remuda._butler_command_run('guard', {'guard', %s}, {})"):format(
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
-- The store's clock: now() is T0 + offset, set by the test.
local function at(offset) T.eval(("remuda.butler.guard_grants.now = function() return %d end"):format(1790000000 + offset)) end
local function perm(alias, host, over)
  return tonumber(T.eval(("return remuda._t_perm({ input = { url = 'https://%s/' }, alias = %q })"):format(host, alias)))
end

T.test("a cross is remembered for the same request for 10 minutes; others are asked as usual", function()
  on("l-deny")
  at(0)
  local first = perm("ss-a", "a.test")
  T.eq(answer(1, "deny"), "true nil", "the owner crosses it")
  T.eq(reply_out(first), "done:" .. DENY, "denied")
  local again = perm("ss-a", "a.test")
  T.eq(reply_out(again), "done:" .. DENY, "the same request is denied at once")
  T.eq(T.eval("return remuda._t_count()"), "1", "and not asked again")
  T.expect(has(T.eval("return remuda._t_lines()"), "remembered deny"), "audited")
  T.expect(perm("ss-a", "b.test") > 0, "another scope is still asked")
  T.eq(T.eval("return remuda._t_count()"), "2", "one more post")
  at(599)
  T.eq(reply_out(perm("ss-a", "a.test")), "done:" .. DENY, "still remembered after 599 s")
  at(601)
  T.eq(reply_out(perm("ss-a", "a.test")), "waiting", "asked again after 10 minutes")
  T.eq(T.eval("return remuda._t_count()"), "3", "a new post")
  guard("grants", "off")
  T.eq(answer(3, "deny"), "true nil", "a cross with grants off")
  T.eq(reply_out(perm("ss-a", "a.test")), "waiting", "is not remembered")
  T.expect(true, "", "ok - remembered deny")
end)

-- The agent names itself (alias / session), so no limit may depend on that name alone.
T.test("changing the alias does not escape a remembered cross or the per-scope post limit", function()
  on("l-alias")
  at(0)
  local first = perm("ss-a", "a.test")
  T.eq(answer(1, "deny"), "true nil", "the owner crosses it")
  T.eq(reply_out(first), "done:" .. DENY, "denied")
  T.eq(reply_out(perm("ss-renamed", "a.test")), "done:" .. DENY, "a new alias still hits the remembered cross")
  T.eq(T.eval("return remuda._t_count()"), "1", "and is not asked")
  for i = 1, 10 do
    T.expect(perm("ss-n" .. i, "s.test") > 0, "request " .. i .. " from a new alias")
    T.eq(answer(tonumber(T.eval("return remuda._t_count()")), "approve"), "true nil", "answered " .. i)
  end
  T.eq(perm("ss-n11", "s.test"), 0, "the 11th post for one scope in an hour is refused whatever the alias")
  T.expect(perm("ss-n11", "t.test") > 0, "another scope is asked", "ok - alias")
end)

T.test("the post tells the owner what the standing-grant reaction does in this version", function()
  on("l-truth")
  perm("ss-a", "a.test")
  T.expect(has(post(1), "🔄 to allow it and, until the time shown, every call in this scope by that session and the sessions below it"), "says so: " .. post(1))
  guard("grants", "off")
  perm("ss-a", "b.test")
  T.expect(not has(post(2), "grant"), "no grant words with the switch off", "ok - truth")
end)

T.test("at most 5 posts per agent per minute and 30 per hour overall; refused without a post", function()
  on("l-rate")
  at(0)
  for i = 1, 5 do
    T.expect(perm("ss-a", "h" .. i .. ".test") > 0, "request " .. i)
    T.eq(answer(i, "approve"), "true nil", "answered " .. i)
  end
  T.eq(perm("ss-a", "h6.test"), 0, "the sixth in a minute is refused: Claude shows its own prompt")
  T.eq(T.eval("return remuda._t_count()"), "5", "without a post")
  T.expect(has(T.eval("return remuda._t_lines()"), '"event":"approval_limited"'), "audited")
  T.expect(perm("ss-b", "h6.test") > 0, "another agent is not limited")
  at(61)
  T.expect(perm("ss-a", "h7.test") > 0, "a minute later the agent may ask again")
  T.eval([[for i = 1, 23 do
    remuda._t_perm({ input = { url = 'https://g' .. i .. '.test/' }, alias = 'ss-g' .. math.floor(i / 5) })
    remuda._t_answer(remuda._t_count(), 'approve')
  end]])
  T.eq(T.eval("return remuda._t_count()"), "30", "30 posts in the hour")
  T.eq(perm("ss-new", "z.test"), 0, "the 31st is refused")
  at(3601)
  T.expect(perm("ss-new", "z.test") > 0, "an hour later it is asked", "ok - rate limits")
end)

T.test("grants that expire together get one notice, after 60 s, in the owner room", function()
  on("l-expiry")
  at(0)
  perm("ss-a", "a.test"); perm("ss-a", "b.test")
  T.eq(answer(1, "grant"), "true nil", "first grant")
  at(30)
  T.eq(answer(2, "grant"), "true nil", "second grant")
  local function sweep(offset) at(offset); T.eval("remuda.butler.approval.sweep()") end
  local function posts() return tonumber(T.eval("return remuda._t_count()")) end
  sweep(100)
  T.eq(posts(), 2, "nothing while they run")
  sweep(3601)
  sweep(3631)
  T.eq(posts(), 2, "g001 has expired but the notice waits for company")
  sweep(3660)
  T.eq(posts(), 2, "59 s after the first")
  sweep(3662)
  T.eq(posts(), 3, "one notice")
  local text = post(3)
  T.expect(has(text, "Standing grants expired: g001 net a.test, g002 net b.test."), "names both: " .. text)
  sweep(5000); sweep(9000)
  T.eq(posts(), 3, "and only one")
  -- nothing is read with the switch off
  at(10000)
  perm("ss-b", "c.test")
  answer(3, "grant")
  guard("grants", "off")
  sweep(10010)
  T.eq(T.eval("local n = 0; for _ in pairs(remuda.butler.guard_approval._exp.tracked) do n = n + 1 end; return n"), "0", "the tracker is dropped", "ok - expiry notice")
end)

T.test("the expiry notice strips @ and backticks from scope text", function()
  on("l-strip")
  at(1000)
  T.eval([[local g = remuda.butler.guard_approval
    g._exp.due = { { id = 'g009', class = 'git', scope = '/p/@room/`x`/@alice:x.org', expires = 0 } }
    g._exp.first = 0
    remuda.butler.approval.sweep()]])
  local text = post(1)
  T.expect(text and has(text, "Standing grants expired: g009 git /p/room/x/alice:x.org."), "the notice is posted, scope stripped: " .. tostring(text))
  T.expect(not has(text, "@") and not has(text, "`"), "no mention or markup survives", "ok - strip")
end)

T.test("agent text is one labelled, escaped, stripped line of at most 200 characters, after Butler's own lines", function()
  on("l-note")
  local note = "do it @room\nsee https://evil.test/x <b>**now**</b> `x` \u{202E}" .. string.rep("y", 300)
  T.eval(("remuda._t_perm({ tool = 'Bash', input = { command = 'git push', description = %q } })"):format(note))
  local text = post(1)
  local last = text:match("([^\n]*)$")
  T.expect(last:match('^agent%-supplied: ".*"$'), "last line is the labelled quote: " .. last)
  T.expect(#last <= 200 + #'agent-supplied: ""' + 20, "capped: " .. #last)
  for _, bad in ipairs({ "@", "http", "<", "*", "`", "\226\128\174" }) do T.expect(not has(last, bad), "stripped " .. bad .. ": " .. last) end
  T.expect(has(last, "\\u202E") and has(last, "[link]"), "escaped and linked out: " .. last)
  T.expect(has(text, "No answer: the agent shows its own prompt.\nagent-supplied:"), "after Butler's lines", "ok - agent text")
end)

T.test("a plain push is offered a git grant for its working directory and the grant covers the next push", function()
  on("l-git")
  local work = T.eval([[local root = os.getenv('XDG_DATA_HOME') .. '/l-git-tree'
    local script = table.concat({ 'set -e', 'mkdir -p ' .. root, 'cd ' .. root, 'git init -q --bare remote.git',
      'git clone -q remote.git work 2>/dev/null', 'cd work', 'git config user.email t@t; git config user.name t',
      'echo a > a; git add a; git commit -q -m a', 'git branch -q -M feat; git push -q -u origin HEAD 2>/dev/null',
      'echo b > b; git add b; git commit -q -m b' }, '\n')
    remuda.process.run({ argv = { 'sh', '-c', script } })
    return (remuda.fs.realpath(root .. '/work'))]])
  T.eval(("remuda._t_perm({ tool = 'Bash', input = { command = 'git push' }, cwd = %q })"):format(work))
  T.expect(has(post(1):lower(), ("grant:    git " .. work .. " until"):lower()), "offered (the scope is case-folded on a case-insensitive volume): " .. post(1))
  T.eq(answer(1, "grant"), "true nil", "granted")
  T.eq(T.eval(("return tostring(remuda.butler.guard_grants.match('Bash', { command = 'git push' }, %q))"):format(work)), "g001",
    "the next plain push is covered", "ok - git offer")
end)
