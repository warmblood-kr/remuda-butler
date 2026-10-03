-- #332: codex per-member sandbox profile (--writable, --sandbox full).
local function ev(code)
  -- "ok:<value>" or "err:<message>", so a refusal is data, not a harness failure.
  return T.eval("local ok, v = pcall(function() " .. code .. " end); return (ok and 'ok:' or 'err:') .. tostring(v)")
end
local function start_butler()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 5, "Butler root start")
  T.eval("remuda._butler_codex_config_supported = true")
end
local function has(list_text, item) return list_text:find(item, 1, true) ~= nil end

T.test("codex builder emits the -c pairs only for a profile", function()
  start_butler()
  local dir = T.eval("local d = os.getenv('XDG_DATA_HOME') .. '/sbx-ok'; remuda.mkdir(d); return d")
  local build = "return table.concat(remuda._butler_agent_builders.codex(%s), '\\n')"
  local plain = T.eval(build:format("{ name='m', telemetry={status_path='/s'} }"))
  T.expect(not has(plain, "writable_roots") and not has(plain, "danger-full-access"),
    "plain launch carried sandbox flags", "ok - no profile, no sandbox -c pairs")
  local scoped = T.eval(build:format("{ name='m', telemetry={status_path='/s'}, writable={'" .. dir .. "'} }"))
  T.expect(has(scoped, 'sandbox_workspace_write.writable_roots=["' .. dir .. '"]'), "writable_roots missing: " .. scoped,
    "ok - writable roots become a TOML array -c pair")
  T.expect(not has(scoped, "danger-full-access"), "writable alone widened to full access")
  local full = T.eval(build:format("{ name='m', telemetry={status_path='/s'}, sandbox='full' }"))
  T.expect(has(full, 'sandbox_mode="danger-full-access"'), "full access pair missing: " .. full,
    "ok - sandbox=full adds danger-full-access")
  T.eval("remuda._butler_codex_config_supported = false")
  local refused = ev(build:format("{ name='m', telemetry={status_path='/s'}, sandbox='full' }"))
  T.expect(refused:find("^err:") and refused:find("Next:", 1, true), "unsupported core did not refuse: " .. refused,
    "ok - a core without -c forwarding refuses a profile")
  T.eval("remuda._butler_codex_config_supported = true")
end)

T.test("profile validation refuses claude, relative and missing dirs", function()
  start_butler()
  local r = ev("return remuda._butler_profile('claude', nil, {'/tmp'})")
  T.expect(r:find("^err:") and r:find("Codex members only", 1, true), "claude not refused: " .. r, "ok - claude refuses --writable")
  r = ev("return remuda._butler_profile('codex', nil, {'rel/dir'})")
  T.expect(r:find("^err:") and r:find("absolute", 1, true) and r:find("Next:", 1, true), "relative accepted: " .. r,
    "ok - relative dir refused with a Next: line")
  r = ev("return remuda._butler_profile('codex', nil, {'/no/such/dir-332'})")
  T.expect(r:find("^err:") and r:find("does not exist", 1, true) and r:find("Next:", 1, true), "missing accepted: " .. r,
    "ok - missing dir refused with a Next: line")
  r = ev("return remuda._butler_profile('codex', 'half', nil)")
  T.expect(r:find("^err:"), "unknown sandbox value accepted", "ok - only `full` is a sandbox value")
end)

T.test("sandbox full is refused for agent callers with the owner command", function()
  start_butler()
  local agent = "{ env = { REMUDA_BUTLER_AGENT_ID = 'AGENT' } }"
  local r = ev("return remuda._butler_command_run('launch', {'launch','codex','w1','--sandbox','full'}, " .. agent .. ")")
  T.expect(r:find("remuda butler launch codex w1 --sandbox full", 1, true) and r:find("Next:", 1, true),
    "agent CLI call not refused with the owner command: " .. r, "ok - CLI agent caller gets the owner command")
  r = ev("return remuda._butler_command_run('topic', {'topic','delegate','t1','--agent','codex','--sandbox','full','do it'}, " .. agent .. ")")
  T.expect(r:find("remuda butler topic delegate t1 --agent codex --sandbox full", 1, true),
    "delegate not refused with the owner command: " .. r, "ok - delegate agent caller gets the owner command")
  -- Library entry points (run_script) are refused when the core says the caller is a session.
  T.eval("remuda.caller = function() return { kind = 'session', session = 'x' } end")
  r = ev("return remuda._butler_launch('codex', 'w2', nil, 'butler', { sandbox = 'full' })")
  T.expect(r:find("^err:") and r:find("remuda butler launch codex w2 --sandbox full", 1, true),
    "library caller not refused: " .. r, "ok - session caller of _butler_launch is refused")
  T.eval("remuda.caller = nil")
end)

T.test("profile is recorded, shown, and re-applied on relaunch", function()
  start_butler()
  local dir = T.eval("local d = os.getenv('XDG_DATA_HOME') .. '/sbx-keep'; remuda.mkdir(d); return d")
  T.eval([[remuda._butler_agent_builders.codex = function(spec)
    -- The launcher first offers the host table; a builder rejects it, as the real one does.
    assert(type(spec) == "table" and spec.telemetry, "spec expected")
    remuda._test_specs = remuda._test_specs or {}
    remuda._test_specs[#remuda._test_specs + 1] = spec
    return { "sh", "-c", "sleep 60" }
  end]])
  T.eval("return remuda._butler_launch('codex', 'wr', nil, 'butler', remuda._butler_profile('codex', nil, {'" .. dir .. "'}))")
  T.wait_until(function() return T.eval("return tostring(remuda._butler_bus.agents.wr ~= nil)") == "true" end, 8, "wr row")
  T.eq(T.eval("local a = remuda._butler_bus.agents.wr; return tostring(a.writable and a.writable[1])"), dir, "row lost the writable root")
  T.eq(T.eval("local w = remuda._test_specs[1].writable; return tostring(w and w[1])"), dir, "builder spec lacks the writable root")
  local sessions = T.eval("return remuda._butler_sessions()")
  T.expect(sessions:find("wr: writable=1", 1, true), "sessions lacks the profile: " .. sessions,
    "ok - butler sessions shows writable=N")
  T.expect(T.eval("return remuda.session_detail({ name = 'wr' })"):find("writable=1", 1, true),
    "session detail lacks the profile")
  local welcome = T.eval("return remuda._butler_inbox(remuda._butler_bus.agents.wr.id)")
  T.expect(welcome:find(dir, 1, true), "welcome mail does not list the roots: " .. welcome,
    "ok - member mail lists the writable roots")
  -- The exit of a member with an update-relaunch record relaunches it with that record's profile.
  T.eval([[local row = remuda._butler_bus.agents.wr
    remuda._butler_bus.codex_update_relaunches.wr = { kind = "codex", name = "wr", cwd = row.cwd, parent = "butler",
      identity = row.id, expected_close = true, profile = remuda._butler_sandbox.of(row) }
    return remuda.close("wr")]])
  T.wait_until(function() return T.eval("return tostring(#remuda._test_specs)") == "2" end, 10, "relaunch spec")
  T.eq(T.eval("return remuda._test_specs[2].writable[1]"), dir, "relaunch dropped the profile")
end)
