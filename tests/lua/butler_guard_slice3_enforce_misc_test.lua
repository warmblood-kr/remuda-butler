-- Guard slice 3, PR-B (#339): an agent-supplied grant_id is ignored, a clock set back matches nothing, and with no grant, matching spawns nothing.
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
    remuda._t_guard = function(args) return remuda._butler_command_run('guard', args, {kind='session', session = 'butler', instance_id = _inst('butler')}) end
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
      local r = remuda._butler_command_run('guard', { 'guard' }, { kind = 'session', session = 's-ssa', stdin = payload })
      if type(r) == 'table' then return 'pending' end
      return tostring(r)
    end
    -- The calling session by core's caller identity: a grant held by U-SSA covers it (holders: enforce_holder).
    remuda._butler_bus.agents['t-ssa'] = { id = 'U-SSA', parent = 'butler', alias = 't-ssa', kind = 'claude', session_name = 's-ssa', children = {} }
    remuda._butler_bus.agents['ss-a'] = nil -- keep this session uniquely registered
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

T.test("a grant_id in the payload or the tool input is ignored", function()
  fresh("e-forged")
  local reply = call("{ grant_id = 'g001', input = { url = 'https://other.example/x', grant_id = 'g001' } }")
  T.expect(not has(reply, ALLOW), "no allow for another host: " .. reply)
  local text = lines()
  T.expect(not has(text, '"grant_id":"g001"'), "no line names g001: " .. text)
  T.expect(has(text, '"event":"PermissionRequest"') and has(text, '"grant_id":"-"'), "the request line: " .. text, "ok - forged id")
end)


local T0 = 1791072000 + 36000 -- 2026-10-04T10:00:00Z
local function at(offset)
  T.eval(("local t = %d; remuda.butler.guard_policy.now = function() return t end; remuda.butler.guard_grants.now = function() return t end"):format(T0 + offset))
end
-- n hook calls in the daemon; returns how many were allowed.
local function uses(n)
  return tonumber(T.eval(("local a = 0; for _ = 1, %d do if remuda._t_call({}):find('allow', 1, true) then a = a + 1 end end; return a"):format(n)))
end
-- A fresh dir whose grant is written at the test clock.
local function fresh_at(name)
  fresh(name, true)
  at(0)
  T.eq(T.eval("return (remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'U-SSA', event = '$ev1', ttl = 86400 }))"), "g001", "grant")
end
T.test("a clock set back more than a minute matches nothing until it catches up", function()
  fresh_at("c-skew")
  at(200)
  T.eq(uses(1), 1, "control")
  at(80)
  T.eq(uses(1), 0, "two minutes back")
  at(170)
  T.eq(uses(1), 1, "within a minute is no skew")
  at(140) -- the high mark is 200
  T.eq(uses(1), 1, "exactly a minute back is no skew")
  at(205)
  T.eq(uses(1), 1, "caught up", "ok - skew")
end)

T.test("grants on with no grant: grant matching spawns no process and stays cheap", function()
  fresh("n-cost", true)
  -- the approval post (which probes git to offer a grant) is not what is measured here
  local r = T.eval([[local real, spawned = remuda.process.run, 0
    local ga = remuda.butler.guard_approval; local post = ga.maybe_request; ga.maybe_request = function() end
    remuda.process.run = function(o) spawned = spawned + 1; remuda._t_argv = table.concat(o.argv, " "):sub(1, 120); return real(o) end
    local function run(n, input)
      local t0 = os.clock()
      for _ = 1, n do remuda._t_call({ tool = 'Bash', input = { command = 'git push' } }); remuda._t_call({}) end
      return os.clock() - t0
    end
    local on = run(20)
    remuda.process.run = real
    remuda._t_guard({'guard','grants','off'})
    local off = run(20)
    ga.maybe_request = post
    return spawned .. ' ' .. string.format('%.2f', (on - off) / 40 * 1000)]])
  local spawned, extra = r:match("^(%d+) (%S+)$")
  T.eq(spawned, "0", "no process: " .. T.eval("return remuda._t_argv"))
  T.expect(tonumber(extra) < 5, "under 5 ms a call over grants off: " .. extra, "ok - cost")
end)
