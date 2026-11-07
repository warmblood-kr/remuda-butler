-- Lifecycle failure regression: executes init.lua against a mock host, never a
-- daemon. The same three failures were reproduced from the external incident
-- fixture; the extra cases cover the staging contract (emit ownership, relay
-- resource intent, durable-state exclusion).
--
-- Run from the repository root: luajit tests/butler_lifecycle_reload.lua
local source = arg[1] or "packages/butler/init.lua"

local function declaration(host)
  local parent = setmetatable({ remuda = host }, { __index = _G })
  local env = setmetatable({}, { __index = parent })
  env._G = env
  local chunk = assert(loadfile(source))
  setfenv(chunk, env)
  return chunk()
end

local function fixture(options)
  options = options or {}
  local host = {
    cli = { parse = function() end },
    schedules = {},
    _butler_skip_relay = options.relay == nil,
    _butler_test_mode = options.test_mode == "none" and nil or (options.test_mode or "lifecycle"),
    _butler_bus = { durable = { marker = 1 } },
  }
  local loads, failing, emits = 0, false, 0
  host.emit = function()
    emits = emits + 1
    if options.emit_fail and emits == 1 then error("injected emit failure") end
  end
  host.exec = function(name)
    if name == "butler/system" then
      host._butler_system = {}
      return
    end
    assert(name == "butler/main")
    loads = loads + 1
    if failing then error("injected main failure") end
    host.butler = {
      dialogs = { install = function() end, stop = function() end },
      native_dispatch = {},
      send_policy = {},
      matrix = options.matrix or {},
    }
    host._butler_notice = {}
  end
  return host,
    function(value) failing = value end,
    function() return loads end,
    function() return emits end
end

local failures = 0
local function test(name, body)
  local ok, why = pcall(body)
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(why)))
  if not ok then failures = failures + 1 end
end

test("failed main initialization can retry", function()
  local host, fail, loads = fixture()
  local module = declaration(host)
  fail(true)
  assert(not pcall(module.commands, {}))
  fail(false)
  module.commands({})
  assert(loads() == 2 and host.butler and host.butler.send_policy,
    "main_loaded must not commit before main succeeds")
end)

test("cached resume restores the last-good notification graph", function()
  local host = fixture()
  local module = declaration(host)
  local state = {}
  module.commands(state)
  module.start(state)
  local good, notice = host.butler, host._butler_notice
  local policy, dispatch, matrix = good.send_policy, good.native_dispatch, good.matrix
  module.stop(state)
  -- A failed candidate can mutate the shared nested table; shallow restoration
  -- of the top-level reference cannot restore its members.
  good.send_policy, good.native_dispatch, good.matrix = nil, {}, {}
  host._butler_notice = {}
  module.resume(state)
  assert(host.butler.send_policy == policy, "policy reference lost")
  assert(host.butler.native_dispatch == dispatch, "dispatch reference lost")
  assert(host.butler.matrix == matrix, "matrix reference lost")
  assert(host._butler_notice == notice, "notice owner reference lost")
end)

test("failed bootstrap does not mark boot complete", function()
  local host = fixture({ test_mode = "none" })
  local attempts = 0
  host._butler_bootstrap = function()
    attempts = attempts + 1
    if attempts == 1 then error("injected bootstrap failure") end
  end
  local module = declaration(host)
  module.commands({})
  assert(not pcall(module.start, {}))
  module.start({})
  assert(attempts == 2, "booted must not suppress incomplete bootstrap retry")
end)

test("partial emit fails closed for this activation, a fresh one retries", function()
  local host, _, _, emits = fixture({ emit_fail = true })
  local module = declaration(host)
  module.commands({})
  assert(not pcall(module.start, {}), "first emit must fail")
  assert(emits() == 1, "one partial emit")
  assert(not pcall(module.start, {}), "same activation must not re-emit")
  assert(emits() == 1, "same activation must not repeat partial emit")
  local fresh = fixture()
  local module2 = declaration(fresh)
  module2.commands({})
  module2.start({})
end)

test("resume restarts a previously running relay exactly once", function()
  local starts, stops = 0, 0
  local relay = { instance = {} }
  relay.start = function()
    starts = starts + 1
    relay.instance = {}
  end
  relay.stop = function()
    stops = stops + 1
    relay.instance = nil
  end
  local host = fixture({ relay = true, matrix = { relay = relay } })
  host._butler_matrix_config = { config_path = "/tmp/butler-test-config" }
  host.http = { request = function() end }
  local module = declaration(host)
  local state = {}
  module.commands(state)
  module.start(state)
  assert(starts == 0 and relay.instance ~= nil, "relay starts only through resume")
  module.stop(state)
  assert(stops == 1 and relay.instance == nil, "stop clears the handle")
  module.resume(state)
  assert(starts == 1 and relay.instance ~= nil, "resume restarts exactly once")
  module.resume(state)
  assert(starts == 1, "a second resume must not restart a live relay")
end)

test("resume does not rewind durable bus state", function()
  local host = fixture()
  local module = declaration(host)
  local state = {}
  module.commands(state)
  module.start(state)
  module.stop(state)
  host._butler_bus.durable.marker = 2
  module.resume(state)
  assert(host._butler_bus.durable.marker == 2,
    "runtime graph rollback must not restore durable state")
end)

os.exit(failures == 0 and 0 or 1)
