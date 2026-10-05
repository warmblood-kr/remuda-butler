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
local function oc(line, who, event)
  return T.eval(("return tostring(remuda.butler.guard_approval.owner_command(%q, %q, %q))"):format(line, who or "@owner:x", event or "$line"))
end
local function at(offset) T.eval(("remuda.butler.guard_grants.now = function() return %d end"):format(1790000000 + offset)) end
-- Make the audit log unwritable (opening it for append fails) or writable again.
local function audit_mode(mode) T.eval(("remuda.process.run({ argv = { 'chmod', '%s', remuda.butler.guard_policy.log_path() } })"):format(mode)) end
local function logged_errors() return T.eval("return table.concat(remuda._t_logged or {}, '|')") end
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
  T.expect(has(oc("guard unfreeze"), "already open"), "asking again says the request is already open")
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

T.test("a second freeze marks the older open unfreeze request expired", function()
  on("v-expire-open"); reset_holds()
  oc("guard freeze"); oc("guard unfreeze")
  local function statuses() return T.eval("local t = {}; for _, r in pairs(remuda._t_state.approvals) do if r.kind == 'guard_unfreeze' then t[#t + 1] = r.status end end; table.sort(t); return table.concat(t, ',')") end
  T.eq(statuses(), "open", "one open ask")
  oc("guard freeze")
  T.eq(statuses(), "expired", "the older ask expired", "ok - expire_open")
end)

T.test("SHOULD a: every owner line that starts with a guard verb is answered, extra tokens get usage", function()
  on("v-usage"); reset_holds()
  fetch("https://a.test/"); answer(1, "grant")
  T.eq(oc("guard revoke g001 now"), "Usage: guard revoke gNNN (the id from `remuda butler guard grants`).", "revoke + token")
  T.eq(oc("guard revoke"), "Usage: guard revoke gNNN (the id from `remuda butler guard grants`).", "revoke alone")
  T.eq(oc("guard freeze please"), "Usage: guard freeze (no arguments).", "freeze + token")
  T.eq(oc("guard unfreeze now"), "Usage: guard unfreeze (no arguments).", "unfreeze + token")
  T.eq(oc("guard freeze-now"), "Usage: guard freeze (no arguments).", "glued text")
  T.eq(frozen(), "false", "none of them acted")
  T.eq(grants(), 1, "g001 stands", "ok - usage")
end)

T.test("SHOULD b: the audit summary of every owner line names the sender and the event", function()
  on("v-by"); reset_holds()
  fetch("https://a.test/"); answer(1, "grant")
  oc("guard revoke g001 now", "@owner:x", "$ev-usage")
  oc("guard revoke g001", "@owner:x", "$ev-revoke")
  oc("guard freeze", "@owner:x", "$ev-freeze")
  for _, ev in ipairs({ "$ev-usage", "$ev-revoke", "$ev-freeze" }) do
    T.expect(has(lines(), "@owner:x, event " .. ev), ev .. " in the audit: " .. lines())
  end
  T.expect(has(lines(), '"event":"owner_line_refused"'), "usage lines are audited too", "ok - by")
end)

T.test("MUST 1: unfreeze writes its audit line first and stays frozen when it cannot; freeze and revoke log the failure", function()
  on("v-audit"); reset_holds()
  T.eval("remuda._t_logged = {}; remuda.log = function(level, msg) remuda._t_logged[#remuda._t_logged + 1] = level .. ':' .. msg end")
  fetch("https://a.test/"); answer(1, "grant")
  oc("guard freeze"); oc("guard unfreeze")
  local n = tonumber(T.eval("return remuda._t_count()"))
  audit_mode("400")
  answer(n, "approve")
  T.eq(frozen(), "true", "no audit line, no lift")
  T.expect(has(note(), "audit line could not be written") and has(note(), "stay frozen"), "owner told: " .. tostring(note()))
  audit_mode("600")
  -- narrowing still acts with an unwritable audit, and says so in the log
  T.eval("remuda.butler.guard_grants._frozen = false; os.remove(remuda.butler.guard_policy.dir() .. '/guard-grants-frozen')")
  audit_mode("400")
  T.expect(has(oc("guard freeze"), "Grants are frozen"), "freeze acts")
  T.eq(frozen(), "true", "frozen")
  T.expect(has(logged_errors(), "grants_frozen could not be written"), "logged: " .. logged_errors())
  T.eq(oc("guard revoke g001"), "Revoked g001. It stops matching on the next call.", "revoke acts too")
  T.expect(has(logged_errors(), "grant_revoked could not be written"), "logged: " .. logged_errors())
  audit_mode("600")
  T.expect(true, "", "ok - audit first")
end)

