-- Guard slice 3, PR-B (#339): the hook's own refusals before a grant may allow: switches, deny rules, the class gate, errors.
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
      local agent = remuda._butler_bus.agents['t-ssa']
      agent.kind = over.kind or 'claude'
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
-- grants.match answers g001 for anything, so only the hook's own checks stand between a call and allow.
local function any_match() T.eval("local g = remuda.butler.guard_grants; remuda._t_match = remuda._t_match or g.match; g.match = function() return 'g001' end") end
local function real_match() T.eval("if remuda._t_match then remuda.butler.guard_grants.match = remuda._t_match end") end
local function asks(over, why)
  local reply = call(over)
  T.expect(not has(reply, ALLOW), why .. ": " .. reply)
end

T.test("only a push (Bash/PowerShell) or a WebFetch can use a grant: every other class asks", function()
  fresh("e-gate")
  any_match()
  T.expect(has(call(), ALLOW), "control: WebFetch")
  T.expect(has(call("{ tool = 'Bash', input = { command = 'git push' } }"), ALLOW), "control: push")
  local rows = { { "git push; remuda butler guard off", "weaken" }, { "git push; kill 1", "control" },
    { "git push; remuda butler matrix join x", "identity" }, { "rm -rf build", "destroy" },
    { "cp x ~/.ssh/config", "escape" }, { "remuda lua x.lua", "script" }, { "curl https://example.com", "net" },
    { "ls", "other" } }
  for _, row in ipairs(rows) do
    T.eq(T.eval(("return remuda.butler.guard_policy.classify('Bash', { command = %q }, {})"):format(row[1])), row[2], "class of " .. row[1])
    asks(("{ tool = 'Bash', input = { command = %q } }"):format(row[1]), row[2])
  end
  asks("{ tool = 'WebSearch', input = { query = 'x' } }", "WebSearch")
  asks("{ tool = 'Write', input = { file_path = '/tmp/x' } }", "Write")
  real_match()
  T.eq(count(lines(), '"event":"grant_used"'), 2, "only the two controls were used", "ok - class gate")
end)

T.test("a deny rule hit at PermissionRequest gets no grant, deny switch on or off", function()
  fresh("e-deny")
  any_match()
  asks("{ tool = 'Bash', input = { command = 'git push --force origin main' } }", "protected force push")
  T.eval("local p = remuda.butler.guard_policy; remuda._t_deny = p.deny_reason; p.deny_reason = function() return 'test rule' end")
  asks("{}", "a WebFetch a deny rule names")
  T.eval("remuda.butler.guard_policy.deny_reason = remuda._t_deny")
  real_match()
  T.expect(has(call(), ALLOW), "control after", "ok - deny")
end)

T.test("switches: guard, approvals, grants off, or a codex session: no allow, and grants off reads no store", function()
  fresh("e-switch")
  asks("{ kind = 'codex' }", "codex")
  T.eval("remuda._t_guard({'guard','approvals','off'})")
  asks("{}", "approvals off")
  T.eval("remuda._t_guard({'guard','approvals','on'}); remuda._t_guard({'guard','grants','off'})")
  T.eval([[remuda._t_opened = {}
    local real = io.open; remuda._t_io_open = real
    io.open = function(p, ...) if tostring(p):find('guard-grants', 1, true) then remuda._t_opened[#remuda._t_opened + 1] = p end; return real(p, ...) end]])
  asks("{}", "grants off")
  local opened = T.eval("io.open = remuda._t_io_open; local n = 0; for _, p in ipairs(remuda._t_opened) do if p:find('guard-grants.jsonl', 1, true) then n = n + 1 end end; return n")
  T.eq(opened, "0", "the store is not opened")
  T.eval("remuda._t_guard({'guard','grants','on'}); remuda._t_guard({'guard','off'})")
  asks("{}", "guard off")
  T.eval("remuda._t_guard({'guard','on'})")
  T.expect(has(call(), ALLOW), "control: all on", "ok - switches")
end)

T.test("an error in match, or an unwritable audit line, asks and counts nothing", function()
  fresh("e-error")
  T.eval("local g = remuda.butler.guard_grants; remuda._t_match = g.match; g.match = function() error('boom') end")
  asks("{}", "match error")
  real_match()
  T.eval("local p = remuda.butler.guard_policy; remuda._t_append = p.append; p.append = function(r) if r.event == 'grant_used' then return nil, 'disk full' end; return remuda._t_append(r) end")
  asks("{}", "audit failed")
  T.eq(T.eval("return #(remuda.butler.guard_grants._uses.g001 or {})"), "0", "no use counted")
  T.eval("remuda.butler.guard_policy.append = remuda._t_append")
  T.expect(has(call(), ALLOW), "control after", "ok - errors")
end)
