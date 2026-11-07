-- The Matrix request word must not latch on a refill timer from a previous
-- module generation, and a dispatch error must not leave the caller waiting.
-- No daemon, no network: the HTTP primitive and the scheduler are injected.
local config_path = os.tmpname()
local token_path = os.tmpname()
local file = assert(io.open(config_path, "w"))
file:write("http://matrix.invalid\n!room:example.org\n@bot:example.org\n")
file:close()
file = assert(io.open(token_path, "w"))
file:write("token")
file:close()

local dispatched, dispatched_paths = 0, {}
local scheduled, cancelled = {}, {}
local working = false

remuda = {
  _butler_matrix_config = { config_path = config_path, token_path = token_path },
  json = {
    null = {}, array = function(value) return value or {} end,
    object = function(value) return value or {} end,
    decode = function() return {} end,
  },
  http = {
    request = function(spec)
      dispatched = dispatched + 1
      dispatched_paths[#dispatched_paths + 1] = spec.path
      return { cancel = function() end }
    end,
  },
  schedule = function(spec)
    local handle = { run = spec.run, every = spec.every }
    scheduled[#scheduled + 1] = handle
    return handle
  end,
  cancel = function(handle) cancelled[#cancelled + 1] = handle end,
}

dofile("packages/butler/matrix_request.lua")
local matrix = assert(remuda.butler.matrix)

local base_clock = os.clock
local clock_offset = 0
os.clock = function() return base_clock() + clock_offset end

local paths = { "/_matrix/client/versions", "/_matrix/client/v3/account/whoami",
  "/_matrix/client/v3/joined_rooms", "/_matrix/client/v3/pushrules/", "/_matrix/client/v3/capabilities" }
local index = 0
local function request()
  index = index + 1
  local answered
  matrix.request({ method = "GET", path = paths[index] }, function(result)
    answered = result or {}
  end)
  return function() return answered end
end

-- 1. The first request uses the one initial token and dispatches at once.
local answer_a = request()
assert(dispatched == 1, "first request dispatches immediately")

-- 2. The second request queues and arms one refill timer (not ticking yet).
local answer_b = request()
assert(dispatched == 1, "second request waits for a refill token")
assert(#scheduled == 1, "a refill timer is armed")
local dead = scheduled[1]

-- 3. The arming generation ends: the handle stays in the module but never ticks.
clock_offset = 10

-- 4. A later request must notice the stale handle, replace it and dispatch both
--    the queued item and itself without waiting for a second enqueue.
local answer_c = request()
assert(cancelled[1] == dead, "a stale refill handle is cancelled before replacing")
assert(#scheduled == 2, "a replacement timer is armed for the stale handle")
working = true
scheduled[2].run()
scheduled[2].run()
assert(dispatched == 3, "queued requests drain after the stale timer is replaced: "
  .. tostring(dispatched))
assert(select(1, answer_b()) == nil, "the queued request answered without an error")
assert(select(1, answer_c()) == nil, "the new request answered without an error")

-- 5. A dispatch that throws answers the caller instead of being swallowed.
clock_offset = 20
local real_request = remuda.http.request
remuda.http.request = function() error("boom") end
local answer_d = request()
assert(#scheduled == 3, "the throwing request queues behind the empty bucket")
scheduled[3].run()
assert(tostring(answer_d().error):find("dispatch failed", 1, true),
  "a throwing dispatch resolves the callback with an error")
remuda.http.request = real_request

-- 6. Cancelling a queued request resolves it once and never dispatches it.
clock_offset = 30
local before = dispatched
local cancelling
index = index + 1
local handle = matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) cancelling = result end)
handle.cancel()
assert(tostring(cancelling.error) == "cancelled", "cancel answers the caller")
local queued_count = #scheduled
for index = queued_count, 1, -1 do
  if scheduled[index] then scheduled[index].run() end
end
assert(dispatched == before, "a cancelled request is never dispatched")

os.clock = base_clock
os.remove(config_path)
os.remove(token_path)
print("ok: Matrix request queue replaces stale refill timers")
