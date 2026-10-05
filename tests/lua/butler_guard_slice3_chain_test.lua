-- Guard slice 3, PR7: audit hash chain, `guard verify`.
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

local function sha(text) return T.eval(("return remuda.butler.guard_approval.sha256(%q)"):format(text)) end
local function lines() return T.eval("return remuda._t_lines()") end
local function list(text) local t = {}; for l in text:gmatch("[^\n]+") do t[#t + 1] = l end; return t end
local function prev_of(line) return line:match('"prev":"([^"]*)"') end
local function obs(n) for i = 1, n do T.eval(("remuda.butler.guard_policy.observe('x', 's%d', 'claude', 'y')"):format(i)) end end
local function verify() return T.eval("return remuda._t_guard({'guard','verify'})") end
-- rewrite the live log with fn(list of lines) -> list of lines
local function rewrite(fn)
  local kept = fn(list(lines()))
  T.eval(("local f = io.open(remuda.butler.guard_policy.log_path(), 'w'); f:write(%q); f:close()"):format(table.concat(kept, "\n") .. "\n"))
end

T.test("sha256 matches the FIPS vector", function()
  start_butler()
  T.eq(sha("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc", "ok - sha256")
end)

T.test("a new log starts at a genesis line and each line carries the hash of the one before", function()
  start_butler()
  T.eval("remuda._t_dir('g7-chain'); remuda._t_guard({'guard','on'})")
  obs(3)
  local ls = list(lines())
  T.expect(#ls == 5 and ls[1]:find('"event":"chain"', 1, true) and prev_of(ls[1]) == "genesis", "genesis first: " .. lines())
  for i = 2, #ls do T.eq(prev_of(ls[i]), sha(ls[i - 1]), "prev of line " .. i) end
  T.expect(verify():find("ok", 1, true), "verify ok: " .. verify(), "ok - chain")
end)

T.test("an unchained log keeps its old lines and the chain starts at a genesis line after them", function()
  start_butler()
  T.eval("remuda._t_dir('g7-legacy')")
  local old = '{"time":"2026-01-01T00:00:00Z","session":"s","kind":"claude","event":"PreToolUse","tool":"Bash","class":"push","summary":"x","grant_id":"-"}'
  T.eval(("local f = io.open(remuda.butler.guard_policy.log_path(), 'w'); f:write(%q); f:close()"):format(old .. "\n"))
  T.eval("remuda._t_guard({'guard','on'})")
  local ls = list(lines())
  T.eq(ls[1], old, "old line untouched")
  T.expect(prev_of(ls[2]) == "genesis" and prev_of(ls[3]) == sha(ls[2]), "genesis then chain: " .. lines())
  T.expect(T.eval("return remuda._t_guard({'guard','stats'})"):find("lines: 3", 1, true), "stats reads all 3", "ok - legacy")
end)

T.test("the chain is carried across rotation and verify walks the archives", function()
  start_butler()
  T.eval("remuda._t_dir('g7-rotate'); remuda._t_guard({'guard','on'}); remuda.butler.guard_policy.LOG_CAP = 700")
  obs(6)
  T.eval("remuda.butler.guard_policy.LOG_CAP = 1024 * 1024")
  local ls = list(lines())
  local last_rotated = T.eval("local f = io.open(remuda.butler.guard_policy.log_path() .. '.1'); local l; for x in f:lines() do l = x end; f:close(); return l")
  T.eq(prev_of(ls[1]), sha(last_rotated), "first live line carries the rotated file's last hash")
  T.expect(verify():find("ok", 1, true), "verify ok across files: " .. verify())
  T.eval("os.remove(remuda.butler.guard_policy.log_path() .. '.1')")
  T.expect(verify():find("BROKEN", 1, true), "removing the rotated file is detected: " .. verify(), "ok - rotation")
end)

T.test("verify names the first broken line for a removed, edited or unchained line", function()
  start_butler()
  T.eval("remuda._t_dir('g7-tamper'); remuda._t_guard({'guard','on'})")
  obs(5)
  local good = lines()
  rewrite(function(t) table.remove(t, 3); return t end)
  T.expect(verify():find("BROKEN at guard-audit.jsonl line 3", 1, true), "removed: " .. verify())
  rewrite(function(t) return list(good) end)
  rewrite(function(t) t[3] = t[3]:gsub('"s1"', '"sX"'); return t end)
  T.expect(verify():find("BROKEN at guard-audit.jsonl line 4", 1, true), "edited: " .. verify())
  rewrite(function(t) return list(good) end)
  rewrite(function(t) t[4] = t[4]:gsub(',"prev":"[^"]*"', ''); return t end)
  T.expect(verify():find("BROKEN at guard-audit.jsonl line 4", 1, true), "unchained: " .. verify(), "ok - tamper")
end)

T.test("a failed hash never stops the audit append; verify flags the unchained line", function()
  start_butler()
  T.eval("remuda._t_dir('g7-failsafe'); remuda._t_guard({'guard','on'})")
  obs(1)
  T.eval("local ga = remuda.butler.guard_approval; remuda._t_sha = ga.sha256; ga.sha256 = function() error('boom') end")
  obs(1)
  T.eval("remuda.butler.guard_approval.sha256 = remuda._t_sha")
  local ls = list(lines())
  T.expect(#ls == 4 and not prev_of(ls[4]), "line written without prev: " .. lines())
  T.expect(verify():find("BROKEN", 1, true), "flagged: " .. verify(), "ok - fail-safe")
end)

T.test("guard verify is read-only: it is not classed as a weakening verb", function()
  start_butler()
  T.eq(T.eval("return remuda.butler.guard_policy.classify('Bash', { command = 'remuda butler guard verify' }, { home = '/h' })"), "other", "class")
  T.eq(T.eval("return tostring(remuda.butler.guard_policy.deny_reason('Bash', { command = 'remuda butler guard verify' }, { home = '/h' }))"), "nil", "not denied", "ok - classing")
end)
