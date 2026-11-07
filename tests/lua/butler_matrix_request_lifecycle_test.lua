-- Real lifecycle owner proof for the Matrix request pump: a failed activation
-- must retire the queued pre-dispatch work once, both imperative timers must be
-- gone, and the restarted old activation must serve a fresh request without
-- replaying the retired one. This is the rollback path, not a claim that a
-- normal reload tears down imperative schedules.
local REPO = assert(os.getenv("REMUDA_LUA_REPO"))
local DATA = assert(os.getenv("XDG_DATA_HOME"))
local SCRATCH = assert(os.getenv("REMUDA_LUA_SCRATCH"))
T.install_mod("butler", REPO)
T.install_mod("matrix_owner", REPO .. "/tests/lua/fixtures/matrix_owner")

local config = SCRATCH .. "/matrix-owner.conf"
local token = SCRATCH .. "/matrix-owner.token"
assert(remuda.fs.write_atomic(config, "http://matrix.invalid\n!room:example.org\n@bot:example.org\n"))
assert(remuda.fs.write_atomic(token, "token"))

local function owner_snapshot()
  return T.eval([[
    local o = remuda._mq_owner
    local refill_owner, watchdog_owner, refill, watchdog = "nil", "nil", nil, nil
    for handle, spec in pairs(remuda.schedules or {}) do
      if spec.name == "matrix-request-refill" then refill_owner = tostring(spec.owner); refill = handle end
      if spec.name == "matrix-request-watchdog" then watchdog_owner = tostring(spec.owner); watchdog = handle end
    end
    return table.concat({ tostring(o.generation), tostring(o.gets), tostring(o.puts),
      tostring(o.first1), tostring(refill_owner), tostring(watchdog_owner),
      tostring(refill ~= nil), tostring(watchdog ~= nil),
      tostring(o.stop_calls or 0), tostring(o.retire_calls or 0),
      tostring(o.old and o.old.queue_retired), tostring(o.old and o.old.not_sent),
      tostring(o.resume_calls or 0), tostring(o.retire_pcall_ok),
      tostring(o.retire_result and o.retire_result.ok),
      tostring(o.retire_result and o.retire_result.queued_settled),
      tostring(o.retire_result ~= nil and #o.retire_result.cancel_failed == 0),
      tostring(o.stop_retire_calls or 0) }, "|")
  ]])
end

T.test("failed activation retires queued work and the restart serves a fresh read", function()
  T.eval(string.format([[
    remuda._mq_owner = { gets = 0, puts = 0,
      config = { config_path = %q, token_path = %q } }
    remuda.exec("matrix_owner")
  ]], config, token))
  T.eq(owner_snapshot(),
    "1|1|0|true|matrix_owner|matrix_owner|true|true|0|0|nil|nil|0|nil|nil|nil|false|0",
    "both imperative timers are owned by the activation and the second read queues")

  -- Count the retire the candidate reexec must invoke before it publishes its
  -- own request functions; a normal stop is not involved yet.
  T.eval([[
    local o = remuda._mq_owner
    local m = assert(remuda.butler.matrix)
    local original = m.request_retire
    m.request_retire = function()
      o.retire_calls = (o.retire_calls or 0) + 1
      return original()
    end
  ]])

  local marker = SCRATCH .. "/failed-start.marker"
  pcall(os.remove, marker)
  local failing = [[
local host = getmetatable(_G).__index.remuda
return { api = "remuda-module-v1", state_version = 1,
  initialize = function() return {} end,
  start = function()
    local f = assert(io.open(assert(os.getenv("REMUDA_LUA_SCRATCH")) .. "/failed-start.marker", "w"))
    f:write("started"); f:close()
    host.exec("butler/matrix_request")
    local m = host.butler and host.butler.matrix
    if m then
      m.request = function() error("staged client must not answer") end
      m.request_json = m.request
    end
    error("staged activation failed")
  end }
]]
  local entry = DATA .. "/remuda/mods/matrix_owner/packages/matrix_owner/init.lua"
  assert(remuda.fs.write_atomic(entry, failing))

  local reload_ok = T.eval([[ return tostring(pcall(remuda.reload, "matrix_owner")) ]])
  T.ok(reload_ok:match("^false"), "the staged activation fails and rolls back: " .. reload_ok)
  local marker_file = io.open(marker, "rb")
  T.ok(marker_file ~= nil, "the candidate start really ran before failing")
  if marker_file then marker_file:close() end

  local after = owner_snapshot()
  local fields = {}
  for field in after:gmatch("[^|]+") do fields[#fields + 1] = field end
  T.eq(fields[9], "1", "old stop retired the queued item exactly once")
  T.eq(fields[10], "1", "the retire was invoked exactly once")
  T.eq(fields[14], "true", "the retire call itself succeeded")
  T.eq(fields[15], "true", "retire reports ok after both timers are released")
  T.eq(fields[16], "1", "retire reports one queued item settled")
  T.eq(fields[17], "true", "retire reports no failed timer cancel")
  T.eq(fields[18], "1", "the stop hook invoked retire exactly once")
  T.eq(fields[11], "true", "the queued item settled with the typed retirement")
  T.eq(fields[12], "true", "the queued item is marked not_sent")
  T.eq(fields[7], "false", "the old refill timer is gone")
  T.eq(fields[8], "false", "the old watchdog timer is gone")
  T.eq(fields[2], "1", "the retired item was never dispatched")
  -- Rollback must leave a usable client: the same captured client preserves its
  -- rate state, so the post-resume READ waits for the preserved due and then
  -- answers 200 once; no queued item is replayed and no write is duplicated.
  T.eval([[
    local o = remuda._mq_owner
    o.read_before = o.gets
    remuda.butler.matrix.request_json({ method = "GET", path = "/_matrix/client/versions" },
      function(value) o.resume_read = value end)
  ]])
  T.wait_until(function()
    return T.eval([[ return tostring(remuda._mq_owner.resume_read ~= nil) ]]) == "true"
  end, 5, "the resumed client answers the post-rollback READ")
  local resumed = T.eval([[
    local o = remuda._mq_owner
    return table.concat({ tostring(o.resume_calls or 0), tostring(o.gets - o.read_before),
      tostring(o.resume_read and o.resume_read.status),
      tostring(o.resume_read and o.resume_read.error or "nil"), tostring(o.puts) }, "|")
  ]])
  T.eq(resumed, "1|1|200|nil|0",
    "rollback resume preserves the client and one READ answers 200 at its due")

  -- Late callbacks from the retired generation cannot dispatch or mutate.
  local late = T.eval([[
    local o = remuda._mq_owner
    local before = o.gets
    for _, run in ipairs(o.ticks or {}) do pcall(run) end
    return tostring(before == o.gets)
  ]])
  T.eq(late, "true", "late old refill/watchdog ticks dispatch nothing")
end)

-- Direct coverage of Butler init's stop/resume seam (not only the modeled
-- owner): the activation captures the exact compiled request client, so a
-- failed activation that replaces the whole public table cannot redirect
-- stop/resume into the failed functions.
T.test("init stop/resume uses the captured request client across a replaced table", function()
  local log = {}
  local fake
  fake = {
    cli = { parse = function() end },
    schedules = {},
    butler = {},
    _butler_system = {},
  }
  fake.cancel = function() end
  local mate = {
    relay = { stop = function() log[#log + 1] = "relay-stop" end },
    request = function() end,
    request_json = function() end,
  }
  local good = {}
  mate.request_retire = function()
    log[#log + 1] = "retire"
    return { ok = true, retired = true, queued_settled = 0, cancel_failed = {}, detail = "" }
  end
  mate.request_resume = function()
    log[#log + 1] = "resume"
    -- The provider republishes this generation's exact compiled pair.
    mate.request, mate.request_json = good.request, good.request_json
    mate.request_retire, mate.request_resume = good.retire, good.resume
    return { ok = true, retired = false, queued_settled = 0, cancel_failed = {}, detail = "" }
  end
  good.request, good.request_json = mate.request, mate.request_json
  good.retire, good.resume = mate.request_retire, mate.request_resume
  fake.butler.matrix = mate
  fake.exec = function(name)
    if name == "butler/system" then fake._butler_system = {} return end
    if name ~= "butler/main" then return end
    local matrix = fake.butler.matrix
    local notice = { _policy_bound = true }
    fake.butler = {
      dialogs = { install = function() end, stop = function() end },
      native_dispatch = { admit = function() return { outcome = "not_written" } end },
      send_policy = { readiness = function()
        return { owner = notice, bound = true, transport_acquired = true }
      end },
      matrix = matrix,
    }
    fake._butler_notice = notice
    fake._butler_notice_config = {}
  end
  local globals = setmetatable({ remuda = fake }, { __index = _G })
  local env = setmetatable({}, { __index = globals })
  env._G = env
  local chunk
  if setfenv then
    chunk = assert(loadfile("packages/butler/init.lua"))
    setfenv(chunk, env)
  else
    chunk = assert(loadfile("packages/butler/init.lua", "t", env))
  end
  local module = chunk()
  module.commands({})
  module.stop({})
  T.eq(table.concat(log, ","), "relay-stop,retire",
    "stop fences the relay before retiring the captured client")
  -- Break the public table in place after the capture: the captured pair must
  -- still be the one stop/resume use, not the replaced functions.
  fake.butler.matrix.request_retire = function() log[#log + 1] = "BROKEN-retire" end
  fake.butler.matrix.request_resume = function() log[#log + 1] = "BROKEN-resume" end
  module.resume({})
  T.eq(table.concat(log, ","), "relay-stop,retire,resume",
    "resume uses the captured client, not the replaced table")
end)
