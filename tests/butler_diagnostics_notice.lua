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
local queue_id = 0
local function queue()
  queue_id = queue_id + 1
  local id = "synthetic" .. queue_id
  bus.notices.lead = { count = 1, message_order = { id },
    message_ids = { [id] = "Butler message " .. id }, text = "Butler message " .. id }
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

-- Attachment itself is not a gate; a core transport refusal is the explicit,
-- non-uncertain reason that defers.
queue()
remuda.ls = function() return { { name = "lead", alive = true, attached = true, instance_id = "instance-1" } } end
remuda.send = function() error("a human is attached to this session", 0) end
local attach_before = events.attach_refused or 0
assert(N.deliver_notice("lead") == false)
assert((events.attach_refused or 0) == attach_before + 1,
  "a core attachment transport refusal is reported explicitly, not as a policy gate")

for _, reason in ipairs({ 'delivery_failed', 'retry_scheduled', 'transport_accepted',
    'delivery_uncertain', 'prompt_busy', 'attach_refused' }) do
  assert(events[reason] and events[reason] > 0, 'missing actual notice transition: ' .. reason)
end
-- Identical scenarios retain their control assertions with a broken observer.
observer_broken = true
dofile('tests/butler_notice_retry.lua')
dofile('tests/butler_notice_stall.lua')
dofile('tests/butler_notice_no_idle_wait.lua')
dofile = original_dofile
print('diagnostics notice transport transitions and recorder isolation: ok')
