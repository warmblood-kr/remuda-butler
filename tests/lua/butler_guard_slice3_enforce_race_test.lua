-- Guard slice 3, PR-B (#339): a use is reserved before its audit write, so a hook that runs while another waits on the audit lock cannot pass the hourly limit; an empty agent kind asks.
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
    -- The calling session by core's caller identity: a grant held by U-SSA covers it (holders: enforce_holder).
    remuda._butler_bus.agents['t-ssa'] = { id = 'U-SSA', parent = 'butler', alias = 't-ssa', session_name = 's-ssa', children = {} }
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

T.test("two hooks at 29 uses: while the first waits on its audit write, the second cannot take the 30th use too", function()
  fresh_at("r-race")
  T.eq(uses(29), 29, "twenty-nine allowed")
  -- The audit write of the next use runs another hook call before it returns (as a yield on the audit lock would).
  T.eval([[local p = remuda.butler.guard_policy; local real = p.append; remuda._t_append = real
    p.append = function(r)
      if r.event == 'grant_used' and not remuda._t_inner then
        remuda._t_inner = remuda._t_call({})
      end
      return real(r)
    end]])
  local outer = T.eval("return remuda._t_call({})")
  local inner = T.eval("local p = remuda.butler.guard_policy; p.append = remuda._t_append; return remuda._t_inner")
  local allowed = (has(outer, ALLOW) and 1 or 0) + (has(inner, ALLOW) and 1 or 0)
  T.eq(allowed, 1, "one of the two takes the 30th use")
  T.eq(count(lines(), '"event":"grant_used"'), 30, "thirty uses in the hour", "ok - race")
end)

T.test("a failed audit write gives its reserved use back", function()
  fresh_at("r-release")
  T.eval("local p = remuda.butler.guard_policy; remuda._t_append = p.append; p.append = function(r) if r.event == 'grant_used' then return nil, 'disk full' end; return remuda._t_append(r) end")
  T.eq(uses(3), 0, "no allow while the audit fails")
  T.eq(T.eval("return #(remuda.butler.guard_grants._uses.g001 or {})"), "0", "nothing kept")
  T.eval("remuda.butler.guard_policy.append = remuda._t_append")
  T.eq(uses(30), 30, "all thirty still there", "ok - release")
end)

T.test("an agent kind that is empty or not claude asks", function()
  fresh_at("r-kind")
  T.eq(uses(1), 1, "control: claude")
  for _, kind in ipairs({ "", "codex", "Claude" }) do
    T.expect(not has(call(("{ kind = %q }"):format(kind)), ALLOW), "kind " .. kind)
  end
  T.eq(count(lines(), '"event":"grant_used"'), 1, "one use", "ok - kind")
end)
