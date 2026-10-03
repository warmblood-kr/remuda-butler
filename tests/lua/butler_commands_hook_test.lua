-- #397: init.lua's `commands` hook registers the CLI verbs without booting;
-- `start` boots once. init.lua is loaded here against a recording host proxy,
-- so the test runs on any core (the core calling the hook is not required).
local DRIVER = [==[
local repo = os.getenv("REMUDA_LUA_REPO")
local with_hook = ...
local f = assert(io.open(repo .. "/packages/butler/init.lua"))
local src = f:read("a"); f:close()
local log = { emits = {}, schedules = {}, bootstrap = 0, reconcile = 0 }
local host = setmetatable({}, { __index = function(_, k) if k ~= "_exec_commands" then return remuda[k] end end,
  __newindex = function(_, k, v) if k ~= "_exec_commands" then remuda[k] = v end end })
local real_emit = remuda.emit
rawset(host, "emit", function(name, ...) log.emits[#log.emits + 1] = name; return real_emit(name, ...) end)
log.specs = {}
rawset(host, "schedule", function(spec) log.schedules[#log.schedules + 1] = spec.name; log.specs[spec.name] = spec; return 0 end)
rawset(host, "cancel", function() end)
local exec_commands = with_hook and function() end or nil
rawset(host, "_exec_commands", exec_commands)
local fake_g = setmetatable({}, { __index = { remuda = host } })
local env = setmetatable({ _G = fake_g, getmetatable = getmetatable }, { __index = _G })
local mod = assert(load(src, "@init.lua", "t", env))()
remuda._butler_skip_relay = true
return mod, log, host
]==]

local function setup()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
end
local function run(body, with_hook)
  return T.eval("local mod, log, host = (function(...) " .. DRIVER .. " end)(" .. tostring(with_hook) .. ")\n"
    .. "local out = {}\n" .. body .. "\nreturn table.concat(out, ';')")
end

T.test("commands registers the verbs and boots nothing", function()
  setup()
  local out = run([==[
    local count = function(t, n) local c = 0 for _, v in ipairs(t) do if v == n then c = c + 1 end end return c end
    mod.commands({})
    remuda._butler_bootstrap = function() log.bootstrap = log.bootstrap + 1 end
    remuda._butler_reconcile = function() log.reconcile = log.reconcile + 1 end
    for _, s in ipairs(mod.schedules) do pcall(s.run, {}) end
    local usage = {}
    for _, e in ipairs(mod.contributes["butler.command"]) do usage[e.verb] = e.usage end
    out[#out + 1] = "run=" .. type(remuda._butler_command_run)
    out[#out + 1] = "doctor=" .. tostring(usage.doctor)
    out[#out + 1] = "emits=" .. #log.emits
    log.specs["butler-start-fallback"].run()
    out[#out + 1] = "fallback=" .. count(log.schedules, "butler-start-fallback")
    out[#out + 1] = "emits_after_fallback=" .. #log.emits
    out[#out + 1] = "bootstrap=" .. log.bootstrap
    out[#out + 1] = "reconcile=" .. log.reconcile
    out[#out + 1] = "sessions=" .. #remuda.ls()
  ]==], true)
  T.expect(out:find("run=function", 1, true), "verbs not registered: " .. out, "ok - commands loads the verb runner")
  T.expect(out:find("doctor=  remuda butler doctor", 1, true), "usage missing: " .. out, "ok - verbs carry usage")
  T.expect(out:find("emits=0;", 1, true) and out:find("bootstrap=0", 1, true), "commands booted: " .. out,
    "ok - no butler-start, no bootstrap")
  T.expect(out:find("emits_after_fallback=0", 1, true), "fallback booted a commands-only load: " .. out,
    "ok - the fallback does not boot a commands-only load")
  T.expect(out:find("reconcile=0", 1, true), "reconcile ran before boot: " .. out, "ok - schedules inert before boot")
  T.expect(out:find("sessions=0", 1, true), "a session was created: " .. out, "ok - no Butler session")
end)

T.test("start after commands boots once and opens the schedules", function()
  setup()
  local out = run([==[
    mod.commands({})
    remuda._butler_bootstrap = function() log.bootstrap = log.bootstrap + 1 end
    remuda._butler_reconcile = function() log.reconcile = log.reconcile + 1 end
    mod.start({})
    mod.start({})
    pcall(mod.schedules[2].run, {})
    out[#out + 1] = "emits=" .. table.concat(log.emits, ",")
    out[#out + 1] = "bootstrap=" .. log.bootstrap
    out[#out + 1] = "reconcile=" .. log.reconcile
  ]==], true)
  T.expect(out:find("emits=butler-start;", 1, true), "butler-start not emitted once: " .. out, "ok - butler-start once")
  T.expect(out:find("bootstrap=1;", 1, true), "bootstrap not once: " .. out, "ok - bootstrap once")
  T.expect(out:find("reconcile=1", 1, true), "reconcile gated after boot: " .. out, "ok - reconcile runs after boot")
end)

T.test("a core without the hook keeps the fallback boot", function()
  setup()
  local out = run([==[
    out[#out + 1] = "fallback=" .. #log.schedules
    out[#out + 1] = "name=" .. tostring(log.schedules[1])
    out[#out + 1] = "commands=" .. type(mod.commands)
    remuda._butler_bootstrap = function() end
    mod.start({})
    out[#out + 1] = "emits=" .. #log.emits
  ]==], false)
  T.expect(out:find("name=butler-start-fallback", 1, true), "fallback missing: " .. out, "ok - old core schedules the fallback")
  T.expect(out:find("emits=1", 1, true), "start did not boot: " .. out, "ok - start boots as before")
end)

T.test("a load that is not commands-only boots by fallback on a core with the hook", function()
  setup()
  local out = run([==[
    remuda._butler_bootstrap = function() end
    log.specs["butler-start-fallback"].run()
    out[#out + 1] = "emits=" .. #log.emits
  ]==], true)
  T.expect(out:find("emits=1", 1, true), "an exec load did not boot: " .. out, "ok - an exec load boots by fallback on a hook core")
end)
