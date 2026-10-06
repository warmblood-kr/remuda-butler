-- Guard slice 3, PR-B (#339): 30 uses per grant per rolling hour, the count rebuilt from the audit log after a start.
local started
local function start_butler()
  -- Installed once per file: a second install reloads the mod (the harness gives a file 20 s in all).
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
    remuda._t_guard = function(args) return remuda._butler_command_run('guard', args, {}) end
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
    .. " local g = remuda.butler.guard_grants; g._uses, g._limited, g._clock = {}, {}, { high = 0 }"):format(name))
  T.eval("remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','approvals','on'}); remuda._t_guard({'guard','grants','on'})")
  if not no_grant then
    T.eq(T.eval("return (remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'ss-a', event = '$ev1' }))"), "g001", "grant")
  end
end
local function call(over) return T.eval("return remuda._t_call(" .. (over or "{}") .. ")") end
local function lines() return T.eval("return remuda._t_lines()") end
local function count(text, needle) local n = 0; for _ in text:gmatch(needle) do n = n + 1 end; return n end
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
  T.eq(T.eval("return (remuda._t_add({ class = 'net', scope = 'example.com', ceiling = 'T2', holder = 'ss-a', event = '$ev1', ttl = 86400 }))"), "g001", "grant")
end
local function restart() T.eval("local g = remuda.butler.guard_grants; g._uses, g._limited = {}, {}") end

T.test("30 uses an hour are allowed, the 31st asks and writes grant_limited once, the next hour allows again", function()
  fresh_at("c-limit")
  T.eq(uses(30), 30, "thirty allowed")
  T.eq(uses(2), 0, "31st and 32nd ask")
  local text = lines()
  T.eq(count(text, '"event":"grant_used"'), 30, "thirty grant_used lines")
  T.eq(count(text, '"event":"grant_limited"[^\n]*"grant_id":"g001"'), 1, "one grant_limited line")
  at(3601)
  T.eq(uses(1), 1, "an hour later", "ok - ceiling")
end)

T.test("after a restart the count is rebuilt from the live audit log; an unreadable log asks", function()
  fresh_at("c-rebuild")
  T.eq(uses(10), 10, "ten before the restart")
  restart()
  T.eq(uses(21), 20, "twenty more, the 31st asks")
  restart()
  at(1800)
  local log = T.eval("return remuda.butler.guard_policy.log_path()")
  T.eval(("os.rename(%q, %q)"):format(log, log .. ".away"))
  T.eval(("remuda.process.run({ argv = { 'mkdir', %q } })"):format(log)) -- a directory: opens, reads nothing
  T.eq(uses(1), 0, "log unreadable on rebuild: asks")
  T.eval(("remuda.process.run({ argv = { 'rmdir', %q } }); os.rename(%q, %q)"):format(log, log .. ".away", log))
  restart()
  at(3601)
  T.eq(uses(1), 1, "the first ten aged out, the hour rolls", "ok - rebuild")
end)

