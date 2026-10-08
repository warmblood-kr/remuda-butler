-- Guard slice 3, PR4 review round (SEC on #387): audit events counted by name,
-- explicit harness subjects, approval records kept at least as long as the longest grant.
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
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end

T.test("guard stats counts the grant events by name, not as other", function()
  start_butler()
  T.eval("local d = os.getenv('XDG_DATA_HOME') .. '/r-stats'; remuda.mkdir(d); remuda._butler_guard_dir = d")
  T.eval("remuda._butler_command_run('guard', {'guard', 'on'}, {kind='session', session='butler'})")
  for _, e in ipairs({ "approval_limited", "grant_created", "grant_refused", "grant_register_refused" }) do
    T.eval(("remuda.butler.guard_policy.observe(%q, 's', 'claude', 'x')"):format(e))
  end
  local out = T.eval("return remuda._butler_command_run('guard', {'guard', 'stats'}, {})")
  for _, e in ipairs({ "approval_limited", "grant_created", "grant_refused", "grant_register_refused" }) do
    T.expect(has(out, "event " .. e .. ": 1"), e .. " counted by name:\n" .. out)
  end
  T.expect(not has(out, "event other"), "none counted as other:\n" .. out, "ok - stats events")
end)

T.test("approval records are kept at least as long as the longest grant", function()
  start_butler()
  T.eval("remuda.exec('butler/guard_grants')")
  T.eq(T.eval("return tostring(remuda.butler.approval.RETENTION_S >= remuda.butler.guard_grants.MAX_TTL)"), "true",
    "retention covers the 24 h grant TTL")
  local f = assert(io.open(os.getenv("REMUDA_LUA_REPO") .. "/packages/butler/matrix_relay.lua", "r"))
  local source = f:read("a")
  f:close()
  T.expect(has(source, "approval.RETENTION_S") and not has(source, "24 * 60 * 60 * 1000"),
    "the relay prunes by the shared constant, not its own literal", "ok - retention")
end)

-- M.now / M.verified / M.insensitive exist only in the explicitly loaded scratch subject.
-- Production rejection is covered in butler_guard_slice3_testflag_test.lua.
T.test("the grant-store seams work in the explicit harness subject", function()
  start_butler()
  T.eval("remuda.exec('butler/guard_grants')")
  T.eval([[local gg, d = remuda.butler.guard_grants, os.getenv('XDG_DATA_HOME') .. '/r-seam'
    remuda.mkdir(d); remuda._butler_guard_dir = d
    local t = os.time()
    local f = io.open(d .. '/guard-grants.jsonl', 'w')
    f:write(remuda.json.encode({ id = 'g001', class = 'net', scope = 'a.test', ceiling = 'T2', holder = 'h', event = '$e',
      written = t + 990, expires = t + 1100 }), '\n')
    f:close()
    gg.verified = function() return true end
    gg.now = function() return t + 1000 end
    gg.insensitive = function() return true end]])
  T.eq(T.eval("return #remuda.butler.guard_grants.active()"), "1", "with the explicit subject the seams work")
  T.eval("remuda.butler.guard_grants.verified, remuda.butler.guard_grants.now, remuda.butler.guard_grants.insensitive = nil, nil, nil")
  T.expect(true, "", "ok - seams")
end)
