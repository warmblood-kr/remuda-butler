-- Guard slice 3, PR5 SEC (from #387): the per-scope post limit ignores command text; the standing-grant thread note is plain text.
-- Same relay stand-in as guard_slice3_reactions_limits.
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
    remuda._t_caller = function(alias, kind)
      alias = alias or 'ss-a'
      local member = remuda._butler_bus.agents[alias]
      if not member then
        member = { id = 'test-' .. alias, alias = alias, kind = kind or 'claude', session_name = 'test-' .. alias }
        remuda._butler_bus.agents[alias] = member
      end
      return { kind = 'session', session = member.session_name,
        env = { REMUDA_BUTLER_AGENT_ALIAS = alias, REMUDA_BUTLER_AGENT_KIND = kind or 'claude' } }
    end
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
      local caller = remuda._t_caller(over.alias, over.kind)
      caller.stdin = payload
      remuda._butler_command_run('guard', { 'guard' }, caller)
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
local function guard(...) return T.eval(("return remuda._butler_command_run('guard', {'guard', %s}, {kind='session', session='butler'})"):format(
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
local function at(offset) T.eval(("remuda.butler.guard_grants.now = function() return %d end"):format(1790000000 + offset)) end

T.test("SEC b: the per-scope post limit is keyed by tool, class and cwd, not command text", function()
  on("s-key")
  at(0)
  local variants = { "ls /tmp", "ls /tmp ", "ls /tmp ; :", "ls  /tmp", "ls /tmp;:", "ls /tmp #1", "ls /tmp #2", "ls /tmp #3", "ls /tmp #4", "ls /tmp #5" }
  for i, command in ipairs(variants) do
    T.expect(tonumber(T.eval(("return remuda._t_perm({ tool = 'Bash', input = { command = %q }, alias = 'ss-' .. %d })"):format(command, i))) > 0, "post " .. i)
    T.eq(answer(i, "approve"), "true nil", "answered " .. i)
  end
  T.eq(T.eval("return remuda._t_perm({ tool = 'Bash', input = { command = 'ls /tmp ;  :' }, alias = 'ss-x' })"), "0",
    "the 11th post for the same tool, class and cwd is refused whatever the text")
  T.expect(tonumber(T.eval("return remuda._t_perm({ tool = 'Bash', input = { command = 'ls /tmp' }, cwd = '/p/other', alias = 'ss-y' })")) > 0,
    "another cwd is asked", "ok - limit key")
end)

T.test("SEC b: a remembered deny still keeps the exact text", function()
  on("s-deny")
  at(0)
  local first = tonumber(T.eval("return remuda._t_perm({ tool = 'Bash', input = { command = 'ls /tmp' } })"))
  T.eq(answer(1, "deny"), "true nil", "crossed")
  T.eq(reply_out(first), "done:" .. DENY, "denied")
  T.eq(reply_out(tonumber(T.eval("return remuda._t_perm({ tool = 'Bash', input = { command = 'ls /tmp' } })"))), "done:" .. DENY, "same text: denied at once")
  T.expect(tonumber(T.eval("return remuda._t_perm({ tool = 'Bash', input = { command = 'ls /tmp ' } })")) > 0, "other text: asked", "ok - deny keeps text")
end)

T.test("SEC c: the Standing grant thread note strips @ and backticks from the scope", function()
  on("s-note")
  at(1000)
  T.eval([[remuda.butler.guard_grants.offer = function() return { class = 'git', scope = '/zz/a@room/`x`', ceiling = 'T2' } end]])
  T.eval("remuda._t_perm({ tool = 'Bash', input = { command = 'git push' } })")
  T.eq(answer(1, "grant"), "true nil", "granted")
  T.eval("remuda.butler.guard_grants.offer = nil; remuda.exec('butler/guard_grants')")
  local text = note()
  T.expect(text and has(text, "Standing grant g001: git /zz/aroom/x until"), "note posted, stripped: " .. tostring(text))
  T.expect(not has(text, "@") and not has(text, "`"), "no mention or markup survives", "ok - note strip")
end)
