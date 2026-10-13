-- Guard slice 3, PR7 fixes: verify and a live log being written; the audit lock falls back, never blocks.
local function start_butler()
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
    remuda._t_hook = function(stdin)
      return remuda._butler_command_run('guard', {'guard'}, { kind = 'session', session = 's-ssa', stdin = stdin })
    end
    remuda._t_lines = function()
      local out, f = {}, io.open(gp.log_path(), 'r')
      if not f then return '' end
      for l in f:lines() do out[#out + 1] = l end
      f:close(); return table.concat(out, '\n')
    end
    remuda._t_guard = function(args, caller) caller = caller or {}; caller.kind = 'session'; caller.session = 'butler'; caller.instance_id = _inst('butler'); return remuda._butler_command_run('guard', args, caller) end
    return 'ok'
  ]])
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end

local function sha(text) return T.eval(("return remuda.butler.guard_approval.sha256(%q)"):format(text)) end
local function lines() return T.eval("return remuda._t_lines()") end
local function list(text) local t = {}; for l in text:gmatch("[^\n]+") do t[#t + 1] = l end; return t end
local function prev_of(line) return line:match('"prev":"([^"]*)"') end
local function obs(n) for i = 1, n do T.eval(("remuda.butler.guard_policy.observe('x', 's%d', 'claude', 'y')"):format(i)) end end
local function verify() return T.eval("return remuda._t_guard({'guard','verify'})") end

T.test("verify tolerates an unterminated last line of the live log and says so", function()
  start_butler()
  T.eval("remuda._t_dir('g7-partial'); remuda._t_guard({'guard','on'})")
  obs(2)
  T.eval("local f = io.open(remuda.butler.guard_policy.log_path(), 'a'); f:write('{\"time\":\"2026-10-0'); f:close()")
  local out = verify()
  T.expect(out:find("guard verify: ok", 1, true) and out:find("no newline yet", 1, true) and not out:find("BROKEN", 1, true), "note, not BROKEN: " .. out)
  T.eval("local f = io.open(remuda.butler.guard_policy.log_path(), 'a'); f:write('\\n'); f:close()")
  T.expect(verify():find("BROKEN", 1, true), "the same line once terminated is judged: " .. verify(), "ok - partial")
end)

T.test("a held audit lock never blocks the write: it falls back after about a second", function()
  start_butler()
  T.eval("remuda._t_dir('g7-lock'); remuda._t_guard({'guard','on'})")
  T.eval("remuda._t_hold = assert(remuda.fs.lock(remuda.butler.guard_policy.log_path() .. '.lock'))")
  local took = tonumber(T.eval("local t = os.time(); remuda.butler.guard_policy.observe('x', 's', 'claude', 'y'); return os.time() - t"))
  T.eval("remuda._t_hold:release()")
  T.expect(took >= 0 and took <= 3, "returned in " .. took .. " s")
  T.eq(#list(lines()), 3, "genesis, on and the line written under the held lock: " .. lines(), "ok - lock")
end)
