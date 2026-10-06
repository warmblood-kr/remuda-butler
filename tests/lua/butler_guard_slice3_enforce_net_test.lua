-- Guard slice 3, PR-B (#339): a WebFetch grant allows only its exact host while it is live.
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
local function asks(over, why)
  local reply = call(over)
  T.expect(not has(reply, ALLOW), why .. ": " .. reply)
end
local function url(u) return ("{ input = { url = %q } }"):format(u) end
local function clock(offset)
  T.eval(("local t = os.time() + %d; remuda.butler.guard_grants.now = function() return t end"):format(offset))
end

T.test("only the exact host and port: no IP, userinfo, subdomain or other port", function()
  fresh("n-host")
  T.expect(has(call(url("https://example.com:443/a")), ALLOW), "control: default port")
  for _, u in ipairs({ "https://93.184.216.34/", "https://u@example.com/", "https://www.example.com/",
    "https://example.com:8443/", "https://example.com.evil.test/", "http://example.com\\@x/" }) do
    asks(url(u), u)
  end
  T.eq(count(lines(), '"event":"grant_used"'), 1, "one use", "ok - host")
end)

T.test("expired, revoked, frozen, written in the future, unverified or T3: no allow", function()
  fresh("n-life")
  clock(-30)
  asks("{}", "written in the future")
  T.eval("remuda.butler.guard_grants.now = nil")
  T.expect(has(call(), ALLOW), "control: live")
  T.eval("remuda.butler.guard_grants.verified = function() return false end")
  asks("{}", "unverified")
  T.eval("remuda.butler.guard_grants.verified = function() return true end")
  T.eq(T.eval("return (remuda._t_controls.freeze())"), "frozen", "freeze")
  asks("{}", "frozen")
  T.eq(T.eval("return (remuda._t_controls.unfreeze())"), "lifted", "unfreeze")
  T.expect(has(call(), ALLOW), "control: lifted")
  T.eq(T.eval("return (remuda._t_controls.revoke('g001'))"), "revoked", "revoke")
  asks("{}", "revoked")
  T.eval([[local t = os.time()
    local f = io.open(remuda.butler.guard_policy.dir() .. '/guard-grants.jsonl', 'a')
    f:write(remuda.json.encode({ id = 'g002', class = 'net', scope = 't3.example', ceiling = 'T3', holder = 'ss-a',
      event = '$ev2', written = t - 5, expires = t + 600 }) .. '\n'); f:close()]])
  asks(url("https://t3.example/"), "T3 entry")
  clock(3601) -- last: a forward jump raises the clock's high mark
  asks("{}", "expired")
  T.eq(count(lines(), '"event":"grant_used"'), 2, "only the two controls", "ok - life")
end)
