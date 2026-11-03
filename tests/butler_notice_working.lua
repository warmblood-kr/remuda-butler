-- Run from the repository root: luajit tests/butler_notice_working.lua
-- Automatic mailbox wakeups do not read the screen at all. A working/animated
-- pane, a ghost suggestion, a real draft and an open dialog are all one atomic
-- send: the owner accepted detached-draft concatenation (2026-11-03) and kept
-- only the attached-human and live/identity preflights. The core's writer-busy
-- refusal is still bounded and keeps the mail queued.
local function read(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end
local FX = "tests/fixtures/notice-working/"
local working = read(FX .. "claude-2.1.300-working-empty.txt")
local spinner2 = working:gsub("12s", "13s")
local draft = read(FX .. "claude-2.1.300-working-draft.txt")
local codex = read(FX .. "codex-0.162.1-working-empty.txt")
local approval = "Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"

local now = 1000
local trace = {}
_butler_session_trace = function(event, detail) trace[#trace + 1] = { event = event, detail = detail } end
local bus = {
  agents = { lead = { id = "lead-id", kind = "claude", parent = "root" } },
  notices = {}, pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {}, mail_resent = {},
  notice_seen = {}, unread_seeded = {},
}
local mail = {
  mailbox = function() return {} end, is_unread = function() return true end,
  unread = function() return 1 end, find_message = function() return { from = { alias = "alice", id = "a" } } end,
}
local screens, calls, sends, sent = {}, 0, {}, {}
remuda = {
  _butler_notice_config = {
    bus = bus, resolve = function(n) return n end,
    mail_address = function(n) return { alias = n, id = n } end,
    mail_id = function(n) return n, { alias = n, id = n, kind = "claude" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end,
  },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = { claude = {}, codex = { placeholders = { "Ask Codex to do anything" } } },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = _butler_session_trace,
  ls = function() return { { name = "lead", alive = true, attached = false } } end,
  -- Notice delivery must never consult the screen or the busy/status probes.
  capture = function() calls = calls + 1; error("notice delivery must not capture the screen") end,
  capture_styled = function() calls = calls + 1; error("notice delivery must not capture the screen") end,
  session = function() error("notice delivery must not read busy telemetry") end,
  key = function() error("notice delivery must never press a key") end,
  type_text = function() error("notice delivery must use one atomic send") end,
}
dofile("packages/butler/notice.lua")
remuda._butler_send = function(_, to, body) sent[#sent + 1] = { to, body } end
local deliver = remuda._butler_notice.deliver_notice

local function reset(screen, kind)
  screens, calls, sends = { screen }, 0, {}
  bus.agents.lead.kind = kind or "claude"
  bus.notices.lead = { count = 1, message_order = { "m1" },
    message_ids = { m1 = "Butler message m1 arrived." }, text = "Butler message m1 arrived.",
    kind = bus.agents.lead.kind }
  bus.notice_recoveries, bus.notice_screens, bus.notice_stuck = {}, {}, {}
  remuda.send = function(name, text) sends[#sends + 1] = { name = name, text = text } end
end

-- 1. Working, animating, draft, ghost and dialog screens: exactly one send each.
for _, case in ipairs({
  { working, "claude", "working Claude pane" },
  { spinner2, "claude", "animating spinner" },
  { draft, "claude", "real draft (owner accepted concatenation)" },
  { approval, "claude", "open approval dialog (no modal prediction)" },
  { codex, "codex", "working Codex pane" },
}) do
  reset(case[1], case[2])
  assert(deliver("lead") == true, case[3] .. ": the notice is sent")
  assert(#sends == 1 and sends[1].name == "lead", case[3] .. ": one core send")
  assert(sends[1].text:find("Butler message m1", 1, true), case[3] .. ": the notice text is sent")
  assert(bus.notices.lead == nil, case[3] .. ": transport acceptance clears the queue")
  assert(calls == 0, case[3] .. ": no screen capture")
end

-- 2. No probe state, no verification check budget, no Return retry.
reset(working)
bus.notice_recoveries.lead = { phase = "probe", count = 1, message_ids = { "m1" }, started_at = now - 999 }
deliver("lead")
assert(#sends == 1, "a legacy probe record cannot delay the atomic send")
assert(bus.notice_recoveries.lead == nil, "no recovery state is created")
assert(not bus.notice_fallbacks.lead, "no fallback retry state is created")

-- 3. Writer busy: one-second recheck, no spent attempt, mail retained, and the
--    busy cap still opens the stuck record with a truthful reason.
reset(working)
local busy_sends = 0
remuda.send = function()
  busy_sends = busy_sends + 1
  error("session input is busy; nothing was written, retry", 0)
end
deliver("lead")
assert(busy_sends == 1 and bus.notices.lead.due_at == now + 1, "busy rechecks in one second")
assert(bus.notices.lead.delivery_attempts == nil, "busy spends no delivery attempt")
for _ = 1, 901 do now = now + 1; deliver("lead") end
assert(bus.notice_stuck.lead and tostring(bus.notice_stuck.lead.reason):find("busy", 1, true),
  "the busy cap opens the stuck record with the busy reason")
assert(bus.notices.lead, "the mail stays queued while the writer is busy")
assert(#sent == 0, "no sender failure mail for a busy writer")
-- Once the writer frees, the same notice sends exactly once.
remuda.send = function(name, text) sends[#sends + 1] = { name = name, text = text } end
now = now + 1
deliver("lead")
assert(#sends == 1 and bus.notices.lead == nil, "the retained notice sends when the writer frees")

-- 4. Attachment refusal never writes and never fabricates delivery.
reset(working)
remuda.ls = function() return { { name = "lead", alive = true, attached = true } } end
sends = {}
deliver("lead")
assert(#sends == 0, "an attached human receives nothing")
assert(bus.notices.lead and bus.notices.lead.due_at == now + 1, "attachment waits for a later recheck")
remuda.ls = function() return { { name = "lead", alive = true, attached = false } } end

-- 5. A live pane whose send outcome is unconfirmed is reported, never claimed.
reset(working)
bus.notice_uncertain_alerts, sent = {}, {}
sends = {}
remuda.send = function() error("text is still being written to a slow pane; Return follows when it lands", 0) end
deliver("lead")
assert(#sends == 0 and bus.notices.lead == nil and bus.notice_stuck.lead,
  "an uncertain outcome opens the stuck record without retrying")
local alert
for _, row in ipairs(sent) do if row[1] == "alice" then alert = row end end
assert(alert and alert[2]:find("Could not confirm", 1, true), "the sender hears the truth")
print("ok - working, animated, draft and dialog screens no longer gate automatic notices")
