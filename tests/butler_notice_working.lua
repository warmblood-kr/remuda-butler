-- Run from the repository root: luajit tests/butler_notice_working.lua
-- Working-agent delivery: the probe phase types into an EMPTY composer while busy.
local function read(path) local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s end
local FX = "tests/fixtures/notice-working/"
local working = read(FX .. "claude-2.1.300-working-empty.txt")
local spinner2 = working:gsub("12s", "13s")
local draft = read(FX .. "claude-2.1.300-working-draft.txt")
local approval = "Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"

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
local frames, calls, modal_calls, typed, sent = {}, 0, {}, {}, {}
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
  session = function() return { is_busy = true } end,
  type_text = function(_, text) typed[#typed + 1] = text; return "submitted" end,
  _butler_send = function(_, to, body) sent[#sent + 1] = { to, body } end,
}
dofile("packages/butler/notice.lua")
local deliver = remuda._butler_notice.deliver_notice

-- Two delivery ticks. The composer first reads unparseable (a menu, before the
-- working screen settles), which starts the probe phase; `tail` are the captures
-- of tick 2 (policy, probe screen, policy re-check). `modal_at` lists capture
-- numbers on which a known modal is on screen (the policy then says "no").
local function run(tail, modal_at)
  local seq = { approval, approval, approval }
  for _, f in ipairs(tail) do seq[#seq + 1] = f end
  frames, calls, typed = seq, 0, {}
  bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "Butler message m1 arrived." },
    text = "Butler message m1 arrived.", kind = "claude", delivery_attempts = 0 }
  bus.notice_recoveries, bus.notice_screens = {}, {}
  local hit = {}
  for _, n in ipairs(modal_at or {}) do hit[n] = true end
  remuda._test_modal = function() return hit[calls] == true end
  deliver("lead")
  assert(bus.notice_recoveries.lead and bus.notice_recoveries.lead.phase == "probe", "probe started")
  assert(#typed == 0, "nothing typed on the unparseable screen")
  now = now + 1
  deliver("lead")
  return #typed
end

-- 1. working + EMPTY composer after an unparseable screen: typed exactly once
--    (tick 2: capture 4 policy blocked, 5 probe screen, 6 re-check).
assert(run({ working, working, working }, { 4 }) == 1, "working+EMPTY types exactly once")
-- 2. animating spinner between captures still types once (no 2-identical wait).
assert(run({ working, spinner2, working }, { 4 }) == 1, "changing spinner still types once")
-- 3. busy->modal race: modal appears between probe and type => no type, stays queued.
assert(run({ working, working, working }, { 4, 6 }) == 0, "modal race defers without typing")
assert(bus.notices.lead, "deferred notice stays queued")
-- 4. human draft in composer is preserved: nothing typed.
assert(run({ working, draft, draft }, { 4 }) == 0, "draft composer is not typed over")
-- 5. approval dialog stays: nothing typed.
assert(run({ approval, approval, approval }, { 4 }) == 0, "approval dialog defers")
-- 6. Codex queues text typed mid-turn too (owner decision 2026-10-19): a working Codex
--    pane with an EMPTY composer receives the notice, like Claude.
local codex = read(FX .. "codex-0.162.1-working-empty.txt")
bus.agents.lead.kind = "codex"
assert(run({ codex, codex, codex }, { 4 }) == 1, "working Codex+EMPTY types exactly once")
assert(run({ codex, codex, codex }, { 4, 6 }) == 0, "Codex busy->modal race defers without typing")
bus.agents.lead.kind = "claude"

-- 7. Direct path and probe-to-direct: busy Codex + EMPTY composer is typed on both.
remuda.capture_styled = function() return { rows = { { { text = "› " } } }, cursor = { row = 1 } } end
local function direct(with_probe)
  bus.agents.lead.kind = "codex"
  frames, calls, typed = { codex, codex, codex, codex, codex }, 0, {}
  bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "Butler message m1 arrived." },
    text = "Butler message m1 arrived.", kind = "codex", delivery_attempts = 0 }
  bus.notice_screens = {}
  bus.notice_recoveries = with_probe and { lead = { phase = "probe", count = 1, message_ids = { "m1" },
    started_at = now, checks = 0 } } or {}
  remuda._test_modal = function() return false end
  deliver("lead")
  return #typed
end
assert(direct(false) == 1, "busy Codex direct path types")
assert(direct(true) == 1, "busy Codex probe-to-direct types")
-- 8. Idle Codex still gets the notice; busy Claude with an EMPTY composer keeps typing.
remuda.session = function() return { is_busy = false } end
assert(direct(false) == 1, "idle Codex still typed")
remuda.session = function() return { is_busy = true } end
bus.agents.lead.kind = "claude"
frames, calls, typed = { working, working, working }, 0, {}
bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "Butler message m1 arrived." },
  text = "Butler message m1 arrived.", kind = "claude", delivery_attempts = 0 }
bus.notice_recoveries, bus.notice_screens = {}, {}
deliver("lead")
assert(#typed == 1, "busy Claude + EMPTY composer unchanged")

-- 9. Busy telemetry that is missing, throwing or nil does not hold a Codex notice.
bus.agents.lead.kind = "codex"
for name, api in pairs({
  missing = false,
  throws = function() error("boom") end,
  nil_row = function() return nil end,
  nil_busy = function() return {} end,
}) do
  remuda.session = api or nil
  assert(direct(false) == 1, "codex busy telemetry " .. name .. " still types")
  assert(direct(true) == 1, "codex busy telemetry " .. name .. " still types (probe)")
end
-- 10. The core keeps refusing the write (another input write in flight): mail stays queued,
--     one escalation record (reason busy) opens after the cap, the leader hears about it once
--     per hour, and the notice is typed once the write goes through.
remuda.session = function() return { is_busy = true } end
local type_text = remuda.type_text
remuda.type_text = function() return "a session input write is already in flight" end
remuda._butler_send = function(from, to, body) sent[#sent + 1] = { to, body } end
sent = {}
bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "Butler message m1 arrived." },
  text = "Butler message m1 arrived.", kind = "codex", delivery_attempts = 0 }
bus.notice_recoveries, bus.notice_screens, bus.notice_stuck = {}, {}, {}
bus.notice_reminder_at, bus.notice_sent_at = {}, {}
frames, calls, typed = { codex }, 0, {}
local N = remuda._butler_notice
for _ = 1, 600 do now = now + 1; deliver("lead"); N.remind_unread_notices("lead", bus.agents.lead, now) end
assert(not bus.notice_stuck.lead and #sent == 0, "no escalation before the cap")
for _ = 1, 7200 do now = now + 1; deliver("lead"); N.remind_unread_notices("lead", bus.agents.lead, now) end
assert(#typed == 0 and bus.notices.lead, "refused mail retained")
assert(bus.notice_stuck.lead and bus.notice_stuck.lead.ids[1] == "m1", "busy cap opens the stuck record")
assert(tostring(bus.notice_stuck.lead.reason):find("busy"), "reason names busy")
assert(#sent >= 2 and #sent <= 3, "hourly leader report, deduped: " .. #sent)
for _, s in ipairs(sent) do assert(s[1] ~= "alice", "sender is not spammed") end
remuda.type_text = type_text
now = now + 1; deliver("lead")
assert(#typed == 1, "the retained notice is typed once the write goes through")
print("ok")
