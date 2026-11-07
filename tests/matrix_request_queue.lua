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
  schedules = {},
  clock = function() return now_ms end,
  -- Opaque, non-key registry: a real core does not key remuda.schedules by
  -- the returned handle, so the fixture must not rely on direct indexing.
  schedule = function(spec)
    local handle = { run = spec.run, every = spec.every, name = spec.name }
    schedules[#schedules + 1] = handle
    return handle
  end,
  cancel = function(handle)
    cancelled[#cancelled + 1] = handle
    for index = #schedules, 1, -1 do
      if schedules[index] == handle then table.remove(schedules, index) end
    end
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
  for _, spec in ipairs(schedules) do
    if spec.name == name then return spec, spec end
  end
end

local function has_schedule(handle)
  for _, current in ipairs(schedules) do
    if current == handle then return true end
  end
  return false
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
assert(remuda.schedules[refill_handle] == nil,
  "the public registry is not keyed by the returned handle")

-- 3. The refill closure stops ticking while its handle remains. Registry
-- membership is not liveness evidence; only elapsed monotonic time may declare
-- it stale, then the watchdog replaces it and keeps the original due.
now_ms = 2500
local stale_cancels = #cancelled
watchdog_spec.run()
local new_refill_handle, new_refill_spec = find_schedule("matrix-request-refill")
assert(new_refill_handle ~= refill_handle, "the stale refill handle is replaced")
assert(#cancelled == stale_cancels + 1 and cancelled[#cancelled] == refill_handle,
  "the stale handle itself is cancelled")
-- The original due time (250) survives replacement.
now_ms = 2500
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
now_ms = 2600
late_watchdog.run()
assert(dispatched == dispatches_before, "a late old watchdog tick dispatches nothing")

-- 6. A dispatch that throws answers the caller conservatively, once.
local real_request = remuda.http.request
now_ms = 3000
remuda.http.request = function() error("boom") end
local answer_c = request("/_matrix/client/v3/joined_rooms")
assert(dispatched == dispatches_before, "the throwing request queues behind the empty bucket")
local throw_handle, throw_spec = find_schedule("matrix-request-refill")
assert(throw_handle and throw_spec, "a refill timer is armed for the throwing request")
now_ms = 3400
throw_spec.run()
local thrown = answer_c()
assert(tostring(thrown.error):find("outcome unknown", 1, true),
  "a throwing dispatch resolves the callback as an unknown outcome")
remuda.http.request = real_request

-- 7. Cancelling a queued request resolves it once and never dispatches it,
-- even if a callback from the replaced pumps ticks afterwards.
now_ms = 4000
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
for index = #schedules, 1, -1 do remuda.cancel(schedules[index]) end
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
dispatched = 0
now_ms = 8000
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
local healthy_cancels = #cancelled
for _ = 1, 4 do
  assert(#cancelled == healthy_cancels, "a healthy pump adds no cancel before it drains")
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

-- 9. A write that may have reached the homeserver is typed uncertain when the
-- dispatch throws, and a late transport callback cannot settle it twice.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
local write_puts, write_callbacks, late_write = 0, 0, nil
remuda.http.request = function(spec)
  write_puts = write_puts + 1
  late_write = spec.callback
  error("boom after side effect")
end
local write_result
matrix.request_json({ method = "PUT",
  path = "/_matrix/client/v3/rooms/!room:example.org/send/m.room.message/tx1",
  body = "{}" }, function(result) write_callbacks = write_callbacks + 1; write_result = result end)
assert(write_puts == 1, "the write is attempted once")
assert(write_callbacks == 1, "the throwing write settles once")
assert(type(write_result) == "table" and write_result.uncertain == true
  and tostring(write_result.error):find("outcome unknown", 1, true),
  "a throwing write reports an uncertain outcome")
-- The transport still calls back late with success: finish-once keeps the
-- uncertain result, and no retry is scheduled.
late_write({ status = 200, headers = {}, body = "{}" })
now_ms = now_ms + 1000
local write_pending = {}
for _, spec in pairs(schedules) do write_pending[#write_pending + 1] = spec.run end
for _, run in ipairs(write_pending) do run() end
assert(write_callbacks == 1, "a late write callback cannot settle the request twice")
assert(type(write_result) == "table" and write_result.uncertain == true,
  "the uncertain write result is retained")
assert(write_puts == 1, "a late write callback causes no retry")
remuda.http.request = real_request

-- 10. Cancelling a dispatched write latches uncertainty BEFORE transport.cancel;
-- an inline generic error from the transport cannot replace that result.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
local cancel_puts, cancel_calls, cancel_callbacks, cancel_late = 0, 0, 0, nil
remuda.http.request = function(spec)
  cancel_puts = cancel_puts + 1
  cancel_late = spec.callback
  return { cancel = function()
    cancel_calls = cancel_calls + 1
    if type(cancel_late) == "function" then cancel_late({ error = "transport cancelled" }) end
  end }
end
local cancel_result
local write_handle = matrix.request_json({ method = "POST",
  path = "/_matrix/client/v3/rooms/!room:example.org/send/m.room.message/tx2",
  body = "{}" }, function(result)
    cancel_callbacks = cancel_callbacks + 1; cancel_result = result
  end)
assert(cancel_puts == 1, "the write dispatches")
write_handle.cancel()
assert(cancel_calls == 1, "the transport cancel is requested")
assert(cancel_callbacks == 1, "cancel settles the write exactly once")
assert(type(cancel_result) == "table" and cancel_result.uncertain == true
  and tostring(cancel_result.error) == "cancelled",
  "the latched uncertain cancellation wins over the inline error")
cancel_late({ status = 200, headers = {}, body = "{}" })
assert(cancel_callbacks == 1 and cancel_result.uncertain == true,
  "a late success cannot replace the uncertain cancellation")
now_ms = now_ms + 1000
local cancel_pending = {}
for _, spec in pairs(schedules) do cancel_pending[#cancel_pending + 1] = spec.run end
for _, run in ipairs(cancel_pending) do run() end
assert(cancel_puts == 1, "no retry after a cancelled write")
remuda.http.request = real_request

-- 11. A caller callback that throws is contained: the request settles once and
-- the module keeps serving later work.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
local throwing_calls = 0
matrix.request({ method = "GET", path = "/_matrix/client/versions" },
  function() throwing_calls = throwing_calls + 1; error("callback boom") end)
assert(throwing_calls == 1, "the throwing callback ran once")
local next_result
matrix.request({ method = "GET", path = "/_matrix/client/v3/joined_rooms" },
  function(result) next_result = result end)
now_ms = now_ms + 250
local next_pending = {}
for _, spec in pairs(schedules) do next_pending[#next_pending + 1] = spec.run end
for _, run in ipairs(next_pending) do run() end
assert(type(next_result) == "table" and next_result.status == 200 and not next_result.error,
  "a throwing callback does not stall the next request")

-- 12. Retiring a generation settles queued-not-dispatched work once, cancels
-- both exact timers, refuses old enqueue, and cannot be revived by old ticks.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
dispatched = 0
local first_answer = request("/_matrix/client/versions")
assert(dispatched == 1, "the initial token dispatches")
local retired_answers = {}
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) retired_answers[1] = result end)
matrix.request({ method = "GET", path = "/_matrix/client/v3/joined_rooms" },
  function(result) retired_answers[2] = result end)
local retire_refill, retire_refill_spec = find_schedule("matrix-request-refill")
local retire_watchdog, retire_watchdog_spec = find_schedule("matrix-request-watchdog")
assert(retire_refill and retire_watchdog, "both timers are armed before retirement")
local cancel_before = #cancelled
matrix.request_retire()
assert(#cancelled == cancel_before + 2, "retire cancels exactly both timers")
assert(not has_schedule(retire_refill) and not has_schedule(retire_watchdog),
  "both retired handles are gone")
for index = 1, 2 do
  local value = retired_answers[index]
  assert(type(value) == "table" and value.queue_retired == true and value.not_sent == true
    and tostring(value.error):find("generation ended", 1, true),
    "queued request settles once with the typed pre-dispatch result")
end
local after_retire = dispatched
retire_refill_spec.run()
retire_watchdog_spec.run()
assert(dispatched == after_retire, "late old ticks dispatch nothing")
local refused_count = 0
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) refused_count = refused_count + 1; retired_answers[3] = result end)
assert(refused_count == 1 and retired_answers[3].not_sent == true,
  "old enqueue is refused with the typed result")
assert(dispatched == after_retire, "old enqueue sends nothing")
-- Resume republishes the same client: the queue is empty, but the rate state
-- (tokens and the absolute due) is preserved, so a new request waits for it.
matrix.request_resume()
local resumed
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) resumed = result end)
assert(dispatched == after_retire, "resume preserves the empty token bucket")
local resumed_refill = find_schedule("matrix-request-refill")
now_ms = now_ms + 249
resumed_refill.run()
assert(dispatched == after_retire, "the preserved deadline mints nothing at +249")
now_ms = now_ms + 1
resumed_refill.run()
assert(dispatched == after_retire + 1 and type(resumed) == "table"
  and resumed.status == 200 and not resumed.error,
  "the preserved deadline mints one credit at +250")
assert(#retired_answers == 3, "resume does not replay retired callbacks")

-- The captured JSON wrapper stays on its own generation: replacing the public
-- helper must not send a retired request through the new client.
matrix.request_retire()
local old_json = matrix.request_json
local stray = 0
matrix.request = function() stray = stray + 1; error("new client must not see the retired wrapper") end
local captured_result
old_json({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) captured_result = result end)
assert(stray == 0, "the captured JSON wrapper does not call the replaced request")
assert(type(captured_result) == "table" and captured_result.not_sent == true,
  "the captured wrapper returns the typed retired result")
matrix.request_resume()
local wrapper_before = dispatched
local fresh_result
matrix.request_json({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) fresh_result = result end)
assert(dispatched == wrapper_before, "the resumed wrapper waits for the preserved due")
local wrapper_refill = find_schedule("matrix-request-refill")
now_ms = now_ms + 250
wrapper_refill.run()
assert(type(fresh_result) == "table" and fresh_result.status == 200 and not fresh_result.error,
  "the resumed client JSON wrapper answers 200 at the preserved due")

-- Repeated resume on a live generation must not drop active handles.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
dispatched = 0
request("/_matrix/client/versions")
local live_answer
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) live_answer = result end)
local live_refill, live_refill_spec = find_schedule("matrix-request-refill")
local live_watchdog = find_schedule("matrix-request-watchdog")
assert(live_refill and live_watchdog, "the live queue has both timers")
matrix.request_resume()
matrix.request_resume()
assert(has_schedule(live_refill) and has_schedule(live_watchdog),
  "repeated resume keeps both live handles")
