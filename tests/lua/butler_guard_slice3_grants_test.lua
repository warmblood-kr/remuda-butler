-- Guard slice 3, PR3: the grant store, `guard grants`, the grants switch, grant_id from the store, push diff check.
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

T.test("clearing the guard-unaudited marker appends a switch line that records it; an unwritable line keeps the marker", function()
  start_butler()
  T.eval("remuda._t_dir('g3p3-marker'); remuda._t_guard({'guard','on'}); remuda._t_guard({'guard','deny','on'})")
  T.eval([[local gp = remuda.butler.guard_policy
    remuda.process.run({ argv = { 'chmod', '400', gp.log_path() } })
    local real = io.stderr; io.stderr = { write = function() end }
    remuda._t_guard({'guard','off'}); io.stderr = real
    remuda.process.run({ argv = { 'chmod', '600', gp.log_path() } })]])
  T.expect(has(T.eval("return remuda._t_guard({'guard','status'})"), "NOT audited"), "marker set by the unaudited off")
  T.eval("remuda._t_guard({'guard','on'})")
  local lines = T.eval("return remuda._t_lines()")
  local note; for l in lines:gmatch("[^\n]+") do if has(l, "earlier off NOT audited:") then note = l end end
  T.expect(note and has(note, '"event":"switch"') and has(note, '"class":"other"'), "no switch line records the marker: " .. lines)
  T.expect(not has(T.eval("return remuda._t_guard({'guard','status'})"), "NOT audited"), "marker cleared after the note")
  -- the note cannot be written: the marker stays
  T.eval([[local gp = remuda.butler.guard_policy
    local f = io.open(remuda._butler_guard_dir .. '/guard-unaudited', 'w'); f:write('x\n'); f:close()
    local real, calls = io.open, 0
    io.open = function(path, mode)
      if path == gp.log_path() and mode == 'a' then calls = calls + 1; if calls == 2 then return nil, 'boom' end end
      return real(path, mode)
    end
    remuda._t_ok = pcall(gp.append, { session = 's', event = 'switch', summary = 'x' })
    io.open = real]])
  T.expect(has(T.eval("return remuda._t_guard({'guard','status'})"), "NOT audited"), "marker kept when its note cannot be written")
  T.expect(true, "", "ok - marker note")
end)

T.test("a failed switch write after an unaudited off clears the marker: no off took effect", function()
  start_butler()
  T.eval("remuda._t_dir('g3p3-offfail'); remuda._t_guard({'guard','on'})")
  T.eval([[local gp = remuda.butler.guard_policy
    os.remove(remuda._butler_guard_dir .. '/guard-observe'); remuda.mkdir(remuda._butler_guard_dir .. '/guard-observe') -- a directory where the switch belongs
    remuda.process.run({ argv = { 'chmod', '400', gp.log_path() } })
    local real = io.stderr; io.stderr = { write = function() end }
    pcall(remuda._t_guard, {'guard','off'}); io.stderr = real
    remuda.process.run({ argv = { 'chmod', '600', gp.log_path() } })]])
  local status = T.eval("return remuda._t_guard({'guard','status'})")
  T.expect(not has(status, "NOT audited"), "a switch that never turned off must not warn of an unaudited off: " .. status,
    "ok - failed set clears marker")
end)
