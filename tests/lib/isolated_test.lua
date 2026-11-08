-- Shared accident guard for suites that replace globals in a live daemon.
--
-- This is accident prevention, not a security boundary. It refuses to let a
-- mutation-heavy suite run in an ordinary daemon image: the caller must be a
-- fresh process created by the private test wrapper, with an explicit
-- isolated envelope and no reachable Butler/runtime state.
--
-- Pure Lua: no product module, remuda.json, timer, file, transport or session
-- operation runs here. The load itself only defines locals and returns the
-- function below.
--
-- The shell wrapper remains authoritative for ownership, mode (0700) and
-- symlink/real-path checks. Lua compares canonical strings only; LuaJIT has
-- no lstat and cannot prove a path component is not a symlink.

local PREFIX = 'REMUDA_TEST_GUARD: '
local CONTEXT_NAME = 'REMUDA_TEST_CONTEXT'
local ENVELOPE_NAME = 'REMUDA_TEST_ENVELOPE'
local VERSION = 'isolated-v1'
local ID_PATTERN = '^[A-Za-z0-9._-]+$'
local SERVER_PATTERN = '^[A-Za-z0-9._-]+$'

-- Explicit checked identity variables. os.getenv cannot enumerate the
-- environment, so this is not a wildcard proof; the wrapper scrubs every
-- REMUDA_BUTLER_* name in the child before launch and the list below covers
-- the documented ones. A new variable must be added here and to the wrapper.
local IDENTITY_ENV = {
  'REMUDA_SERVER',
  'REMUDA_BUTLER_AGENT_ID',
  'REMUDA_BUTLER_LEADER_ID',
  'REMUDA_BUTLER_TOKEN',
  'REMUDA_BUTLER_CONFIG',
  'REMUDA_BUTLER_PROJECT_HOME',
  'REMUDA_BUTLER_MEMORY_DIR',
  'REMUDA_BUTLER_SESSION',
  'REMUDA_BUTLER_MEMBER',
  'REMUDA_BUTLER_ID',
  'REMUDA_BUTLER_NAME',
  'REMUDA_BUTLER_LEADER',
  'REMUDA_BUTLER_AGENT',
}

local function refuse(fmt, ...)
  error(PREFIX .. string.format(fmt, ...), 0)
end

local function getenv(name)
  local ok, value = pcall(os.getenv, name)
  if not ok then return nil end
  return value
end

local function is_id(value)
  return type(value) == 'string' and #value >= 1 and #value <= 64
    and value:match(ID_PATTERN) ~= nil
end

-- Absolute, no empty/dot/dotdot component, no duplicate or trailing slash.
local function is_canonical(value)
  if type(value) ~= 'string' or value == '' or value:sub(1, 1) ~= '/' then
    return false
  end
  if value == '/' or value:sub(-1) == '/' then return false end
  if value:find('//', 1, true) then return false end
  if value:find('/./', 1, true) or value:sub(-2) == '/.' then return false end
  if value:find('/../', 1, true) or value:sub(-3) == '/..' then return false end
  return true
end