now_ms = now_ms + 250
live_refill_spec.run()
assert(type(live_answer) == "table" and live_answer.status == 200 and not live_answer.error,
  "the live queue still dispatches after idempotent resume")

-- 13. A throwing retired callback cannot strand the remaining queued items.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
dispatched = 0
request("/_matrix/client/versions")
local settled = 0
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function() settled = settled + 1; error("retired callback boom") end)
matrix.request({ method = "GET", path = "/_matrix/client/v3/joined_rooms" },
  function() settled = settled + 1 end)
matrix.request_retire()
assert(settled == 2, "both queued callbacks settle despite the first throwing")

-- 14. Cancelling a dispatched write after its generation retired still settles
-- once as uncertain; there is no replay or second transport call.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
local after_retire_puts, after_retire_cancel_calls, after_retire_callbacks = 0, 0, 0
local after_retire_callback, late_cancel
remuda.http.request = function(spec)
  after_retire_puts = after_retire_puts + 1
  late_cancel = spec.callback
  return { cancel = function()
    after_retire_cancel_calls = after_retire_cancel_calls + 1
    if type(late_cancel) == "function" then
      late_cancel({ status = 200, headers = {}, body = "{}" })
    end
  end }
end
local write = matrix.request_json({ method = "PUT",
  path = "/_matrix/client/v3/rooms/!room:example.org/send/m.room.message/tx3",
  body = "{}" }, function(result)
    after_retire_callbacks = after_retire_callbacks + 1
    after_retire_callback = result
  end)
