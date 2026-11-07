-- The Matrix request word must not latch on a refill timer from a previous
-- module generation, and a lone queued item must recover without another
-- request. No daemon, no network: HTTP and the scheduler are injected.
local config_path = os.tmpname()
local token_path = os.tmpname()
local file = assert(io.open(config_path, "w"))
file:write("http://matrix.invalid\n!room:example.org\n@bot:example.org\n")
file:close()
file = assert(io.open(token_path, "w"))
file:write("token")
file:close()

local dispatched, dispatched_paths = 0, {}
local schedules, cancelled = {}, {}
local now_ms = 0

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
      local callback = spec.callback
      if type(callback) == "function" then
        callback({ status = 200, headers = {}, body = "{}" })
      end
      return { cancel = function() end }
    end,
  },
  schedules = schedules,
  clock = function() return now_ms end,
  schedule = function(spec)
    local handle = { run = spec.run, every = spec.every, name = spec.name }
    schedules[handle] = handle
    return handle
  end,
  cancel = function(handle)
    cancelled[#cancelled + 1] = handle
    schedules[handle] = nil
  end,
  log = function() end,
}

dofile("packages/butler/matrix_request.lua")
local matrix = assert(remuda.butler.matrix)

local function request(path)
  local answered
  matrix.request({ method = "GET", path = path }, function(result)
    answered = result or {}
  end)
  return function() return answered end
end

local function find_schedule(name)
  for handle, spec in pairs(schedules) do
    if spec.name == name then return handle, spec end
  end
end

-- 1. The first request uses the initial token and dispatches at once.
local answer_a = request("/_matrix/client/versions")
assert(dispatched == 1, "first request dispatches immediately")

-- 2. The second request queues and arms both the refill and its watchdog.
local answer_b = request("/_matrix/client/v3/account/whoami")
assert(dispatched == 1, "second request waits for a refill token")
local refill_handle, refill_spec = find_schedule("matrix-request-refill")
local watchdog_handle, watchdog_spec = find_schedule("matrix-request-watchdog")
assert(refill_handle and refill_spec, "a refill timer is armed")
assert(watchdog_handle and watchdog_spec, "a watchdog timer is armed")

-- 3. The refill handle disappears (partial reload/failed resume) but the
-- watchdog survives. It must replace the timer and drain the lone item without
-- a third request.
now_ms = 300
schedules[refill_handle] = nil
watchdog_spec.run()
local new_refill_handle, new_refill_spec = find_schedule("matrix-request-refill")
assert(new_refill_handle ~= refill_handle, "the stale refill handle is replaced")
assert(schedules[refill_handle] == nil, "the stale refill is not trusted")
-- The original due time (250) survives replacement: at 300 the replacement
-- must grant immediately rather than wait for a fresh 0.25 s phase.
now_ms = 300
new_refill_spec.run()
assert(dispatched == 2, "the lone queued item drains after the watchdog replaces the timer")
local recovered = answer_b()
assert(type(recovered) == "table" and recovered.status == 200 and not recovered.error,
  "the queued request answered with its 200 result")
local after_recovery = dispatched
new_refill_spec.run()
assert(dispatched == after_recovery, "the replacement does not mint a second token at the same due")