local function under(path, root)
  return path:sub(1, #root + 1) == root .. '/'
end

local function split(value)
  local fields, start = {}, 1
  while true do
    local at = value:find('|', start, true)
    if not at then
      fields[#fields + 1] = value:sub(start)
      return fields
    end
    fields[#fields + 1] = value:sub(start, at - 1)
    start = at + 1
  end
end

local function parse_envelope(raw)
  if type(raw) ~= 'string' or raw == '' then
    refuse('%s is missing; run this suite only under its private test wrapper', ENVELOPE_NAME)
  end
  local fields = split(raw)
  if #fields ~= 8 then
    refuse('%s has %d fields, expected 8', ENVELOPE_NAME, #fields)
  end
  local version, id, root, home, config, data, runtime, socket =
    fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8]
  if version ~= VERSION then
    refuse('%s version %q is not %q', ENVELOPE_NAME, tostring(version), VERSION)
  end
  if not is_id(id) then refuse('%s context id is malformed', ENVELOPE_NAME) end
  for name, path in pairs({
    root = root, home = home, config = config, data = data,
    runtime = runtime, socket = socket,
  }) do
    if not is_canonical(path) then
      refuse('%s %s is not a canonical absolute path: %q', ENVELOPE_NAME, name, tostring(path))
    end
  end
  if home ~= root .. '/home' then
    refuse('%s home is not <root>/home', ENVELOPE_NAME)
  end
  if config ~= root .. '/config' then
    refuse('%s config is not <root>/config', ENVELOPE_NAME)
  end
  if data ~= root .. '/data' then
    refuse('%s data is not <root>/data', ENVELOPE_NAME)
  end
  if runtime ~= root .. '/runtime' then
    refuse('%s runtime is not <root>/runtime', ENVELOPE_NAME)
  end
  if not under(socket, runtime .. '/remuda') then
    refuse('%s socket is not under <runtime>/remuda', ENVELOPE_NAME)
  end
  local leaf = socket:sub(#(runtime .. '/remuda') + 2)
  local server, suffix = leaf:match('^([^/]+)(%.sock)$')
  if not server or suffix ~= '.sock' or not is_id(server) then
    refuse('%s socket is not <runtime>/remuda/<server>.sock', ENVELOPE_NAME)
  end
  return {
    id = id, root = root, home = home, config = config, data = data,
    runtime = runtime, socket = socket, server = server,
  }
end

local function check_envelope()
  local context = getenv(CONTEXT_NAME)
  if context == nil then
    refuse('%s is not set; run this suite only under its private test wrapper', CONTEXT_NAME)
  end
  local version, id = tostring(context):match('^([^:]+):(.+)$')
  if version ~= VERSION or not is_id(id) then
    refuse('%s is malformed: %q', CONTEXT_NAME, tostring(context))
  end
  local envelope = parse_envelope(getenv(ENVELOPE_NAME))
  if id ~= envelope.id then
    refuse('%s id does not match %s', CONTEXT_NAME, ENVELOPE_NAME)
  end
  local bindings = {
    HOME = envelope.home,
    XDG_CONFIG_HOME = envelope.config,
    XDG_DATA_HOME = envelope.data,
    REMUDA_RUNTIME_DIR = envelope.runtime,
  }
  for name, expected in pairs(bindings) do
    local actual = getenv(name)
    if actual ~= expected then
      refuse('%s is %q, expected the envelope value %q', name, tostring(actual), expected)
    end
  end
  for _, name in ipairs(IDENTITY_ENV) do
    if getenv(name) ~= nil then
      refuse('%s is inherited; the wrapper must clear it before launch', name)
    end
  end
  return envelope
end

local function nonempty(name, value)
  if value == nil then return false end
  if type(value) ~= 'table' then return true end
  return next(value) ~= nil
end

local function check_empty_runtime(remuda)
  if type(remuda) ~= 'table' then
    refuse('no remuda runtime table in this process')
  end
  -- Any of these means an image that already runs (or ran) the real thing.
  local live = {
    '_butler_bus',
    '_butler_state',
    '_butler_notice',
    '_relay_timers',
    '_fake_http_timers',
  }
  for _, name in ipairs(live) do
    if rawget(remuda, name) ~= nil then
      refuse('live runtime evidence: remuda.%s exists', name)
    end
  end
  if rawget(remuda, 'butler') ~= nil then
    refuse('live runtime evidence: remuda.butler exists')
  end

  local schedules = rawget(remuda, 'schedules')
  if schedules == nil then
    refuse('remuda.schedules is absent; cannot prove an empty timer registry')
  end
  local registry = schedules
  if type(schedules) == 'function' then
    local ok, value = pcall(schedules)
    if not ok then refuse('remuda.schedules accessor failed') end
    registry = value
  end
  if type(registry) ~= 'table' then
    refuse('remuda.schedules is malformed (%s)', type(registry))
  end
  if next(registry) ~= nil then
    refuse('remuda.schedules is not empty')
  end

  local ls = rawget(remuda, 'ls')
  if type(ls) ~= 'function' then
    refuse('remuda.ls is unavailable; cannot prove an empty roster')
  end
  local ok, roster = pcall(ls)
  if not ok then refuse('remuda.ls failed') end
  if type(roster) ~= 'table' then
    refuse('remuda.ls returned %s, expected a roster table', type(roster))
  end
  for key in pairs(roster) do
    refuse('roster is not empty (first key %s)', tostring(key))
  end
end

return function(remuda)
  local envelope = check_envelope()
  check_empty_runtime(remuda)
  return true, envelope
end