assert(after_retire_puts == 1, "the write dispatches before retirement")
matrix.request_retire()
write.cancel()
assert(after_retire_callbacks == 1, "the cancelled write settles exactly once")
assert(after_retire_cancel_calls == 1, "the dispatched transport is cancelled once")
assert(type(after_retire_callback) == "table" and after_retire_callback.uncertain == true
  and tostring(after_retire_callback.error) == "cancelled",
  "a cancel after retirement settles once as uncertain")
late_cancel({ status = 200, headers = {}, body = "{}" })
assert(after_retire_callbacks == 1, "a late success cannot call the callback again")
assert(type(after_retire_callback) == "table" and after_retire_callback.uncertain == true,
  "a late success cannot replace the uncertain cancellation")
now_ms = now_ms + 1000
local after_pending = {}
for _, spec in pairs(schedules) do after_pending[#after_pending + 1] = spec.run end
for _, run in ipairs(after_pending) do run() end
assert(after_retire_puts == 1, "no replay or second transport call")
remuda.http.request = real_request

-- 15. Retire observes timer-cancel failures, retains the exact handles, and
-- retries them without resettling queued work; resume fails closed until clean.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
dispatched = 0
request("/_matrix/client/versions")
local observed_queue
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) observed_queue = result end)
local observed_state = remuda._butler_matrix_request_state()
local observed_refill, observed_watchdog = observed_state.timer, observed_state.watchdog
assert(observed_refill and observed_watchdog, "both timers armed before retirement")
local real_cancel = remuda.cancel
remuda.cancel = function(handle)
  if handle == observed_refill then error("refill cancel boom") end
  if handle == observed_watchdog then return false end
  return real_cancel(handle)
