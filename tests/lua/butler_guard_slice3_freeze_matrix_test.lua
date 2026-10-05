-- Guard slice 3, PR5: the owner-only guard verbs (freeze, unfreeze, revoke ID) as the relay hands them to guard_approval.owner_command
-- after its owner gate (tested in tests/butler_matrix_relay.lua). Same relay stand-in as guard_slice3_reactions.
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
local function oc(line, who)
  return T.eval(("return tostring(remuda.butler.guard_approval.owner_command(%q, %s))"):format(line, string.format("%q", who or "@owner:x")))
end
local function frozen() return T.eval("return tostring(remuda.butler.guard_grants.frozen())") end
local function lines() return T.eval("return remuda._t_lines()") end
local function reset_holds() T.eval("local g = remuda.butler.guard_grants; g._revoked, g._frozen = {}, false") end

T.test("revoke ID: one grant stops, repeats and unknown ids answer plainly, audited with grant_id", function()
  on("v-revoke"); reset_holds()
  fetch("https://a.test/"); fetch("https://b.test/")
  T.eq(answer(1, "grant"), "true nil", "g001"); T.eq(answer(2, "grant"), "true nil", "g002")
  T.eq(grants(), 2, "two grants")
  T.eq(oc("guard revoke g001"), "Revoked g001. It stops matching on the next call.", "revoked")
  T.eq(grants(), 1, "one left")
  T.eq(oc("guard revoke g001"), "g001 is already revoked.", "again")
  T.eq(oc("guard revoke g009"), "No grant g009.", "unknown")
  T.eq(oc("guard revoke g1"), "Usage: guard revoke gNNN (the id from `remuda butler guard grants`).", "malformed id")
  T.expect(has(lines(), '"event":"grant_revoked"') and has(lines(), '"grant_id":"g001"'), "audit: " .. lines())
  T.eq(T.eval("return tostring(remuda.butler.guard_approval.owner_command('guard grants', '@owner:x'))"), "nil", "other lines are not ours")
  T.eq(oc("hello"), "nil", "ordinary text is not ours")
  T.expect(true, "", "ok - revoke")
end)

T.test("freeze: no grant matches, none is offered or made, the reaction is refused with a reason", function()
  on("v-freeze"); reset_holds()
  fetch("https://a.test/")
  T.eq(answer(1, "grant"), "true nil", "g001 before the freeze")
  T.eq(oc("guard freeze"), "Grants are frozen: none matches and none is made until you lift it (guard unfreeze, then react on the post).", "frozen")
  T.eq(frozen(), "true", "state")
  T.eq(grants(), 0, "nothing matches")
  T.eq(oc("guard freeze"), "Grants are already frozen.", "again")
  local n = fetch("https://b.test/")
  T.expect(not has(post(2), "🔄") and not has(post(2), "grant:"), "no grant offered while frozen: " .. post(2))
  T.eq(answer(2, "grant"), "nil Standing grants are frozen.", "so the cycle reaction makes nothing")
  T.eq(answer(2, "approve"), "true nil", "a check still allows this one call")
  T.eq(reply_out(n), "done:" .. ALLOW, "allowed once")
  T.expect(has(lines(), '"event":"grants_frozen"'), "audit: " .. lines())
  T.expect(true, "", "ok - freeze")
end)

T.test("a post made before the freeze cannot make a grant while frozen", function()
  on("v-prefreeze"); reset_holds()
  local n = fetch("https://a.test/")
  oc("guard freeze")
  T.eq(answer(1, "grant"), "nil Standing grants are frozen.", "refused, request stays open")
  T.eq(reply_out(n), "waiting", "still waiting")
  T.eq(grants(), 0, "no grant", "ok - prefreeze")
end)

T.test("unfreeze needs the owner's answer on a Butler post; the terminal and a plain command cannot lift it", function()
  on("v-unfreeze"); reset_holds()
  T.eq(oc("guard unfreeze"), "Grants are not frozen.", "nothing to lift")
  fetch("https://a.test/")
  T.eq(answer(1, "grant"), "true nil", "g001")
  oc("guard freeze")
  local before = tonumber(T.eval("return remuda._t_count()"))
  T.eq(oc("guard unfreeze"), "To lift the freeze, react ✅ on the post I just made (or reply yes).", "asks")
  T.eq(tonumber(T.eval("return remuda._t_count()")), before + 1, "one approval post")
  T.eq(oc("guard unfreeze"), "To lift the freeze, react ✅ on the post I just made (or reply yes).", "asking again")
  T.eq(tonumber(T.eval("return remuda._t_count()")), before + 1, "reuses the open post")
  T.eq(frozen(), "true", "still frozen: asking lifts nothing")
  local n = before + 1
  T.eq(answer(n, "approve", "operator (terminal)"), "nil Lifting the freeze can only be approved by the owner in its live Matrix thread.", "terminal")
  T.eq(frozen(), "true", "still frozen")
  T.eq(answer(n, "deny"), "true nil", "owner crosses it")
  T.eq(frozen(), "true", "a cross keeps it frozen")
  oc("guard unfreeze")
  T.eq(answer(n + 1, "approve"), "true nil", "owner approves")
  T.eq(frozen(), "false", "lifted")
  T.eq(grants(), 1, "the grant matches again")
  T.expect(has(note(), "Freeze lifted"), "thread note: " .. tostring(note()))
  T.expect(has(lines(), '"event":"grants_unfrozen"'), "audit: " .. lines())
  T.expect(true, "", "ok - unfreeze")
end)

T.test("unfreeze post expiry leaves the freeze", function()
  on("v-unfreeze-exp"); reset_holds()
  oc("guard freeze"); oc("guard unfreeze")
  T.eval("for _, rec in pairs(remuda._t_state.approvals) do rec.expires_at = 0 end; remuda.butler.approval.sweep()")
  T.eq(frozen(), "true", "expired: still frozen")
  T.expect(has(note(), "stay frozen"), "owner told: " .. tostring(note()), "ok - expiry")
end)