T.test("MUST 2: a stale unfreeze post cannot beat a newer freeze", function()
  on("v-stale"); reset_holds()
  fetch("https://a.test/"); answer(1, "grant")
  oc("guard freeze"); oc("guard unfreeze")
  local n = tonumber(T.eval("return remuda._t_count()"))
  T.eq(oc("guard freeze"), "Grants are already frozen.", "a newer freeze while the ask is open")
  answer(n, "approve")
  T.eq(frozen(), "true", "the late check-mark lifts nothing")
  T.eq(grants(), 0, "no grant matches")
  -- a request still posting (not yet in the store) is caught by the freeze generation
  oc("guard unfreeze")
  local m = tonumber(T.eval("return remuda._t_count()"))
  T.eval("local g = remuda.butler.guard_approval; g._freeze_gen = g._freeze_gen + 1")
  answer(m, "approve")
  T.eq(frozen(), "true", "an older generation lifts nothing")
  T.expect(has(note(), "newer freeze"), "owner told: " .. tostring(note()), "ok - stale unfreeze")
end)

T.test("SHOULD e: the unfreeze reply says what the request did", function()
  on("v-reply"); reset_holds()
  oc("guard freeze")
  T.expect(has(oc("guard unfreeze"), "post I just made"), "a new post")
  T.expect(has(oc("guard unfreeze"), "already open"), "the open one")
  T.eval("remuda.butler.approval.expire_open('guard_unfreeze')")
  -- the post fails: the reply says so
  T.eval([[remuda._t_state = { approvals = remuda.json.object({}) }
    remuda.butler.approval.attach(remuda._t_state, function() return true end, function(text, relation, cb)
      if cb then cb({ error = 'boom' }) end
      return {}
    end)]])
  local out = oc("guard unfreeze")
  T.expect(has(out, "Could not ask to lift the freeze") and has(out, "boom") and has(out, "stay frozen"), "failure told: " .. out, "ok - reply")
end)

T.test("SHOULD d: a grant that expires during a freeze is still announced", function()
  on("v-expfreeze"); reset_holds()
  at(0)
  fetch("https://a.test/"); answer(1, "grant")
  local function sweep(offset) at(offset); T.eval("remuda.butler.approval.sweep()") end
  sweep(10)
  oc("guard freeze")
  sweep(20)
  sweep(3601)
  sweep(3670)
  T.expect(has(tostring(post(2)), "Standing grants expired: g001 net a.test"), "notice: " .. tostring(post(2)), "ok - expiry while frozen")
  T.eval("remuda.butler.guard_grants.now = nil")
end)

-- Last: this reloads guard_approval alone, which leaves it without the private handoff (grant_controls nil).
T.test("MUST 3: freeze and revoke work without the private handoff; unfreeze says it is unavailable", function()
  on("v-nohandoff"); reset_holds()
  fetch("https://a.test/"); fetch("https://b.test/")
  answer(1, "grant"); answer(2, "grant")
  T.eval("remuda.exec('butler/guard_approval')")
  T.eq(oc("guard revoke g001"), "Revoked g001. It stops matching on the next call.", "revoke")
  T.eq(grants(), 1, "g002 left")
  T.expect(has(oc("guard freeze"), "Grants are frozen"), "freeze")
  T.eq(frozen(), "true", "marker written")
  T.eq(grants(), 0, "nothing matches")
  T.expect(has(oc("guard unfreeze"), "not available"), "unfreeze stays private", "ok - no handoff")
end)