end
local retired = matrix.request_retire()
assert(retired.ok == false and retired.retired == true and retired.queued_settled == 1,
  "retire reports cancel failures and settles queued work once")
assert(type(retired.cancel_failed) == "table" and #retired.cancel_failed == 2,
  "both failed roles are reported")
assert(type(retired.detail) == "string" and #retired.detail > 0, "retire carries a detail")
assert(type(observed_queue) == "table" and observed_queue.not_sent == true,
  "queued work still settles typed despite cancel failures")
local pending = remuda._butler_matrix_request_state().cancel_pending
assert(type(pending) == "table" and #pending == 2, "failed exact handles are retained")
local retried = matrix.request_retire()
assert(retried.ok == false and retried.queued_settled == 0,
  "a repeated retire retries but never resettles queued work")
local refused = matrix.request_resume()
assert(refused.ok == false and refused.resumed == false and refused.retired == true,
  "resume refuses a degraded generation and stays fenced")
assert(dispatched == 1, "a refused resume dispatches nothing")
remuda.cancel = real_cancel
local recovered = matrix.request_retire()
assert(recovered.ok == true and #recovered.cancel_failed == 0,
  "retire retries the exact pending handles once cancellation works")
assert(remuda._butler_matrix_request_state().cancel_pending == nil,
  "confirmed cancels clear the pending set")
local resumed = matrix.request_resume()
assert(resumed.ok == true and resumed.resumed == true and resumed.retired == false,
  "resume succeeds only after cleanup is confirmed")

-- 16. The same captured client keeps its rate state across retire/resume:
-- EMPTY means the queue only. Repeated live resume is idempotent and mints no
-- extra credit; a fresh new module client is the separate initial-burst case.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
dispatched = 0
request("/_matrix/client/versions")
local settled_second
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) settled_second = result end)
local epoch_retire = matrix.request_retire()
assert(epoch_retire.ok == true and epoch_retire.queued_settled == 1
  and #epoch_retire.cancel_failed == 0 and settled_second.not_sent == true,
  "retire settles the queued second once with a clean role array")
