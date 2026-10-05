-- Guard slice 3, PR7: the daily audit digest posted to the owner room.
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
    return 'ok'
  ]])
end
local DAY = 1791072000 -- 2026-10-04T00:00:00Z
local function at(offset) T.eval(("remuda.butler.guard_policy.now = function() return %d end"):format(DAY + offset)) end
local function posts() return tonumber(T.eval("return #remuda._t_posts")) end
local function text(n) return T.eval(("return remuda._t_posts[%d].text"):format(n)) end
local function sweep(offset) at(offset); T.eval("remuda.butler.approval.sweep()") end
-- Fresh data dir and relay stand-in; a restart forgets the in-memory digest state only.
local function fresh(name)
  start_butler()
  T.eval(("remuda._t_dir('%s'); remuda._t_attach(); remuda.butler.guard_approval._dg = { checked = 0 }"):format(name))
end
local function restart() T.eval("remuda.butler.guard_approval._dg = { checked = 0 }") end
local function lines_of_day(day) return T.eval(("local n = 0; for l in remuda._t_lines():gmatch('[^\\n]+') do if l:find('\"time\":\"%s', 1, true) then n = n + 1 end end; return n"):format(day)) end

T.test("one digest per day goes to the owner room: count, last line hash, previous digest", function()
  fresh("d-one")
  at(36000) -- 2026-10-04 10:00
  T.eval("remuda._butler_command_run('guard', {'guard','on'}, {}); remuda.butler.guard_policy.observe('x', 's', 'claude', 'y')")
  local all = T.eval("return remuda._t_lines()")
  local last = all:match("[^\n]+$")
  sweep(40000)
  T.eq(posts(), 0, "the day is not over")
  sweep(86400 + 300) -- the next day
  T.eq(posts(), 1, "one digest")
  local want = "Butler audit digest for 2026-10-04 (UTC): 3 lines, last line hash " .. T.eval(("return remuda.butler.guard_approval.sha256(%q)"):format(last))
    .. ", previous digest none."
  T.eq(text(1), want, "text")
  sweep(86400 + 4000)
  T.eq(posts(), 1, "and only one that day", "ok - digest")
end)

T.test("a restart does not post the same day again; the next day names the previous digest", function()
  fresh("d-restart")
  at(36000)
  T.eval("remuda._butler_command_run('guard', {'guard','on'}, {})")
  sweep(86400 + 300)
  T.eq(posts(), 1, "first digest")
  restart()
  sweep(86400 + 3600)
  T.eq(posts(), 1, "no double post after a restart")
  local first = text(1)
  at(86400 + 40000)
  T.eval("remuda.butler.guard_policy.observe('x', 's', 'claude', 'y')")
  sweep(2 * 86400 + 300)
  T.eq(posts(), 2, "the next day")
  local hash = T.eval(("return remuda.butler.guard_approval.sha256(%q)"):format(first))
  T.expect(text(2):find("for 2026-10-05 (UTC): 1 lines", 1, true) and text(2):find("previous digest " .. hash .. ".", 1, true), "chain: " .. text(2), "ok - restart")
end)

T.test("a failed post is retried on a later tick and never blocks the audit", function()
  fresh("d-retry")
  at(36000)
  T.eval("remuda._butler_command_run('guard', {'guard','on'}, {})")
  T.eval("local a = remuda.butler.approval; remuda._t_notify = a.notify; a.notify = function() return nil, 'down' end")
  sweep(86400 + 300)
  T.eq(posts(), 0, "nothing posted")
  T.eval("remuda.butler.guard_policy.observe('x', 's', 'claude', 'y')")
  T.expect(lines_of_day("2026-10-05") == "1", "audit still written")
  T.eval("remuda.butler.approval.notify = remuda._t_notify")
  sweep(86400 + 330)
  T.eq(posts(), 0, "throttled to once a minute")
  sweep(86400 + 400)
  T.eq(posts(), 1, "retried", "ok - retry")
end)

-- Count the daemon's scans of the audit files (a wrapper around day_facts, installed once).
local function scans()
  T.eval([[local gp = remuda.butler.guard_policy
    if not remuda._t_real_facts then
      remuda._t_real_facts = gp.day_facts
      gp.day_facts = function(d) remuda._t_scans = (remuda._t_scans or 0) + 1; return remuda._t_real_facts(d) end
    end]])
  return tonumber(T.eval("return remuda._t_scans or 0"))
end
local function reset_scans() scans(); T.eval("remuda._t_scans = 0") end

T.test("a quiet day (no audit lines) is scanned once, not on every tick", function()
  fresh("d-quiet")
  reset_scans()
  sweep(86400 + 300)
  sweep(86400 + 400)
  sweep(86400 + 500)
  T.eq(posts(), 0, "no digest for a day without lines")
  T.eq(scans(), 1, "one scan", "ok - quiet")
end)

T.test("a failed post is retried from the cached facts, without scanning again", function()
  fresh("d-noscan")
  at(36000)
  T.eval("remuda._butler_command_run('guard', {'guard','on'}, {})")
  reset_scans()
  T.eval("local a = remuda.butler.approval; remuda._t_notify = a.notify; a.notify = function() return nil, 'down' end")
  sweep(86400 + 300)
  sweep(86400 + 400)
  sweep(86400 + 500)
  T.eq(scans(), 1, "scanned once while the post keeps failing")
  T.eval("remuda.butler.approval.notify = remuda._t_notify")
  sweep(86400 + 600)
  T.eq(posts(), 1, "posted")
  T.eq(scans(), 1, "and still one scan", "ok - noscan")
end)

T.test("an archive stamped before the day cannot hold it and is not read", function()
  fresh("d-skip")
  T.eval([[local gp = remuda.butler.guard_policy
    local f = io.open(gp.log_path() .. '.20260101T000000Z', 'w')
    f:write('{"time":"2026-10-04T10:00:00Z","summary":"forged"}\n'); f:close()]])
  T.eq(T.eval("return (remuda.butler.guard_policy.day_facts('2026-10-04'))"), "0", "stamp Jan 1 < Oct 4", "ok - skip")
end)

T.test("after downtime each day with lines is attested, oldest first, and the chain stays linked", function()
  fresh("d-gap")
  at(36000) -- 10-04
  T.eval("remuda._butler_command_run('guard', {'guard','on'}, {})")
  sweep(86400 + 300)
  T.eq(posts(), 1, "10-04")
  at(86400 + 36000) -- 10-05
  T.eval("remuda.butler.guard_policy.observe('x', 's', 'claude', 'y')")
  at(3 * 86400 + 36000) -- 10-07, none on 10-06: the daemon was down
  T.eval("remuda.butler.guard_policy.observe('x', 's', 'claude', 'y')")
  sweep(4 * 86400 + 300) -- 10-08
  T.eq(posts(), 3, "10-05 and 10-07 both attested")
  local h1 = T.eval(("return remuda.butler.guard_approval.sha256(%q)"):format(text(1)))
  local h2 = T.eval(("return remuda.butler.guard_approval.sha256(%q)"):format(text(2)))
  T.expect(text(2):find("for 2026-10-05 (UTC)", 1, true) and text(2):find("previous digest " .. h1 .. ".", 1, true), "2: " .. text(2))
  T.expect(text(3):find("for 2026-10-07 (UTC)", 1, true) and text(3):find("previous digest " .. h2 .. ".", 1, true), "3: " .. text(3), "ok - gap")
end)
