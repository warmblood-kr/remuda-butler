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
-- 6. Codex steers mid-turn (not a queue): a working Codex pane is deferred, never typed.
local codex = read(FX .. "codex-0.162.1-working-empty.txt")
bus.agents.lead.kind = "codex"
assert(run({ codex, codex, codex }, { 4 }) == 0, "working Codex+EMPTY defers without type_text")
assert(bus.notices.lead, "Codex notice stays queued")
bus.agents.lead.kind = "claude"
print("ok")
