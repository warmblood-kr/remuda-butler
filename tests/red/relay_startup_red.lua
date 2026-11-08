-- Expected RED until the relay startup/bridge/archive wiring lands.
-- Run from the repository root: luajit tests/red/relay_startup_red.lua
-- Exit 0 only when every required caller seam exists and the bounded rules hold.
local failures = {}
local function check(name, body)
  local ok, why = pcall(body)
  if not ok then
    failures[#failures + 1] = name
    print("RED " .. name .. ": " .. tostring(why))
  else
    print("GREEN " .. name)
  end
end

local function declaration(host)
  local parent = setmetatable({ remuda = host }, { __index = _G })
  local env = setmetatable({}, { __index = parent })
  env._G = env
  local chunk = assert(loadfile("packages/butler/init.lua"))
  setfenv(chunk, env)
  return chunk()
end

local function publish_graph(host, options)
  local notice = { _policy_bound = true }
  local policy = {}
  policy.readiness = function()
    return { owner = notice, bound = true, transport_acquired = true }
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

local function fixture(options)
  local host = {
    cli = { parse = function() end }, schedules = {},
    _butler_skip_relay = options.relay == nil,
    _butler_test_mode = "lifecycle",
    _butler_bus = { durable = { marker = 1 } },
  }
  host.emit = function() end
  host.exec = function(name)
    if name == "butler/system" then host._butler_system = {}; return end
    assert(name == "butler/main")
    publish_graph(host, options)
  end
  return host
end

check("init blocks relay.start when authority is blocked", function()
  local starts = 0
  local relay = {
    start = function() starts = starts + 1; return true end,
    stop = function() end,
    owner_proven = function() return true end,
  }
  local host = fixture({ relay = true, matrix = { relay = relay } })
  host.http = { request = function() end }
  host._butler_matrix_config = { config_path = "/tmp/red-relay" }
  host._butler_relay_authority = {
    start = function() return nil, "blocked: inbox_proof_missing" end,
  }
  local module = declaration(host)
  module.start({})
  assert(starts == 0, "matrix.relay.start ran despite a blocked authority receipt")
end)

check("authority seam exists and refuses without a real inbox producer", function()
  local authority = assert(dofile("packages/butler/relay_authority.lua"))
  for _, name in ipairs({ "start", "advance", "status", "assert_inbox_compatible" }) do
    assert(type(authority[name]) == "function", "missing authority." .. name)
  end
  local result, why = authority.start({ config_path = "/tmp/red-relay" },
    { inbox_proof = nil })
  assert(result == nil, "authority started without an inbox producer")
  assert(tostring(why):find("inbox", 1, true), "missing inbox refusal: " .. tostring(why))
end)

check("migrate exposes one bounded store action per call", function()
  local migrate = assert(dofile("packages/butler/relay_store_migrate.lua"))
  assert(type(migrate.step) == "function", "bounded migrate.step missing")
  local actions = 0
  local store = {
    import_prepare = function() actions = actions + 1; return true end,
    import_source = function() actions = actions + 1; return { accepted = true,
      done = false, ingest_id = "ingest:source:red:fixture1", revision = 1,
      phase = "HASH" } end,
    import_batch = function() actions = actions + 1; return { count = 0,
      done = false, phase = "HASH", ingest_id = "ingest:source:red:fixture1" } end,
    ingest_step = function() actions = actions + 1; return { done = false,
      phase = "HASH", ingest_id = "ingest:source:red:fixture1", revision = 2 } end,
    verify_import = function() actions = actions + 1; return { verified = false,
      state = "backlog" } end,
    activate = function() actions = actions + 1; return { store_id = "red" } end,
  }
  local before = actions
  local result, why = migrate.step(store, {}, {})
  assert(result or why, "step returned neither progress nor refusal")
  assert(actions - before <= 1, "one advance performed " .. (actions - before) .. " store actions")
end)

check("archive refuses to plan without both current proofs", function()
  local archive = assert(dofile("packages/butler/relay_archive.lua"))
  for _, name in ipairs({ "plan", "advance", "status" }) do
    assert(type(archive[name]) == "function", "missing archive." .. name)
  end
  local plan, why = archive.plan({})
  assert(plan == nil, "archive planned without relay+inbox proofs")
  assert(tostring(why):find("proof", 1, true), "missing proof refusal: " .. tostring(why))
end)

if #failures > 0 then
  print("RED_COUNT " .. #failures)
  os.exit(1)
end
print("relay startup RED cleared")
