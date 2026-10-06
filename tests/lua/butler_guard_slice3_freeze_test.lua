-- Guard slice 3, PR5: revoke one grant and freeze all grants (the store half; the owner-only Matrix verbs are in
-- tests/butler_matrix_relay.lua and guard_slice3_freeze_matrix).
local started
local function start_butler()
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
    remuda._t_guard = function(args, caller) return remuda._butler_command_run('guard', args, caller or {}) end
    -- A fresh load of the store hands add and the owner controls to the test; the cross-check is not under test here.
    remuda._t_load = function()
      remuda.exec('butler/guard_grants')
      local g = remuda.butler.guard_grants
      g.verified = function() return true end
      g.register(function(add, control) remuda._t_add, remuda._t_ctl = add, control end)
    end
    remuda._t_fresh = function(name)
      local d = os.getenv('XDG_DATA_HOME') .. '/' .. name
      remuda.mkdir(d); remuda._butler_guard_dir = d
      remuda._t_load()
      remuda.butler.guard_grants.now = nil
      remuda.butler.guard_grants._revoked, remuda.butler.guard_grants._frozen = {}, false -- memory holds of an earlier test
      remuda._t_guard({ 'guard', 'on' }); remuda._t_guard({ 'guard', 'grants', 'on' })
    end
    remuda._t_net = function(host) return remuda._t_add({ class = 'net', scope = host, ceiling = 'T2', holder = 'ss-a', event = '$e', ttl = 3600 }) end
    remuda._t_covers = function(url) return tostring(remuda.butler.guard_grants.match('WebFetch', { url = url }, '/')) end
    return 'ok'
  ]])
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end
local function eval(code) return T.eval(code) end

T.test("revoke ID ends that grant at the next hook call, persists, and answers plainly", function()
  start_butler()
  eval("remuda._t_fresh('f-revoke')")
  eval("remuda._t_net('a.test'); remuda._t_net('b.test')")
  T.eq(eval("return remuda._t_covers('https://a.test/')"), "g001", "control: covered")
  T.eq(eval("local r, why = remuda._t_ctl.revoke('g001'); return tostring(r) .. ' ' .. tostring(why)"), "revoked nil", "revoked")
  T.eq(eval("return remuda._t_covers('https://a.test/')"), "nil", "g001 no longer matches")
  T.eq(eval("return remuda._t_covers('https://b.test/')"), "g002", "g002 is untouched")
  T.eq(eval("return (remuda._t_ctl.revoke('g001'))"), "already", "again: already revoked")
  T.eq(eval("return (remuda._t_ctl.revoke('g099'))"), "unknown", "unknown id")
  T.eq(eval("return (remuda._t_ctl.revoke('nonsense'))"), "unknown", "not an id")
  eval("remuda._t_load()") -- a restart reloads the store from the file
  T.eq(eval("return remuda._t_covers('https://a.test/')"), "nil", "still revoked after a reload")
  local out = eval("return remuda._t_guard({'guard','grants'})")
  T.expect(has(out, "g002  net  b.test") and has(out, "g001  revoked  net a.test"), "operator view: " .. out)
  eval("remuda.butler.guard_grants.now = function() return os.time() + 7200 end")
  T.eq(eval("return (remuda._t_ctl.revoke('g002'))"), "expired", "an expired grant answers expired", "ok - revoke")
end)

T.test("a revoke that cannot be saved still takes effect now and is reported (fail closed)", function()
  start_butler()
  eval("remuda._t_fresh('f-revoke-fail')")
  eval("remuda._t_net('a.test')")
  eval("local w = remuda.fs.write_atomic; remuda._t_w = w; remuda.fs.write_atomic = function() return nil, 'disk full' end")
  local out = eval("local r, why = remuda._t_ctl.revoke('g001'); return tostring(r) .. ' ' .. tostring(why)")
  eval("remuda.fs.write_atomic = remuda._t_w")
  T.eq(out, "nil disk full", "the failure is reported")
  T.eq(eval("return remuda._t_covers('https://a.test/')"), "nil", "the grant is already off", "ok - revoke fails closed")
end)

T.test("freeze stops every grant and any new grant until lifted, and survives a reload", function()
  start_butler()
  eval("remuda._t_fresh('f-freeze')")
  eval("remuda._t_net('a.test')")
  T.eq(eval("return tostring(remuda.butler.guard_grants.frozen())"), "false", "not frozen")
  T.eq(eval("return (remuda._t_ctl.freeze())"), "frozen", "freeze")
  T.eq(eval("return (remuda._t_ctl.freeze())"), "already", "freeze again")
  T.eq(eval("return remuda._t_covers('https://a.test/')"), "nil", "no grant matches")
  T.eq(eval("local id, why = remuda._t_net('c.test'); return tostring(id) .. ' ' .. tostring(why)"), "nil grants are frozen", "no new grant")
  local out = eval("return remuda._t_guard({'guard','grants'})")
  T.expect(has(out, "frozen") and has(out, "g001"), "operator view says frozen: " .. out)
  eval("remuda._t_load()")
  T.eq(eval("return tostring(remuda.butler.guard_grants.frozen())"), "true", "still frozen after a reload")
  T.eq(eval("return remuda._t_covers('https://a.test/')"), "nil", "and nothing matches")
  T.eq(eval("return (remuda._t_ctl.unfreeze())"), "lifted", "lifted")
  T.eq(eval("return (remuda._t_ctl.unfreeze())"), "not frozen", "lifting twice")
  T.eq(eval("return remuda._t_covers('https://a.test/')"), "g001", "the grant matches again", "ok - freeze")
end)

T.test("a freeze that cannot be saved still holds in memory (fail closed)", function()
  start_butler()
  eval("remuda._t_fresh('f-freeze-fail')")
  eval("remuda._t_net('a.test')")
  eval("local w = remuda.fs.write_atomic; remuda._t_w = w; remuda.fs.write_atomic = function() return nil, 'disk full' end")
  local out = eval("local r, why = remuda._t_ctl.freeze(); return tostring(r) .. ' ' .. tostring(why)")
  eval("remuda.fs.write_atomic = remuda._t_w")
  T.eq(out, "nil disk full", "the failure is reported")
  T.eq(eval("return remuda._t_covers('https://a.test/')"), "nil", "grants are held")
  T.eq(eval("return (remuda._t_ctl.unfreeze())"), "lifted", "unfreeze clears the memory hold", "ok - freeze fails closed")
end)

T.test("the CLI has no freeze, unfreeze or revoke verb", function()
  start_butler()
  eval("remuda._t_fresh('f-cli')")
  for _, args in ipairs({ "{'guard','freeze'}", "{'guard','unfreeze'}", "{'guard','revoke','g001'}" }) do
    local out = eval(("local ok, r = pcall(remuda._t_guard, %s); return tostring(r)"):format(args))
    T.expect(has(out, "Usage: remuda butler guard"), args .. " is not a verb: " .. out)
  end
  T.eq(eval("return tostring(remuda.butler.guard_grants.frozen())"), "false", "nothing froze", "ok - no CLI verbs")
end)
