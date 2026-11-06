-- Run from the repository root: luajit tests/butler_notice_no_idle_wait.lua
-- Owner decision, 2026-10-19: Claude Code and Codex queue input typed while
-- they work. Owner decision, 2026-11-03: automatic wakeups no longer wait for
-- anything they can predict from the screen or telemetry. One ordinary atomic
-- send per coalesced notice; only the attached/live/instance preflight (and the
-- audited dialog gate for general writes) can refuse.
_butler_session_trace = function() end
local now = 1000
local bus = {
  agents = { lead = { id = "lead-id", kind = "claude", parent = "root", instance_id = "instance-1" } },
  notices = {}, pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {}, notice_seen = {}, unread_seeded = {}, mail_resent = {},
}
local mail = {
  mailbox = function() return {} end, is_unread = function() return true end,
  unread = function() return 1 end, find_message = function() return { from = { alias = "owner", id = "o" } } end,
}
local sends, captures = {}, 0
remuda = {
  _butler_notice_config = {
    bus = bus, resolve = function(n) return n end,
    mail_address = function(n) return { alias = n, id = n } end,
    mail_id = function(n) return n, { alias = n, id = n, kind = "claude" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end,
  },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = { claude = {}, codex = {}, opencode = { placeholders = { "Ask anything…" } } },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = function() end,
  ls = function() return { { name = "lead", alive = true, attached = false, instance_id = "instance-1" } } end,
  capture = function() captures = captures + 1; error("notice delivery must not capture") end,
  capture_styled = function() captures = captures + 1; error("notice delivery must not capture") end,
  session = function() error("notice delivery must not read busy telemetry") end,
  key = function() error("notice delivery must never press a key") end,
  type_text = function() error("notice delivery must use one atomic send") end,
  clear_input = function() error("notice delivery must never clear input") end,
}
dofile("tests/notice_journal_stub.lua")
dofile("packages/butler/notice.lua")
dofile("tests/notice_policy_stub.lua")
remuda._butler_send = function() end
local deliver = remuda._butler_notice.deliver_notice

local function reset(kind)
  bus.agents.lead.kind = kind
  bus.notices.lead = { count = 1, message_order = { "m1" },
    message_ids = { m1 = "Butler message m1 arrived." }, text = "Butler message m1 arrived.",
    kind = kind, delivery_attempts = 0 }
  bus.notice_recoveries, bus.notice_screens, bus.notice_stuck = {}, {}, {}
  sends = {}
  remuda.send = function(name, text) sends[#sends + 1] = { name, text } end
end

-- 1. Every kind sends once without touching the screen or busy telemetry.
for _, kind in ipairs({ "claude", "codex", "opencode" }) do
  for _, telemetry in ipairs({
    function() return { is_busy = true } end,
    function() return { is_busy = false } end,
    function() error("busy unavailable") end,
    function() return nil end,
    function() return {} end,
  }) do
    reset(kind)
    remuda.session = telemetry
    assert(deliver("lead") == true, kind .. ": the notice is sent without an idle wait")
    assert(#sends == 1 and bus.notices.lead == nil, kind .. ": exactly one send, queue cleared")
  end
end
remuda.session = function() error("notice delivery must not read busy telemetry") end
assert(captures == 0, "no screen capture in any case")

-- 2. Retry-after-failed-write and legacy probe records do not delay the send.
for _, kind in ipairs({ "claude", "codex", "opencode" }) do
  reset(kind)
  bus.notices.lead.delivery_attempts = 2
  bus.notice_recoveries.lead = { phase = "probe", message_ids = { "m1" }, started_at = now - 500 }
  assert(deliver("lead") == true, kind .. ": a legacy probe record is ignored")
  assert(#sends == 1 and bus.notice_recoveries.lead == nil, kind .. ": one send, no recovery state")
end

-- 3. Attachment is not an admission gate: one atomic send, no deferral.
reset("claude")
remuda.ls = function() return { { name = "lead", alive = true, attached = true, instance_id = "instance-1" } } end
assert(deliver("lead") == true, "an attached pane receives the notice")
assert(#sends == 1, "an attached pane receives exactly one send")
assert(bus.notices.lead == nil, "the attached delivery completes")
remuda.ls = function() return { { name = "lead", alive = true, attached = false, instance_id = "instance-1" } } end

-- 4. A first task still owns the pane: that is a task-state guard, not a
-- composer prediction, and it keeps the notice queued.
reset("codex")
bus.pending_tasks.lead = true
assert(deliver("lead") == false and #sends == 0, "a pending first task keeps the notice queued")
bus.pending_tasks.lead = nil
assert(deliver("lead") == true and #sends == 1, "the notice sends once the task state clears")
print("ok - automatic notices never wait for idle or read the screen")
