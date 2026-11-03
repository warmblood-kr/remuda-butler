-- Exercise actual notice state transitions through the standalone suites.
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
    'tests/butler_notice_no_idle_wait.lua' }) do dofile(path) end
-- The suites above leave a live notice module and bus. Drive each transport
-- boundary directly: accepted, uncertain, busy deferral and attachment.
local bus = remuda._butler_notice_config.bus
local N = remuda._butler_notice
local function queue()
  bus.notices.lead = { count = 1, message_order = { "synthetic" },
    message_ids = { synthetic = "Butler message synthetic" }, text = "Butler message synthetic" }
  bus.notice_recoveries, bus.notice_stuck, bus.notice_uncertain_alerts = {}, {}, {}
  bus.notice_failure_alerts = {}
end
remuda.ls = function() return { { name = "lead", alive = true, attached = false, instance_id = "instance-1" } } end
bus.agents.lead.instance_id = "instance-1"

queue()
remuda.send = function() return nil end
assert(N.deliver_notice("lead"))
assert(last_event.outcome == "submitted" and last_event.reason == "transport_accepted",
  "a transport-accepted notice is labelled submitted/transport_accepted, never delivered")

queue()
remuda.send = function() error("text may be in the pane, but submission is unconfirmed.", 0) end
assert(N.deliver_notice("lead") == false)
assert(last_event.outcome == "error" and last_event.reason == "delivery_uncertain",
  "an uncertain outcome is recorded as an error, not a delivery")
assert(bus.notice_stuck.lead, "uncertainty opens the stuck record")

queue()
remuda.send = function() error("session input is busy; nothing was written, retry", 0) end
local busy_before = events.prompt_busy or 0
for _ = 1, 4 do N.deliver_notice("lead") end
assert((events.prompt_busy or 0) == busy_before + 1, "busy deferral records only its transition")

queue()
remuda.ls = function() return { { name = "lead", alive = true, attached = true, instance_id = "instance-1" } } end
remuda.send = function() error("must not be called") end
local attached_before = events.human_attached or 0
assert(N.deliver_notice("lead") == false)
assert((events.human_attached or 0) == attached_before + 1, "attachment is reported as a deferral, not a delivery")

for _, reason in ipairs({ 'delivery_failed', 'retry_scheduled', 'transport_accepted',
    'delivery_uncertain', 'prompt_busy', 'human_attached' }) do
  assert(events[reason] and events[reason] > 0, 'missing actual notice transition: ' .. reason)
end
-- Identical scenarios retain their control assertions with a broken observer.
observer_broken = true
dofile('tests/butler_notice_retry.lua')
dofile('tests/butler_notice_stall.lua')
dofile('tests/butler_notice_no_idle_wait.lua')
dofile = original_dofile
print('diagnostics notice transport transitions and recorder isolation: ok')
