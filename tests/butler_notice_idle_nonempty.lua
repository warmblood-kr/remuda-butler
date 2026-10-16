-- Run from the repository root: luajit tests/butler_notice_idle_nonempty.lua
-- Idle garbled composers must not trap mail in probe timeout/backoff.
local now = 1000
_butler_session_trace = function() end
local bus = {
  agents = { lead = { id = "lead-id", kind = "claude", parent = "root" } },
  notices = {}, pending_tasks = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  codex_update_relaunches = {}, codex_update_state = {},
}
local mail = {
  mailbox = function() return {} end, is_unread = function() return true end,
  unread = function() return 1 end, find_message = function() return { from = { alias = "alice", id = "a" } } end,
}
local frames, calls, typed, sent = {}, 0, {}, {}
remuda = {
  _butler_notice_config = {
    bus = bus, resolve = function(n) return n end,
    mail_address = function(n) return { alias = n, id = n } end,
    mail_id = function(n) return n, { alias = n, id = n, kind = "claude" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end,
  },
  _butler_chooser = { known_startup_modal = function() return remuda._test_modal() end },
  _test_modal = function() return false end,
  _butler_agent_startup = { claude = {}, codex = { placeholders = { "Ask Codex to do anything" } } },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = function() end,
  ls = function() return { { name = "lead", alive = true, attached = false } } end,
  capture = function() calls = calls + 1; return frames[math.min(calls, #frames)] end,
  session = function() return { is_busy = false } end,
  type_text = function(_, text) typed[#typed + 1] = text; return "submitted" end,
  _butler_send = function(_, to, body) sent[#sent + 1] = { to, body } end,
}
dofile("packages/butler/notice.lua")
local deliver = remuda._butler_notice.deliver_notice
local idle, busy, alive, modal, replaced = math.huge, false, true, false, false
remuda.ls = function()
  return {{ name = "lead", alive = alive, attached = true, human_idle = idle }}
end
remuda.session = function() return { is_busy = busy } end
remuda.butler = { dialogs = { check = function() return not modal and not replaced end } }
remuda.key = function() error("notice admission must not probe or clear the composer") end
local garbled = "────\n❯ stale text model-refresh error: garbled input\n────"
local function reset(screen, expired)
  frames, calls, typed = { screen }, 0, {}
  bus.notices.lead = { count = 4, message_order = { "m1", "m2", "m3", "m4" },
    message_ids = { m1 = "notice one", m2 = "notice two", m3 = "notice three", m4 = "notice four" },
    text = "notice four", kind = "claude", delivery_attempts = 0 }
  bus.notice_recoveries = expired and { lead = { phase = "probe", count = 4,
    started_at = now - 21, message_ids = { "m1", "m2", "m3", "m4" } } } or {}
  bus.notice_screens, bus.notice_fallbacks = {}, {}
end
assert(remuda._butler_prompt_is_empty("claude", garbled) == "NON-EMPTY")
for _, kind in ipairs({ "claude", "codex" }) do
  bus.agents.lead.kind = kind
  for _, screen in ipairs({ garbled, "unrecognized garbled renderer", "❯ actual draft" }) do
    for _, expired in ipairs({ false, true }) do
      reset(screen, expired)
      deliver("lead")
      assert(#typed == 1, kind .. " idle input must reach normal submission")
      assert(bus.notice_recoveries.lead.phase == "verify_notice", "submission remains verified")
      assert(#bus.notice_recoveries.lead.message_ids == 4, "all four notices tracked")
      assert(not bus.notices.lead.retry_at, "no timeout backoff")
    end
  end
end
-- Independent positive restrictions remain effective, regardless of composer text.
for _, guard in ipairs({ "human", "modal", "replaced", "dead", "busy" }) do
  reset(garbled, false)
  idle = guard == "human" and 0 or math.huge
  modal, replaced = guard == "modal", guard == "replaced"
  alive, busy = guard ~= "dead", guard == "busy"
  assert(not remuda._butler_notify_policy("lead"), guard .. " restriction preserved")
end
idle, busy, alive, modal, replaced = math.huge, false, true, false, false
-- Missing busy telemetry does not grant the explicit-idle exception.
reset(garbled, false)
for _, api in ipairs({ function() return nil end, function() return {} end,
    function() error("busy unavailable") end }) do
  remuda.session = api
  assert(not remuda._butler_notify_policy("lead"), "unknown busy telemetry keeps legacy policy")
end
remuda.session = function() return { is_busy = false } end
-- Unknown capture is a screen-policy uncertainty, not a busy signal.
remuda.capture = function() error("capture unavailable") end
assert(remuda._butler_notify_policy("lead"), "idle capture failure allows screen dimension")
remuda.capture = function() return {} end
assert(remuda._butler_notify_policy("lead"), "idle malformed capture allows screen dimension")
print("ok - idle nonempty notice admission and expired fallback")