local epoch_resume = matrix.request_resume()
assert(epoch_resume.ok == true and epoch_resume.resumed == true
  and epoch_resume.retired == false and #epoch_resume.cancel_failed == 0,
  "resume republishes the same client")
local fresh
matrix.request({ method = "GET", path = "/_matrix/client/versions" },
  function(result) fresh = result end)
assert(dispatched == 1, "resume preserves the empty token bucket; the request queues")
local live_handle = remuda._butler_matrix_request_state().timer
local live_spec = find_schedule("matrix-request-refill")
local live_resume = matrix.request_resume()
assert(live_resume.ok == true and live_resume.resumed == false
  and live_resume.retired == false, "repeated live resume is idempotent")
assert(remuda._butler_matrix_request_state().timer == live_handle,
  "repeated live resume keeps the active deadline handle")
now_ms = now_ms + 249
live_spec.run()
assert(dispatched == 1 and fresh == nil, "the preserved deadline mints nothing at +249")
now_ms = now_ms + 1
live_spec.run()
assert(dispatched == 2 and fresh.status == 200,
  "the preserved deadline mints exactly one credit at +250")

-- 17. A queue_retired callback cannot reactivate or replace the client while
-- the outer teardown is still running.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
dispatched = 0
request("/_matrix/client/versions")
local nested = {}
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result)
    nested.first_result = result
    local resumed = matrix.request_resume()
    nested.resume_ok, nested.resume_resumed, nested.resume_retired =
      resumed.ok, resumed.resumed, resumed.retired
    local retired_again = matrix.request_retire()
    nested.retire_ok, nested.retire_retired = retired_again.ok, retired_again.retired
    local new_request
    matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
      function(value) new_request = value end)
    nested.new_not_sent = new_request and new_request.not_sent
    local ok, err = pcall(dofile, "packages/butler/matrix_request.lua")
    nested.reexec_ok = ok
    nested.reexec_refused = tostring(err):find("helper replacement refused", 1, true) ~= nil
  end)
matrix.request({ method = "GET", path = "/_matrix/client/v3/joined_rooms" },
  function(result) nested.second_result = result end)
local outer = matrix.request_retire()
assert(outer.ok == true and outer.retired == true and outer.queued_settled == 2,
  "the outer retire still settles both queued items exactly once")
assert(nested.first_result.not_sent == true and nested.second_result.not_sent == true,
  "every queued callback receives the typed retirement")
assert(nested.resume_ok == false and nested.resume_resumed == false
  and nested.resume_retired == true,
  "a nested resume reports the in-progress phase, not clean success")
assert(nested.retire_ok == false and nested.retire_retired == true,
  "a nested retire reports the in-progress phase")
assert(nested.new_not_sent == true,
  "a nested new request is refused with the typed retirement")
assert(nested.reexec_ok == false and nested.reexec_refused == true,
  "a nested helper replacement is refused")
assert(dispatched == 1, "reentrant calls send nothing")
local settled_state = remuda._butler_matrix_request_state()
assert(settled_state.phase == nil and settled_state.retired == true,
  "the phase clears and the generation stays retired")
local resumed_after = matrix.request_resume()
assert(resumed_after.ok == true and resumed_after.resumed == true,
  "a real resume works after the teardown completes")
local live
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) live = result end)
assert(dispatched == 1, "the preserved bucket still waits for its due")
now_ms = now_ms + 250
local live_spec = find_schedule("matrix-request-refill")
live_spec.run()
assert(dispatched == 2 and live.status == 200,
  "one credit dispatches the post-teardown request")

-- 18. Cancel advice that reenters the public API during retire (and during a
-- pending-cancel retry) gets the busy phase, never a clean completion.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
dispatched = 0
request("/_matrix/client/versions")
local advice = {}
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function(result) advice.settled = result end)
local real_cancel = remuda.cancel
remuda.cancel = function(handle)
  local nested_resume = matrix.request_resume()
  local nested_retire = matrix.request_retire()
  advice.resume_ok, advice.resume_resumed, advice.resume_detail =
    nested_resume.ok, nested_resume.resumed, nested_resume.detail
  advice.retire_ok, advice.retire_detail = nested_retire.ok, nested_retire.detail
  return real_cancel(handle)
