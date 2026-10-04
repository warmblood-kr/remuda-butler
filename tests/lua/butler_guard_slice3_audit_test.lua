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
    i = i + 1
    local w = want[i]
    T.expect(w and has(line, '"event":"switch"') and has(line, '"summary":"' .. w[1] .. '"')
      and has(line, '"session":"' .. w[2] .. '"') and has(line, '"time":"'), "switch line " .. i .. ": " .. line)
  end
  T.expect(i == #want, "expected " .. #want .. " switch lines, got " .. i, "ok - switch events")
  -- A status read changes nothing and records nothing.
  T.eval("remuda._t_guard({'guard','status'}, {})")
  T.eq(T.eval("return select(2, remuda._t_lines():gsub('\\n', '')) + 1"), tostring(#want), "status records nothing")
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
  T.expect(tonumber(days) >= 30, "retention default must be conservative: " .. out)
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
  for _, f in ipairs({ "lines: 6", "class push: 3", "class other: 3", "event deny: 2", "event PreToolUse: 2",
    "event switch: 2", "since 2020-01-01T00:00:00Z" }) do
    T.expect(has(out, f), "stats missing '" .. f .. "':\n" .. out)
  end
  T.expect(true, "", "ok - guard stats")
end)