-- 4. A late old refill tick cannot cancel or re-arm the new pump.
local dispatches_before = dispatched
local cancels_before = #cancelled
refill_spec.run()
assert(dispatched == dispatches_before, "a late old refill tick dispatches nothing")
assert(#cancelled == cancels_before, "a late old refill tick cancels nothing")

-- 5. A late old watchdog tick cannot mutate the current pump.
local late_watchdog = watchdog_spec
now_ms = 700
late_watchdog.run()
assert(dispatched == dispatches_before, "a late old watchdog tick dispatches nothing")

-- 6. A dispatch that throws answers the caller conservatively, once.
now_ms = 800
local real_request = remuda.http.request
remuda.http.request = function() error("boom") end
local answer_c = request("/_matrix/client/v3/joined_rooms")
assert(dispatched == dispatches_before, "the throwing request queues behind the empty bucket")
local throw_handle, throw_spec = find_schedule("matrix-request-refill")
assert(throw_handle and throw_spec, "a refill timer is armed for the throwing request")
now_ms = 1100
throw_spec.run()
local thrown = answer_c()
assert(tostring(thrown.error):find("outcome unknown", 1, true),
  "a throwing dispatch resolves the callback as an unknown outcome")
remuda.http.request = real_request

-- 7. Cancelling a queued request resolves it once and never dispatches it,
-- even if a callback from the replaced pumps ticks afterwards.
now_ms = 1400
local before = dispatched
local cancel_callbacks = 0
local cancelling
local handle = matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) cancel_callbacks = cancel_callbacks + 1; cancelling = result end)
-- The registry is handle-keyed, so snapshot the run closures (plus callbacks
-- from earlier replaced pumps) instead of indexing it numerically.
local drain = { refill_spec.run, late_watchdog.run, throw_spec.run }
for _, spec in pairs(schedules) do drain[#drain + 1] = spec.run end
handle.cancel()
assert(cancel_callbacks == 1, "cancel answers the caller exactly once")
assert(tostring(cancelling.error) == "cancelled", "cancel answers the caller")
now_ms = now_ms + 1000
for _, run in ipairs(drain) do run() end
assert(cancel_callbacks == 1, "a cancelled request's callback is never repeated")
assert(dispatched == before, "a cancelled request is never dispatched")

-- 8. Continuous inflow: a healthy refill handle is retained, one credit per
-- 0.25 s tick, and no duplicate timer is armed.
for handle in pairs(schedules) do remuda.cancel(handle) end
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
dispatched = 0
now_ms = 4000
local first = request("/_matrix/client/versions")
assert(dispatched == 1, "fairness first request dispatches immediately")
local first_result = first()
assert(type(first_result) == "table" and first_result.status == 200 and not first_result.error,
  "fairness first request answered")
local queued_answers = {}
for index = 1, 4 do
  queued_answers[index] = request("/_matrix/client/v3/account/whoami")
end
assert(dispatched == 1, "four requests queue behind the empty bucket")
local fair_refill, fair_spec = find_schedule("matrix-request-refill")
local fair_watchdog = find_schedule("matrix-request-watchdog")
assert(fair_refill and fair_watchdog, "one refill and one watchdog are armed")
local before_first = dispatched
fair_spec.run()
assert(dispatched == before_first, "the initial token and a same-instant refill never mint two")
now_ms = now_ms + 250
fair_spec.run()
assert(dispatched == before_first + 1, "the first armed tick at the real due time dispatches one queued item")
local same_refill = select(1, find_schedule("matrix-request-refill"))
assert(same_refill == fair_refill, "a healthy refill handle is retained across enqueue")
-- A new arrival between ticks joins the same queue and the same healthy pump.
local late_answer = request("/_matrix/client/v3/joined_rooms")
assert(dispatched == before_first + 1, "a mid-interval arrival waits for the next due tick")
for _ = 1, 4 do
  now_ms = now_ms + 249
  local handle, spec = find_schedule("matrix-request-refill")
  assert(handle == fair_refill, "the healthy refill handle is not replaced")
  local before_due = dispatched
  spec.run()
  assert(dispatched == before_due, "before the absolute due time no token is minted")
  now_ms = now_ms + 1
  local before = dispatched
  spec.run()
  assert(dispatched == before + 1, "exactly one request dispatches at the due time")
  local repeated = dispatched
  spec.run()
  assert(dispatched == repeated, "a second tick in the same interval mints no second token")
end
assert(dispatched == 6, "all six requests progressed at the 0.25 s cadence")
for index = 1, 4 do
  local value = queued_answers[index]()
  assert(type(value) == "table" and value.status == 200 and not value.error,
    "fairness queued request answered")
end
local late = late_answer()
assert(type(late) == "table" and late.status == 200 and not late.error,
  "the mid-interval arrival answered")

-- 9. A missing scheduler settles the queue before dispatch; it never falls
-- back to an unthrottled network send.
remuda.butler.matrix = {}
remuda.schedule = nil
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
dispatched = 0
local unavailable_first = request("/_matrix/client/versions")
assert(dispatched == 1, "the immediate token still dispatches")
local unavailable_ok = unavailable_first()
assert(type(unavailable_ok) == "table" and unavailable_ok.status == 200 and not unavailable_ok.error,
  "the immediate token dispatches normally")
local unavailable_second = request("/_matrix/client/v3/account/whoami")
local unavailable_result = unavailable_second()
assert(dispatched == 1, "queued request was not sent without a scheduler")
assert(type(unavailable_result) == "table"
  and tostring(unavailable_result.error):find("scheduler is unavailable", 1, true),
  "the queued request settles with a clear pre-write error")

os.remove(config_path)
os.remove(token_path)
print("ok: Matrix request queue replaces stale refill timers, recovers a lone item and keeps fairness")
