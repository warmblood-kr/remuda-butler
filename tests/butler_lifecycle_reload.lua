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
    local notice = { _policy_bound = true }
    local policy = {}
    if options.readiness ~= false then
      policy.readiness = function()
        return { owner = notice, bound = true, transport_acquired = true }
      end
    end
    host.butler = {
      dialogs = { install = function() end, stop = function() end },
      native_dispatch = { admit = function() return { outcome = "not_written" } end },
      send_policy = policy,
      matrix = options.matrix or {},
    }
    host._butler_notice = notice
    host._butler_notice_config = { bus = host._butler_bus }
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

local function relay_fixture(fenced)
  local starts, stops, seen = 0, 0, nil
  local relay = { instance = {} }
  relay.start = function(config)
    starts = starts + 1
    seen = config
    relay.instance = {}
  end
  relay.stop = function()
    stops = stops + 1
    relay.instance = nil
  end
  if fenced then relay.owner_proven = function() return true end end
  local host = fixture({ relay = true, matrix = { relay = relay } })
  host.http = { request = function() end }
  return host, relay, {
    starts = function() return starts end,
    stops = function() return stops end,
    seen = function() return seen end,
  }
end

test("resume restarts a stopped relay once with a positive owner fence", function()
  local host, relay, counters = relay_fixture(true)
  host._butler_matrix_config = { config_path = "/tmp/butler-test-config" }
  local module = declaration(host)
  local state = {}
  module.commands(state)
  module.start(state)
  assert(counters.starts() == 0 and relay.instance ~= nil, "relay starts only through resume")
  module.stop(state)
  assert(counters.stops() == 1 and relay.instance == nil, "stop clears the handle")
  module.resume(state)
  assert(counters.starts() == 1 and relay.instance ~= nil, "fenced resume restarts once")
  assert(counters.seen() == host._butler_matrix_config, "restored relay config")
  module.resume(state)
  assert(counters.starts() == 1, "a second resume must not restart a live relay")
end)

test("resume never restarts a stopped snapshot without an owner fence", function()
  local host, relay, counters = relay_fixture(false)
  host._butler_matrix_config = { config_path = "/tmp/butler-test-config" }
  local module = declaration(host)
  local state = {}
  module.commands(state)
  module.start(state)
  module.stop(state)
  assert(relay.instance == nil, "stopped by the lifecycle")
  module.resume(state)
  assert(counters.starts() == 0, "unfenced resume must not create a second writer")
  assert(host._butler_relay_restart_blocked == true, "blocked state is explicit")
end)

test("resume validates the graph before starting a resource", function()
  local host, _, counters = relay_fixture(true)
  host._butler_matrix_config = {}
  local module = declaration(host)
  local state = {}
  module.commands(state)
  module.start(state)
  module.stop(state)
  host._butler_bus = {}
  assert(not pcall(module.resume, state), "bus mismatch must fail")
  assert(counters.starts() == 0, "invalid graph started a relay before validation")
end)

test("resume restores the pre-stop relay config", function()
  local host, _, counters = relay_fixture(true)
  local old = { marker = "old" }
  host._butler_matrix_config = old
  local module = declaration(host)
  local state = {}
  module.commands(state)
  module.start(state)
  module.stop(state)
  host._butler_matrix_config = { marker = "candidate" }
  module.resume(state)
  assert(host._butler_matrix_config == old, "candidate config survived rollback")
  assert(counters.seen() == old, "resumed relay used the candidate config")
end)

test("missing readiness fails closed at load and resume", function()
  local host = fixture({ readiness = false })
  local module = declaration(host)
  assert(not pcall(module.commands, {}), "unverifiable policy was loaded")
end)

test("rollback clears a candidate export absent from the old graph", function()
  local host = fixture()
  local module = declaration(host)
  local state = {}
  module.commands(state)
  module.start(state)
  module.stop(state)
  host._butler_notify = function() error("candidate") end
  module.resume(state)
  assert(host._butler_notify == nil, "candidate notify survived rollback")
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
