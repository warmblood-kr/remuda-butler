-- Focused behavioral tests for tests/lib/isolated_test.lua.
-- Run with plain luajit from the repository root:
--   luajit tests/isolated_test_guard_test.lua
-- No daemon, scheduler, session, file or transport operation is used.

local ROOT = '/private/tmp/guard-test-root'
local ID = 'guard-test-1'

local function envelope(overrides)
  local values = {
    version = 'isolated-v1', id = ID, root = ROOT,
    home = ROOT .. '/home', config = ROOT .. '/config',
    data = ROOT .. '/data', runtime = ROOT .. '/runtime',
    socket = ROOT .. '/runtime/remuda/bmr.sock',
  }
  for key, value in pairs(overrides or {}) do values[key] = value end
  return table.concat({
    values.version, values.id, values.root, values.home, values.config,
    values.data, values.runtime, values.socket,
  }, '|')
end

local function environment(overrides)
  local values = {
    REMUDA_TEST_CONTEXT = 'isolated-v1:' .. ID,
    REMUDA_TEST_ENVELOPE = envelope(),
    HOME = ROOT .. '/home',
    XDG_CONFIG_HOME = ROOT .. '/config',
    XDG_DATA_HOME = ROOT .. '/data',
    REMUDA_RUNTIME_DIR = ROOT .. '/runtime',
  }
  for key, value in pairs(overrides or {}) do
    if value == false then
      values[key] = nil
    else
      values[key] = value
    end
  end
  return values
end

local function empty_remuda()
  return { schedules = {}, ls = function() return {} end }
end

local original_getenv = os.getenv
local function with_env(values)
  os.getenv = function(key) return values[key] end
end

-- Loading the helper must not create globals or touch a host table.
local globals_before = {}
for key in pairs(_G) do globals_before[key] = true end
local guard = dofile('tests/lib/isolated_test.lua')
for key in pairs(_G) do
  assert(globals_before[key], 'guard load added global ' .. tostring(key))
end
assert(type(guard) == 'function', 'guard helper must return a function')

local failures = 0
local function fail(name, message)
  failures = failures + 1
  print('FAIL ' .. name .. ': ' .. tostring(message))
end

local function expect_admitted(name, values, remuda)
  with_env(values)
  local ok, err = pcall(guard, remuda)
  if not ok then fail(name, 'refused: ' .. tostring(err)) end
end

local function expect_refused(name, values, remuda)
  with_env(values)
  local ok, err = pcall(guard, remuda)
  if ok then
    fail(name, 'was admitted')
  elseif not tostring(err):find('REMUDA_TEST_GUARD:', 1, true) then
    fail(name, 'refused without the stable prefix: ' .. tostring(err))
  end
end

local function deep_snapshot(root)
  local seen, saved = {}, {}
  local function visit(value)
    if type(value) ~= 'table' or seen[value] then return end
    seen[value] = true
    local record = { entries = {}, meta = getmetatable(value) }
    saved[value] = record
    for key, item in pairs(value) do
      record.entries[key] = item
      visit(key)
      visit(item)
    end
    visit(record.meta)
  end
  visit(root)
  return saved
end