end
local first = matrix.request_retire()
assert(first.ok == true and first.queued_settled == 1,
  "cancel advice does not break the outer retirement")
assert(advice.resume_ok == false and advice.resume_resumed == false
  and advice.resume_detail == "transition busy",
  "cancel-advice resume reports the busy phase")
assert(advice.retire_ok == false and advice.retire_detail == "transition busy",
  "cancel-advice retire reports the busy phase")
assert(advice.settled.not_sent == true and dispatched == 1,
  "cancel advice sends nothing and the queued item still settles")

-- Pending-cancel retry is also guarded: the cancel advice reenters the retry.
remuda.butler.matrix = {}
dofile("packages/butler/matrix_request.lua")
matrix = assert(remuda.butler.matrix)
now_ms = now_ms + 1000
dispatched = 0
request("/_matrix/client/versions")
matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
  function() end)
local retry_target = remuda._butler_matrix_request_state().timer
remuda.cancel = function(handle)
  if handle == retry_target then return false end
  return real_cancel(handle)
end
local failed_retire = matrix.request_retire()
assert(failed_retire.ok == false and #failed_retire.cancel_failed == 1,
  "the first retire leaves one pending cancel")
remuda.cancel = function(handle)
  local nested_resume = matrix.request_resume()
  local nested_retire = matrix.request_retire()
  advice.retry_resume_ok = nested_resume.ok
  advice.retry_retire_ok = nested_retire.ok
  advice.retry_detail = nested_retire.detail
  return real_cancel(handle)
end
local retried = matrix.request_retire()
assert(retried.ok == true and retried.queued_settled == 0,
  "the repeated retire retries the exact pending handle")
assert(advice.retry_resume_ok == false and advice.retry_retire_ok == false
  and advice.retry_detail == "transition busy",
  "cancel advice during the retry reports the busy phase")
assert(dispatched == 1, "the retry path sends nothing")

-- 19. A bare helper replacement validates the prior retirement strictly
-- before publishing; a refusal keeps the old public API and sends nothing.
local function load_request_module()
  remuda.butler.matrix = {}
  dofile("packages/butler/matrix_request.lua")
  return assert(remuda.butler.matrix)
end
local function expect_refused(retire, label)
  local current = load_request_module()
  local old_request = current.request
  local before = dispatched
  current.request_retire = retire
  local ok, err = pcall(dofile, "packages/butler/matrix_request.lua")
  assert(not ok and tostring(err):find("helper replacement refused", 1, true),
    label .. " refuses the replacement")
  assert(current.request == old_request, label .. " keeps the old public API")
  assert(dispatched == before, label .. " sends nothing")
end
dispatched = 0
expect_refused(function() error("boom") end, "a throwing prior retire")
expect_refused(function()
  return { ok = false, retired = true, queued_settled = 0, cancel_failed = {} }
end, "a failed prior retire")
expect_refused(function() return {} end, "a malformed prior retire")
expect_refused(function()
  return { ok = true, retired = true, queued_settled = 0, cancel_failed = { "refill" } }
end, "a non-empty cancel_failed on success")
expect_refused(function()
  return { ok = true, retired = true, queued_settled = -1, cancel_failed = {} }
end, "a negative queued_settled")
expect_refused(function()
  return { ok = true, retired = true, queued_settled = 0, cancel_failed = {},
    detail = string.rep("x", 300) }
end, "an unbounded detail")
local replaced = load_request_module()
local old_request = replaced.request
replaced.request_retire = function()
  return { ok = true, retired = true, queued_settled = 0, cancel_failed = {}, detail = "clean" }
end
assert(dofile("packages/butler/matrix_request.lua"))
assert(replaced.request ~= old_request, "a clean prior retirement allows replacement")
assert(dispatched == 0, "a clean replacement sends nothing")

-- 20. A missing scheduler settles the queue before dispatch; it never falls
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
print("ok: Matrix request queue replaces stale refill timers, recovers a lone item, keeps fairness, and types write uncertainty")
