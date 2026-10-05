-- Guard slice 3, PR2: grant_id on every audit line, switch-change events, retention, `guard stats`.
local function start_butler()
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
    remuda._t_hook = function(stdin)
      return remuda._butler_command_run('guard', {'guard'}, { stdin = stdin, env =
        { REMUDA_BUTLER_AGENT_ALIAS = 'ss-a', REMUDA_BUTLER_AGENT_KIND = 'claude' } })
    end
    remuda._t_lines = function()
      local out, f = {}, io.open(gp.log_path(), 'r')
      if not f then return '' end
      for l in f:lines() do out[#out + 1] = l end
      f:close(); return table.concat(out, '\n')
    end
    remuda._t_guard = function(args, caller) return remuda._butler_command_run('guard', args, caller or {}) end
    return 'ok'
  ]])
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end
local LS = [[{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}]]
local PUSH = [[{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push --force origin main"},"cwd":"/p"}]]

T.test("every audit line carries grant_id, '-' until grants exist", function()
  start_butler()
  T.eval("remuda._t_dir('g3-grant'); remuda._t_guard({'guard','on'})")
  T.eval(("remuda._t_hook(%q)"):format(LS))
  T.eval("remuda.butler.guard_policy.observe('codex_prompt', 'ss-c', 'codex', 'Allow?')")
  local lines = T.eval("return remuda._t_lines()")
  local n = 0
  for line in lines:gmatch("[^\n]+") do
    n = n + 1
    T.expect(has(line, '"grant_id":"-"'), "line without grant_id: " .. line)
  end
  T.expect(n >= 3, "expected switch, hook and observe lines, got " .. n, "ok - grant_id on every line")
end)

T.test("switch changes are audited with who and when, even when turned off", function()
  start_butler()
  T.eval("remuda._t_dir('g3-switch'); remuda._t_guard({'guard','on'}, {env={REMUDA_BUTLER_AGENT_ALIAS='lead-1'}})")
  T.eval("remuda._t_guard({'guard','deny','on'}, {env={REMUDA_BUTLER_AGENT_ALIAS='lead-1'}})")
  T.eval("remuda._t_guard({'guard','deny','off'}, {})")
  T.eval("remuda._t_guard({'guard','approvals','on'}, {})")
  T.eval("remuda._t_guard({'guard','off'}, {})")
  local lines = T.eval("return remuda._t_lines()")
  local want = { { "guard on", "lead-1" }, { "guard deny on", "lead-1" }, { "guard deny off", "operator" },
    { "guard approvals on", "operator" }, { "guard off", "operator" } }
  local i = 0
  for line in lines:gmatch("[^\n]+") do
    if not has(line, '"event":"chain"') then -- the genesis line is not a switch
      i = i + 1
      local w = want[i]
      T.expect(w and has(line, '"event":"switch"') and has(line, '"summary":"' .. w[1] .. '"')
        and has(line, '"session":"' .. w[2] .. '"') and has(line, '"time":"'), "switch line " .. i .. ": " .. line)
    end
  end
  T.expect(i == #want, "expected " .. #want .. " switch lines, got " .. i, "ok - switch events")
  -- A status read changes nothing and records nothing.
  T.eval("remuda._t_guard({'guard','status'}, {})")
  T.eq(T.eval("return select(2, remuda._t_lines():gsub('\\n', '')) + 1"), tostring(#want + 1), "status records nothing")
end)

T.test("retention: size rotation keeps dated archives, prunes only past the documented period", function()
  start_butler()
  T.eval("remuda._t_dir('g3-ret'); remuda._t_guard({'guard','on'})")
  local out = T.eval([[
    local gp = remuda.butler.guard_policy
    local base = gp.log_path()
    local function stamp(days_ago) return os.date('!%Y%m%dT%H%M%SZ', os.time() - days_ago * 86400) end
    local old, young = base .. '.' .. stamp(gp.RETENTION_DAYS + 1), base .. '.' .. stamp(gp.RETENTION_DAYS - 1)
    for _, p in ipairs({ old, young, base .. '.1' }) do local f = io.open(p, 'w'); f:write('x\n'); f:close() end
    local f = io.open(base, 'w'); f:write(string.rep('x', 1024 * 1024 + 1)); f:close()
    remuda._t_hook(']] .. LS .. [[')
    local function exists(p) local h = io.open(p, 'r'); if h then h:close() end; return h ~= nil end
    local dated = 0
    for _, name in ipairs(remuda.list_dir(remuda._butler_guard_dir)) do
      if name:match('^guard%-audit%.jsonl%.%d+T%d+Z$') then dated = dated + 1 end
    end
    return table.concat({ tostring(gp.RETENTION_DAYS), tostring(exists(old)), tostring(exists(young)),
      tostring(exists(base .. '.1')), tostring(dated) }, ' ')
  ]])
  local days, old, young, one, dated = out:match("(%d+) (%a+) (%a+) (%a+) (%d+)")
  T.expect(days == "90", "RETENTION_DAYS is the documented 90: " .. out)
  T.expect(old == "false", "an archive past retention must be pruned: " .. out)
  T.expect(young == "true" and one == "true", "archives inside retention must stay: " .. out)
  T.expect(dated == "2", "the previous .1 moves to a dated name instead of being deleted: " .. out, "ok - retention")
end)

T.test("guard stats counts decision classes over the log and its archives", function()
  start_butler()
  T.eval("remuda._t_dir('g3-stats')")
  T.expect(has(T.eval("return remuda._t_guard({'guard','stats'})"), "Next:"), "empty stats should point at a next step")
  T.eval("remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','deny','on'})")
  T.eval(("remuda._t_hook(%q); remuda._t_hook(%q); remuda._t_hook(%q)"):format(LS, PUSH, PUSH))
  -- one older line in a dated archive counts too
  T.eval([[local gp = remuda.butler.guard_policy
    local f = io.open(gp.log_path() .. '.20200101T000000Z', 'w')
    f:write('{"time":"2020-01-01T00:00:00Z","session":"s","kind":"claude","event":"PreToolUse","tool":"Bash","class":"push","summary":"x"}\n')
    f:close()]])
  local out = T.eval("return remuda._t_guard({'guard','stats'})")
  for _, f in ipairs({ "lines: 7", "class push: 3", "class other: 4", "event chain: 1", "event deny: 2", "event PreToolUse: 2",
    "event switch: 2", "since 2020-01-01T00:00:00Z" }) do
    T.expect(has(out, f), "stats missing '" .. f .. "':\n" .. out)
  end
  T.expect(true, "", "ok - guard stats")
end)

T.test("rotation never overwrites an archive made in the same second", function()
  start_butler()
  T.eval("remuda._t_dir('g3-collide')")
  local out = T.eval([[
    local gp = remuda.butler.guard_policy
    local base, now = gp.log_path(), os.time()
    local name = base .. '.' .. os.date('!%Y%m%dT%H%M%SZ', now)
    local function put(p, s) local f = io.open(p, 'w'); f:write(s); f:close() end
    local function get(p) local f = io.open(p, 'r'); local s = f and f:read('a'); if f then f:close() end; return s end
    put(name, 'OLD'); put(base .. '.1', 'NEW'); put(base, 'CUR')
    gp.rotate(base, now)
    return table.concat({ tostring(get(name)), tostring(get(name .. '-1')), tostring(get(base .. '.1')) }, ' ')
  ]])
  T.expect(out == "OLD NEW CUR", "same-second rotation lost or misplaced an archive: " .. out, "ok - rotate collision")
end)

T.test("guard stats survives a tampered log: bucketed names, capped lines, unreadable files", function()
  start_butler()
  T.eval("remuda._t_dir('g3-hostile')")
  local out = T.eval([[
    local gp = remuda.butler.guard_policy
    local base = gp.log_path()
    assert(remuda.mkdir(base .. '.1') ~= false)
    local f = io.open(base, 'w')
    f:write('{"time":"2026-01-01T00:00:00Z","class":"evil\\u001b[31mred","event":"x\\nfoo","summary":""}\n')
    f:write('{"time":"\\u001b[2Jbad","class":"push","event":"switch"}\n')
    f:write(string.rep('a', 300000) .. '\n')
    f:write('{"time":"2026-01-02T00:00:00Z","class":"push","event":"deny"}\n')
    f:write(string.rep('b', 300000)) -- no trailing newline
    f:close()
    return remuda._t_guard({'guard','stats'})
  ]])
  T.expect(not out:find("[\1-\9\11-\31]"), "control bytes reached the terminal: " .. out)
  for _, want in ipairs({ "class other: 1", "class push: 2", "event other: 1", "event deny: 1", "event switch: 1",
    "unreadable" }) do
    T.expect(has(out, want), "stats missing '" .. want .. "':\n" .. out)
  end
  T.expect(not has(out, "evil") and not has(out, "bad"), "raw tampered text echoed: " .. out)
  T.expect(has(out, "since 2026-01-01T00:00:00Z until 2026-01-02T00:00:00Z"), "time range wrong: " .. out, "ok - hostile stats")
end)

T.test("turning a switch off is audited first; an unwritable audit still switches off, loudly, with a sticky marker", function()
  start_butler()
  T.eval("remuda._t_dir('g3-offfirst'); remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','deny','on'})")
  -- a read-only log: opening it for append fails on every platform (a directory would not on Linux)
  T.eval([[local gp = remuda.butler.guard_policy
    remuda.process.run({ argv = { 'chmod', '400', gp.log_path() } })]])
  local off = T.eval([[local err, real = {}, io.stderr
    io.stderr = { write = function(_, t) err[#err + 1] = t end }
    local ok, r = pcall(remuda._t_guard, {'guard','off'})
    io.stderr = real
    return tostring(r) .. '\nSTDERR:' .. table.concat(err)]])
  local answer, stderr = off:match("^(.-)\nSTDERR:(.*)$")
  T.expect(has(answer, "switched off, NOT audited:") and has(stderr, "NOT audited"), "loud answer and stderr: " .. off)
  local status = T.eval("return remuda._t_guard({'guard','status'})")
  T.expect(has(status, "guard: off") and has(status, "NOT audited"), "status must show off and the marker: " .. status)
  T.expect(has(T.eval("return remuda._t_guard({'guard','stats'})"), "NOT audited"), "stats must show the marker")
  T.eval([[local gp = remuda.butler.guard_policy
    remuda.process.run({ argv = { 'chmod', '600', gp.log_path() } })]])
  T.eval("remuda._t_guard({'guard','on'}, {env={REMUDA_BUTLER_AGENT_ALIAS='lead-1'}})")
  status = T.eval("return remuda._t_guard({'guard','status'})")
  T.expect(has(status, "guard: on") and not has(status, "NOT audited"), "a good audit line clears the marker: " .. status)
  T.eval("remuda._t_guard({'guard','off'}, {env={REMUDA_BUTLER_AGENT_ALIAS='lead-1'}})")
  local lines = T.eval("return remuda._t_lines()")
  local last; for l in lines:gmatch("[^\n]+") do last = l end
  T.expect(has(last, '"summary":"guard off"') and has(last, '"session":"lead-1"')
    and has(T.eval("return remuda._t_guard({'guard','status'})"), "guard: off"), "off line missing: " .. last, "ok - off audited first")
end)

T.test("an off line followed by a failed switch write is followed by 'off failed', so the log does not claim off", function()
  start_butler()
  T.eval("remuda._t_dir('g3-offfail')")
  -- a directory where the switch file belongs makes the atomic write fail
  T.eval("remuda.mkdir(remuda._butler_guard_dir .. '/guard-observe')")
  local answer = T.eval("local ok, r = pcall(remuda._t_guard, {'guard','off'}); return tostring(ok) .. tostring(r)")
  T.expect(has(answer, "guard switch not changed"), "the failed write is reported: " .. answer)
  local lines = T.eval("return remuda._t_lines()")
  local last; for l in lines:gmatch("[^\n]+") do last = l end
  T.expect(has(last, '"summary":"guard off failed: '), "last line must say the off failed: " .. tostring(last), "ok - off failed line")
end)

T.test("guard stats reads a 1 MiB file of newlines in linear time", function()
  start_butler()
  T.eval("remuda._t_dir('g3-newlines')")
  local out = T.eval([[
    local gp = remuda.butler.guard_policy
    local f = io.open(gp.log_path(), 'w'); f:write(string.rep('\n', 1024 * 1024)); f:close()
    local t0 = os.clock()
    local answer = remuda._t_guard({'guard','stats'})
    return string.format('%.2f', os.clock() - t0) .. ' ' .. answer
  ]])
  T.expect(tonumber(out:match("^(%S+)")) < 2, "stats over 1 MiB of newlines was too slow: " .. out, "ok - stats linear")
end)

T.test("a failed rotate rename never truncates the live log", function()
  start_butler()
  T.eval("remuda._t_dir('g3-rotfail')")
  local out = T.eval([[
    local gp = remuda.butler.guard_policy
    local base = gp.log_path()
    local f = io.open(base, 'w'); f:write(string.rep('x', 1024 * 1024 + 1)); f:close()
    local real = os.rename
    os.rename = function() return nil, 'boom' end
    local ok, why = gp.append({ session = 's', event = 'switch', summary = 'after failed rotate' })
    os.rename = real
    local h = io.open(base, 'r'); local size = h:seek('end'); h:close()
    return tostring(ok) .. ' ' .. size
  ]])
  local ok, size = out:match("^(%a+) (%d+)$")
  T.expect(ok == "true" and tonumber(size) > 1024 * 1024, "the live log must keep its content when rotate fails: " .. out, "ok - rotate failure keeps log")
end)
