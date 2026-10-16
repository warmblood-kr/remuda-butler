-- Exercise actual notice state transitions through existing synthetic cases.
local original_dofile, events = dofile, {}
local observer_broken, last_event = false, nil
dofile = function(path)
  if path == 'packages/butler/notice.lua' then
    remuda._butler_diagnostics = { record = function(subsystem, outcome, reason, correlation)
      assert(subsystem == 'notice')
      assert(type(correlation) == 'string')
      if observer_broken then error('synthetic recorder failure') end
      last_event = { outcome = outcome, reason = reason }
      assert(outcome ~= "delivered" and reason ~= "delivery_ok", "notice must not claim delivery")
      events[reason] = (events[reason] or 0) + 1
    end }
  end
  return original_dofile(path)
end
for _, path in ipairs({ 'tests/butler_notice_retry.lua', 'tests/butler_notice_stall.lua',
    'tests/butler_notice_deferred.lua' }) do dofile(path) end
-- An observed empty composer heuristically completes an existing notice; a busy writer
-- remains deferred across repeated probes without producing duplicate events.
local bus = remuda._butler_notice_config.bus
remuda._butler_prompt_is_empty = function() return "EMPTY", "" end
remuda._butler_notify_policy = function() return true end
remuda.session = function() return { is_busy = false } end
bus.notices.child = { count = 1, message_order = { "synthetic" }, message_ids = { synthetic = "notice" }, reshow = { synthetic = true } }
bus.notice_recoveries.child = { phase = "verify_existing", notice = "notice", message_ids = { "synthetic" }, count = 1 }
assert(remuda._butler_notice.deliver_notice("child"))
assert(bus.notices.child == nil, "heuristic completion clears queue")
assert(last_event.outcome == "observed" and last_event.reason == "heuristic_completion",
  "EMPTY completion must explicitly report a heuristic observation")
bus.notices.child = { count = 1, message_order = { "synthetic" }, message_ids = { synthetic = "notice" }, reshow = { synthetic = true }, text = "notice" }
remuda.type_text = function() error("a session input write is already in flight") end
local busy_before = events.prompt_busy or 0
for _ = 1, 4 do remuda._butler_notice.deliver_notice("child") end
assert((events.prompt_busy or 0) == busy_before + 1, "busy deferral records only its transition")
for _, reason in ipairs({ 'delivery_failed', 'retry_scheduled', 'heuristic_completion' }) do
  assert(events[reason] and events[reason] > 0, 'missing actual notice transition: ' .. reason)
end
-- Identical scenarios retain their control assertions with a broken observer.
observer_broken = true
dofile('tests/butler_notice_retry.lua')
dofile('tests/butler_notice_stall.lua')
dofile = original_dofile
print('diagnostics notice synthetic transitions and recorder isolation: ok')