local function deep_changes(saved)
  local result = {}
  for original, record in pairs(saved) do
    if getmetatable(original) ~= record.meta then result[#result + 1] = 'metatable changed' end
    for key, item in pairs(record.entries) do
      if rawget(original, key) ~= item then result[#result + 1] = 'changed ' .. tostring(key) end
    end
    for key in pairs(original) do
      if record.entries[key] == nil then result[#result + 1] = 'added ' .. tostring(key) end
    end
  end
  return result
end

expect_admitted('valid empty envelope', environment(), empty_remuda())

expect_refused('missing context', environment({ REMUDA_TEST_CONTEXT = false }), empty_remuda())
expect_refused('malformed context', environment({ REMUDA_TEST_CONTEXT = 'invalid' }), empty_remuda())
expect_refused('bad context id', environment({ REMUDA_TEST_CONTEXT = 'isolated-v1:bad/id' }), empty_remuda())
expect_refused('mismatched context', environment({ REMUDA_TEST_CONTEXT = 'isolated-v1:other' }), empty_remuda())
expect_refused('missing envelope', environment({ REMUDA_TEST_ENVELOPE = false }), empty_remuda())
expect_refused('short envelope', environment({ REMUDA_TEST_ENVELOPE = 'isolated-v1|wrong|/bad' }), empty_remuda())
expect_refused('wrong version', environment({ REMUDA_TEST_ENVELOPE = envelope({ version = 'v2' }) }), empty_remuda())
expect_refused('noncanonical root', environment({ REMUDA_TEST_ENVELOPE = envelope({ root = '/tmp/../escape' }) }), empty_remuda())
expect_refused('wrong home field', environment({ REMUDA_TEST_ENVELOPE = envelope({ home = ROOT .. '/elsewhere' }) }), empty_remuda())
expect_refused('bad socket leaf', environment({ REMUDA_TEST_ENVELOPE = envelope({ socket = ROOT .. '/runtime/remuda/nested/bmr.sock' }) }), empty_remuda())
expect_refused('wrong home binding', environment({ HOME = '/private/tmp/foreign-home' }), empty_remuda())
expect_refused('wrong runtime binding', environment({ REMUDA_RUNTIME_DIR = '/private/tmp/foreign-runtime' }), empty_remuda())
expect_refused('inherited server', environment({ REMUDA_SERVER = 'production' }), empty_remuda())
expect_refused('inherited identity', environment({ REMUDA_BUTLER_AGENT_ID = 'production-member' }), empty_remuda())

-- Marker never overrides live evidence, including an otherwise empty bus.
expect_refused('any empty bus', environment(), {
  schedules = {}, ls = function() return {} end, _butler_bus = {},
})
expect_refused('empty butler table', environment(), {
  schedules = {}, ls = function() return {} end, butler = {},
})
expect_refused('startup state', environment(), {
  schedules = {}, ls = function() return {} end, _butler_state = {},
})
expect_refused('relay timers', environment(), {
  schedules = {}, ls = function() return {} end, _relay_timers = {},
})
expect_refused('fake http timers', environment(), {
  schedules = {}, ls = function() return {} end, _fake_http_timers = {},
})
expect_refused('notice controller', environment(), {
  schedules = {}, ls = function() return {} end, _butler_notice = { controller = {} },
})
expect_refused('malformed schedules', environment(), {
  schedules = 'invalid', ls = function() return {} end,
})
expect_refused('nonempty schedules', environment(), {
  schedules = { timer = {} }, ls = function() return {} end,
})
expect_refused('missing roster api', environment(), { schedules = {} })
expect_refused('throwing roster api', environment(), {
  schedules = {}, ls = function() error('boom') end,
})
expect_refused('nonempty roster', environment(), {
  schedules = {}, ls = function() return { { name = 'existing' } } end,
})
expect_refused('forged marker and live graph', environment(), {
  schedules = {}, ls = function() return {} end, _butler_bus = {},
})

-- A refusal leaves the reachable graph untouched.
local host = {
  schedules = {}, ls = function() return {} end, butler = {},
  _butler_bus = { agents = {} }, _relay_timers = { { cancelled = false } },
}
local saved = deep_snapshot(host)
with_env(environment())
local ok = pcall(guard, host)
if ok then fail('snapshot refusal', 'was admitted') end
local changes = deep_changes(saved)
if #changes > 0 then fail('snapshot refusal', table.concat(changes, '; ')) end

with_env(environment())
local admitted_ok, admitted = guard(empty_remuda())
if not admitted_ok then
  fail('positive return value', 'guard did not report success')
elseif type(admitted) ~= 'table' or admitted.server ~= 'bmr' then
  fail('positive return value', 'missing canonical envelope')
end

os.getenv = original_getenv
if failures > 0 then
  error(tostring(failures) .. ' guard test(s) failed', 0)
end
print('ok - isolated_test guard behavioral cases')
