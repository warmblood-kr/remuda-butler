-- Guard slice 3: the daily digest after long downtime (the 7-day catch-up cap) and quiet days after a digest.
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

T.test("after ten days down only the last seven days are attested, oldest first", function()
  fresh("d-cap")
  at(36000) -- 10-04
  T.eval("remuda._butler_command_run('guard', {'guard','on'}, {kind='session', session='butler'})")
  sweep(86400 + 300)
  T.eq(posts(), 1, "10-04")
  for day = 1, 10 do -- a line on each of 10-05 .. 10-14
    at(day * 86400 + 36000)
    T.eval("remuda.butler.guard_policy.observe('x', 's', 'claude', 'y')")
  end
  sweep(11 * 86400 + 300) -- 10-15
  T.eq(posts(), 8, "seven more, not ten")
  T.expect(text(2):find("for 2026-10-08 (UTC)", 1, true), "oldest attested is 10-08: " .. text(2))
  T.expect(text(8):find("for 2026-10-14 (UTC)", 1, true), "newest is 10-14: " .. text(8), "ok - cap")
end)

T.test("quiet days after a digest are each scanned once, not on every tick", function()
  fresh("d-quiet3")
  at(36000)
  T.eval("remuda._butler_command_run('guard', {'guard','on'}, {kind='session', session='butler'})")
  sweep(86400 + 300)
  T.eq(posts(), 1, "10-04")
  reset_scans()
  sweep(4 * 86400 + 300) -- 10-08: 10-05 .. 10-07 had no lines
  sweep(4 * 86400 + 400)
  sweep(4 * 86400 + 500)
  T.eq(posts(), 1, "no digest for quiet days")
  T.eq(scans(), 3, "each quiet day scanned once", "ok - quiet days")
end)
