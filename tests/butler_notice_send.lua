-- Run from the repository root: luajit tests/butler_notice_send.lua
-- Automatic mailbox wakeups: one ordinary atomic send per coalesced notice,
-- for OpenCode, Codex and Claude Code. No composer/modal/idle prediction, no
-- probe, no 20-second recovery, no extra Return, no clear/ESC. Attachment is not
-- an admission gate; a replaced session/instance, a changed agent record and a
-- replaced notice/journal generation are refused by the live + bound-instance
-- preflight and the generation fence. Transport acceptance is never claimed as
-- a read: mail stays unread until the inbox is.
local now = 1000
local trace = {}
_butler_session_trace = function(event, detail) trace[#trace + 1] = { event = event, detail = detail } end
local unread = { m1 = true, m2 = true, m3 = true }
local unread_loaded = {}
local sent_mail = {}
local bus = {
  agents = {},
  notices = {}, notice_timers = {}, messages = {}, objects = {}, mail_delivered = {},
  pending_tasks = {}, codex_update_relaunches = {}, codex_update_state = {},
  mail_resent = {}, unread_seeded = {}, notice_seen = {},
}
local messages = {
  m1 = { id = "m1", from = { alias = "alice", id = "alice-id" } },
  m2 = { id = "m2", from = { alias = "alice", id = "alice-id" } },
  m3 = { id = "m3", from = { alias = "bob", id = "bob-id" } },
}
local mail = {
  mailbox = function(id) if id == "lead-id" or id == "lead" then return { "m1" } end; return {} end,
  is_unread = function(id, message_id) return unread[message_id] == true end,
  unread = function(id) unread_loaded[id] = {}; return 1 end,
  find_message = function(id) return messages[id] end,
}
local rows = {}
local capture_calls, key_calls, type_calls, clear_calls = 0, 0, 0, 0
remuda = {
  _butler_notice_config = {
    bus = bus, resolve = function(name) return name end,
    mail_address = function(name) return { alias = name, id = name } end,
    mail_id = function(name) return name, { alias = name, id = name, kind = "opencode" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end,
  },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = {
    opencode = { placeholders = { "Ask anything…" } },
    codex = { placeholders = { "Ask Codex to do anything" } },
    claude = { placeholders = {} },
  },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = _butler_session_trace,
  ls = function() return rows end,
  capture = function() capture_calls = capture_calls + 1; error("notice delivery must not read the screen") end,
  capture_styled = function() capture_calls = capture_calls + 1; error("notice delivery must not read the screen") end,
  session = function() error("notice delivery must not need busy telemetry") end,
  key = function() key_calls = key_calls + 1; error("notice delivery must never press keys") end,
  type_text = function() type_calls = type_calls + 1; error("notice delivery must use one atomic send") end,
  clear_input = function() clear_calls = clear_calls + 1; error("notice delivery must never clear input") end,
}
-- Durable journal harness: the real module with an injected codec/clock/storage.
local journal_module = dofile("packages/butler/delivery_journal.lua")
local journal_files = {}
local function literal(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = literal(item) end
    local keys = {}
    for key in pairs(value) do if type(key) ~= "number" then keys[#keys + 1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("[%q]=%s", key, literal(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end
local test_codec = {
  encode = literal,
  decode = function(text) return assert(loadstring("return " .. text))() end,
  array = function(value) return value end,
  object = function(value) return value end,
}
local function new_journal()
  return journal_module.new({ path = "notice-journal",
    read = function(path)
      if journal_files[path] == nil then return nil, "missing" end
      return journal_files[path]
    end,
    write = function(path, text) journal_files[path] = text; return true end,
    now = function() return now end,
    hash = function(body) return string.format("%x", #body) end,
    json = test_codec })
end
dofile("packages/butler/notice.lua")
-- notice.lua installs the real mail-sending seam; replace it after loading.
remuda._butler_send = function(_, to, body) sent_mail[#sent_mail + 1] = { to = to, body = body } end
local N = remuda._butler_notice
local deliver = N.deliver_notice

local function reset(kind, state)
  now = 1000
  state = state or {}
  bus.agents = { lead = { id = "lead-id", kind = kind or "opencode", parent = "root",
    instance_id = state.instance or "instance-1" } }
  bus.notices = {}
  bus.notice_screens, bus.notice_recoveries, bus.notice_fallbacks = {}, {}, {}
  bus.notice_stuck, bus.notice_failure_alerts, bus.notice_uncertain_alerts = {}, {}, {}
  bus.notice_journal_alerts, bus.notice_journal_failure_alerts = {}, {}
  bus.notice_uncertain = {}
  bus.notice_sent_at, bus.notice_reminder_at, bus.notice_retry_reasons = {}, {}, {}
  bus.pending_tasks = {}
  capture_calls, key_calls, type_calls, clear_calls = 0, 0, 0, 0
  journal_files = {}
  remuda._butler_delivery_journal = new_journal()
  sent_mail = {}
  unread = { m1 = true, m2 = true, m3 = true }
  rows = { { name = "lead", alive = state.alive ~= false, attached = state.attached == true,
    instance_id = state.row_instance or "instance-1" } }
end
local function reset_keeping_journal(kind, state)
  local saved = journal_files
  reset(kind, state)
  journal_files = saved
  remuda._butler_delivery_journal = new_journal()
end
local function queue(ids)
  ids = ids or { "m1" }
  local order, notices = {}, {}
  for _, id in ipairs(ids) do
    order[#order + 1] = id
    notices[id] = "Butler message " .. id .. " from alice arrived. Read it: remuda butler inbox"
  end
  bus.notices.lead = {
    count = #ids, message_order = order, message_ids = notices,
    text = notices[order[#order]], kind = bus.agents.lead.kind, due_at = now,
  }
end
local function assert_never_destructive(label)
  assert(capture_calls == 0, label .. ": captured the screen")
  assert(key_calls == 0, label .. ": pressed a key")
  assert(type_calls == 0, label .. ": used type_text")
  assert(clear_calls == 0, label .. ": cleared input")
end

-- 1. Idle, busy/animated and draft screens are all irrelevant: one send.
for _, kind in ipairs({ "opencode", "codex", "claude" }) do
  reset(kind)
  queue()
  local sent = {}
  remuda.send = function(name, text) sent[#sent + 1] = { name = name, text = text } end
  assert(deliver("lead") == true, kind .. ": transport-accepted send completes the notice")
  assert(#sent == 1 and sent[1].name == "lead", kind .. ": exactly one core send")
  assert(sent[1].text:find("Butler message m1", 1, true), kind .. ": the notice text is sent")
  assert(bus.notices.lead == nil, kind .. ": the delivered notice leaves the queue")
  assert(unread.m1 == true, kind .. ": transport acceptance never marks the mail read")
  assert_never_destructive(kind)
  local accepted
  for _, row in ipairs(trace) do
    if row.event == "notice_transport_accepted" then accepted = row end
  end
  assert(accepted and accepted.detail:find("m1", 1, true), kind .. ": acceptance is traced")
end

-- 2. Nil success is the real core contract (`send` returns no value on Ok).
reset("opencode")
queue()
remuda.send = function() return nil end
assert(deliver("lead") == true, "nil return is transport accepted")
assert(bus.notices.lead == nil, "nil success clears the queue")
-- A defensive true is accepted too.
reset("codex")
queue()
remuda.send = function() return true end
assert(deliver("lead") == true, "true return is transport accepted")
-- A legacy explicit false is never success. Its detail decides: a busy detail
-- proves nothing was written (safe recheck); an unexplained or unconfirmed
-- result may have landed and is uncertain.
reset("claude")
queue()
remuda.send = function() return false, "legacy refusal" end
deliver("lead")
assert(bus.notices.lead == nil and bus.notice_stuck.lead,
  "an unexplained false is uncertain, not retried")
reset("claude")
queue()
remuda.send = function() return false, "session input is busy; nothing was written, retry" end
deliver("lead")
assert(bus.notices.lead and bus.notices.lead.due_at == now + 1
  and not bus.notices.lead.delivery_attempts, "false plus busy is a safe one-second recheck")
reset("claude")
queue()
remuda.send = function() return false, "submission is unconfirmed" end
deliver("lead")
assert(bus.notices.lead == nil and bus.notice_stuck.lead,
  "false plus an unconfirmed detail is uncertain")
reset("claude")
queue()
remuda.send = function() return false, "delivery may be partial or late" end
deliver("lead")
assert(bus.notices.lead == nil and bus.notice_stuck.lead,
  "false plus a partial detail is uncertain")

-- 3. Attachment is not an admission gate (owner decision 2026-11-05): the one
-- atomic send still happens; no composer read or draft protection is added.
reset("opencode", { attached = true })
queue()
local attached_sends = 0
remuda.send = function() attached_sends = attached_sends + 1 end
assert(deliver("lead") == true, "an attached pane still receives the notice")
assert(attached_sends == 1, "exactly one send while attached")
assert(bus.notices.lead == nil, "the attached delivery completes normally")
assert_never_destructive("attached")
-- If the core itself refuses with its transport limitation, that is an explicit
-- reason and a safe one-second recheck, not a policy gate and not uncertainty.
reset("opencode", { attached = true })
queue()
remuda.send = function() error("a human is attached to this session", 0) end
deliver("lead")
assert(bus.notices.lead and bus.notices.lead.due_at == now + 1,
  "a core transport refusal rechecks in one second")
assert(bus.notice_stuck.lead == nil, "a core transport refusal is not uncertainty")

-- 4. Dead or replaced sessions refuse without writing.
reset("codex", { alive = false })
queue()
remuda.send = function() error("must not send") end
deliver("lead")
assert(bus.notices.lead and bus.notices.lead.delivery_attempts == 1, "a dead session is a bounded failure")
reset("claude", { instance = "instance-1", row_instance = "instance-2" })
queue()
local replaced_sends = 0
remuda.send = function() replaced_sends = replaced_sends + 1 end
deliver("lead")
assert(replaced_sends == 0, "a replaced instance receives no bytes")
assert(bus.notices.lead and bus.notices.lead.delivery_attempts == 1, "replacement is a bounded failure")

-- 5. Writer busy and rate limiting are explicit refusals that wrote nothing.
for _, refusal in ipairs({
  "session input is busy; nothing was written, retry",
  "a session input write is already in flight",
  "session input rate limit exceeded",
}) do
  reset("opencode")
  queue()
  remuda.send = function() error(refusal, 0) end
  deliver("lead")
  assert(bus.notices.lead and bus.notices.lead.due_at == now + 1,
    "refusal rechecks in one second: " .. refusal)
  assert(bus.notices.lead.delivery_attempts == nil, "refusal spends no attempt: " .. refusal)
end
-- The dialog gate's refusal is explicit too, and the notice is not retyped now.
reset("claude")
queue()
remuda.send = function() error("Butler dialog blocked; waiting for owner review", 0) end
deliver("lead")
assert(bus.notices.lead and bus.notices.lead.due_at == now + 1, "dialog refusal rechecks in one second")
assert(bus.notices.lead.delivery_attempts == nil, "dialog refusal spends no attempt")

-- 6. "This text was not typed" is safe to retry on the bounded schedule.
reset("codex")
queue()
remuda.send = function()
  error("an earlier write to this pane stalled for over 30s and its Return was not sent; "
    .. "the pane may hold unsent text; this text was not typed", 0)
end
deliver("lead")
assert(bus.notices.lead and bus.notices.lead.delivery_attempts == 1
  and bus.notices.lead.retry_at == now + 20, "not-typed uses the bounded retry schedule")

-- 7. A timeout or uncertain outcome after dispatch is reported, never resent.
for _, uncertain in ipairs({
  "text is still being written to a slow pane; Return follows when it lands or is dropped after the bound; check the pane before resending",
  "text may be in the pane, but submission is unconfirmed.",
  "session PTY write timed out; delivery may be partial or late",
}) do
  reset("opencode")
  queue({ "m1", "m2" })
  local uncertain_sends = 0
  remuda.send = function() uncertain_sends = uncertain_sends + 1; error(uncertain, 0) end
  deliver("lead")
  assert(uncertain_sends == 1, "an uncertain outcome is attempted once: " .. uncertain)
  assert(bus.notices.lead == nil, "an uncertain outcome is not retried now")
  assert(bus.notice_stuck.lead, "an uncertain outcome opens the stuck record")
  assert(bus.notice_stuck.lead.ids and #bus.notice_stuck.lead.ids == 2, "stuck record names both IDs")
  assert(bus.notice_uncertain_alerts.lead and bus.notice_uncertain_alerts.lead.exhausted,
    "the uncertainty alert is recorded")
  local alert
  for _, row in ipairs(sent_mail) do if row.to == "alice" then alert = row end end
  assert(alert, "the sender is told the truth")
  assert(alert.body:find("Could not confirm", 1, true), "the alert does not claim delivery")
  assert(alert.body:find("m1", 1, true) and alert.body:find("m2", 1, true), "the alert names the IDs")
  assert(alert.body:find("[butler-notice-uncertain:m1]", 1, true), "the alert carries its once-only marker")
  assert(unread.m1 == true and unread.m2 == true, "uncertain mail stays unread")
  deliver("lead")
  assert(uncertain_sends == 1, "a later tick does not repeat an uncertain send")
end
-- An unknown post-dispatch error is treated as uncertain, not as safe.
reset("codex")
queue()
local unknown_sends = 0
remuda.send = function() unknown_sends = unknown_sends + 1; error("transport exploded", 0) end
deliver("lead")
assert(unknown_sends == 1 and bus.notices.lead == nil and bus.notice_stuck.lead,
  "unknown errors never trigger a blind resend")
deliver("lead")
assert(unknown_sends == 1, "unknown errors are not repeated on later ticks")

-- 8. Coalescing keeps the 2s quiet / 10s cap window before the one send.
reset("opencode")
now = 5000
remuda.send = function() end
assert(remuda._butler_notify("lead", "first notice", "m1") == false)
now = 5001
assert(remuda._butler_notify("lead", "second notice", "m2") == false)
local pending = bus.notices.lead
assert(pending.count == 2, "notices coalesce")
assert(pending.due_at == 5003, "the quiet window restarts with the newest mail")
now = 5003
deliver("lead")
assert(bus.notices.lead == nil, "the coalesced notice sends once")
-- The call is checked: the real send stub was replaced above, so this is a no-op guard.
assert(type(remuda.send) == "function")

-- 9. Reading the mail or the recipient exiting cancels the queue; durability holds.
reset("opencode")
queue()
bus.notices.lead = { count = 1, message_order = { "m1" }, message_ids = { m1 = "notice m1" }, text = "notice m1" }
unread.m1 = false
remuda.send = function() error("must not send read mail") end
deliver("lead")
assert(bus.notices.lead == nil, "read mail is not noticed")
-- An unread message survives a restart: seeding queues it again.
reset("opencode")
unread = { m1 = true }
bus.unread_seeded = {}
remuda.ls = function() return rows end
remuda._butler_notify = remuda._butler_notify
-- Rebuild the module state as a restart would: a fresh bus with the same unread mail.
bus.notices, bus.notice_sent_at, bus.notice_reminder_at = {}, {}, {}
bus.notice_seen, bus.unread_seeded = {}, {}
remuda.send = function() end
remuda._butler_deliver_notices()
assert(bus.notices.lead and bus.notices.lead.count == 1, "restart re-seeds unread mail")
now = now + 3
remuda._butler_deliver_notices()
assert(unread.m1 == true, "the re-seeded notice leaves the mail unread")
assert(bus.notices.lead == nil, "the re-seeded notice is sent once")

-- 10. Repeated ticks while the transport accepted do not duplicate.
reset("claude")
queue()
local once = 0
remuda.send = function() once = once + 1 end
deliver("lead")
deliver("lead")
deliver("lead")
assert(once == 1, "an accepted notice is not resent by later ticks")

-- 11. The dialogs capability is preferred when installed, and its refusal is honoured.
reset("opencode")
queue()
local capability_calls, raw_calls = 0, 0
remuda.send = function() raw_calls = raw_calls + 1 end
remuda.butler = { dialogs = { automatic_notice_send = function(name, text, ids)
  capability_calls = capability_calls + 1
  assert(name == "lead" and type(text) == "string" and #ids == 1)
  return false, "human_attached"
end } }
deliver("lead")
assert(capability_calls == 1 and raw_calls == 0, "the notice-only capability is used")
assert(bus.notices.lead and bus.notices.lead.due_at == now + 1, "capability refusal defers")
remuda.butler = nil

-- 12. Same-runtime reload: a preserved stuck record suppresses a blind reseed.
reset("opencode")
bus.notice_stuck.lead = { ids = { "m1", "m2" }, since = now, agent_id = "lead-id",
  reason = "uncertain: text may be in the pane" }
bus.notice_seen, bus.unread_seeded = {}, { lead = "old-instance" }
bus.notices = {}
local reseed_sends = 0
remuda.send = function() reseed_sends = reseed_sends + 1 end
remuda._butler_deliver_notices()
assert(bus.notices.lead == nil and reseed_sends == 0,
  "a preserved uncertain stuck record suppresses the reload reseed")
assert(bus.unread_seeded.lead == "instance-1", "the reseed checkpoint still advances")

-- 13. A full restart re-reads the durable journal, so an uncertain ID is never
-- nudged again even after a canonical read or a compaction re-show.
reset("opencode")
queue()
remuda.send = function() error("submission is unconfirmed", 0) end
deliver("lead")
assert(bus.notice_stuck.lead, "the uncertain attempt opens the stuck record")
unread.m1 = false -- the canonical inbox read happened
bus.notice_stuck, bus.notice_seen, bus.unread_seeded, bus.notices = nil, {}, {}, nil
reset_keeping_journal("opencode")
unread.m1 = false
local restart_sends = 0
remuda.send = function() restart_sends = restart_sends + 1 end
bus.unread_seeded = { lead = "old-instance" }
remuda._butler_deliver_notices()
assert(restart_sends == 0 and bus.notices.lead == nil,
  "the durable journal suppresses the ID across a full restart and a read")
assert(remuda._butler_notify("lead", "Butler message m1 from alice re-shown after compaction.", "m1", true) == false)
assert(bus.notices.lead == nil, "the durable journal suppresses a post-restart reshow")

-- 14. The single admission point suppresses an ID already stuck for this
-- recipient (including a re-show); a new ID still queues, and another agent
-- generation's record does not suppress this recipient.
reset("opencode")
bus.notice_stuck.lead = { ids = { "m1" }, since = now, agent_id = "lead-id",
  reason = "uncertain: text may be in the pane" }
bus.notice_seen = {}
assert(remuda._butler_notify("lead", "Butler message m1 from alice re-shown after compaction.", "m1", true) == false)
assert(bus.notices.lead == nil, "a stuck re-show is not queued again")
assert(remuda._butler_notify("lead", "Butler message m2 from alice arrived.", "m2") == false)
assert(bus.notices.lead and bus.notices.lead.count == 1, "a new message ID still queues")
-- The stuck record may close (the mail was read) while the uncertainty
-- tombstone keeps suppressing the same ID for this image.
bus.notices.lead = nil
bus.notice_stuck.lead = nil
bus.notice_uncertain["lead-id"] = { m1 = "text may be in the pane" }
assert(remuda._butler_notify("lead", "Butler message m1 from alice re-shown after compaction.", "m1", true) == false)
assert(bus.notices.lead == nil, "an uncertainty tombstone suppresses the re-show after stuck clears")
assert(remuda._butler_notify("lead", "Butler message m3 from bob arrived.", "m3") == false)
assert(bus.notices.lead and bus.notices.lead.count == 1, "new IDs still queue beside a tombstone")
bus.notices.lead = nil
bus.notice_uncertain = {}
bus.notice_stuck.lead = { ids = { "m1" }, since = now, agent_id = "other-agent-id" }
assert(remuda._butler_notify("lead", "Butler message m1 from alice re-shown after compaction.", "m1", true) == false)
assert(bus.notices.lead and bus.notices.lead.count == 1,
  "another agent generation's stuck record does not suppress this recipient")

-- 14b. Generation fence at the writer seam: a reload during journal_save
-- yields no transport, and the replacement journal keeps the attempt reserved.
reset("opencode")
queue()
local live = true
remuda._butler_delivery_journal = journal_module.new({ path = "notice-journal",
  read = function(path)
    if journal_files[path] == nil then return nil, "missing" end
    return journal_files[path]
  end,
  write = function(path, text) journal_files[path] = text; live = false; return true end,
  now = function() return now end,
  hash = function(body) return string.format("%x", #body) end,
  json = test_codec, is_current = function() return live end })
local reload_sends = 0
remuda.send = function() reload_sends = reload_sends + 1 end
assert(deliver("lead") == false, "a writer-seam reload refuses the dispatch")
assert(reload_sends == 0, "zero transport after a writer-seam reload")
local replacement = new_journal()
assert(replacement.load() == true, "the replacement journal loads the written bytes")
assert(replacement.state_of("lead-id", "m1") == "uncertain",
  "the old attempt stays reserved in the replacement journal")

-- 14c. Generation fence at the audit yield: the capability's still-current hook
-- refuses before the raw send, and the old generation never retires the new one.
reset("opencode")
queue()
local audit_sends = 0
remuda.butler = { dialogs = { automatic_notice_send = function(name, text, ids, still_current)
  remuda._butler_delivery_journal = new_journal()
  if type(still_current) == "function" and still_current() ~= true then
    return false, "journal_generation_changed"
  end
  audit_sends = audit_sends + 1
  return true
end } }
assert(deliver("lead") == false, "an audit-yield reload refuses the dispatch")
assert(audit_sends == 0, "zero transport after an audit-yield reload")
local after_audit = remuda._butler_delivery_journal
assert(after_audit.load() == true, "the replacement journal loads")
assert(after_audit.state_of("lead-id", "m1") == "uncertain",
  "the reserved attempt survives in the replacement journal")
remuda.butler = nil

-- 14d. A final mark/retire failure after transport is surfaced explicitly; it
-- must never read as if no bytes were written.
for _, failure in ipairs({ false, "throw" }) do
  reset("opencode")
  queue()
  local journal = remuda._butler_delivery_journal
  if failure == false then
    journal.retire = function() return false, "save_failed: disk full" end
  else
    journal.retire = function() error("dispatch failed", 0) end
  end
  local resolve_sends, alerts = 0, 0
  remuda.send = function() resolve_sends = resolve_sends + 1 end
  remuda._butler_send = function(_, to, body)
    if to == "alice" and body:find("could not record", 1, true) then alerts = alerts + 1 end
  end
  assert(deliver("lead") == true, "the transport outcome is still recorded")
  assert(resolve_sends == 1 and alerts == 1,
    "a failed resolution write alerts explicitly: " .. tostring(failure))
  local traced = false
  for _, row in ipairs(trace) do
    if row.event == "notice_journal_resolve_failed" then traced = true end
  end
  assert(traced, "the failed resolution is traced")
  for _, row in ipairs(sent_mail) do
    if row.to == "alice" and row.body:find("could not record", 1, true) then
      assert(row.body:find("Legacy unread reminders", 1, true),
        "accepted PTY failure does not promise no reminders")
      assert(not row.body:find("no automatic resend will run", 1, true),
        "accepted PTY failure does not claim a conservative reservation")
    end
  end
end

-- 14e. A release that cannot persist keeps its reservation conservatively:
-- the entry is restored, the next tick does not resend, and the alert says so.
reset("opencode")
queue()
local release_journal = remuda._butler_delivery_journal
release_journal.retire = function() return false, "save_failed: disk full" end
local release_sends, release_alerts = 0, 0
remuda.send = function()
  release_sends = release_sends + 1
  error("session input is busy; nothing was written, retry", 0)
end
remuda._butler_send = function(_, to, body)
  if to == "alice" and body:find("kept", 1, true) then release_alerts = release_alerts + 1 end
end
assert(deliver("lead") == false, "a failed release defers")
assert(release_sends == 1, "the first attempt still made the safe refusal")
assert(release_journal.find("lead-id", "m1") ~= nil,
  "the unpersisted release restores its reservation")
assert(release_alerts == 1, "the conservative release is alerted")
now = now + 1
deliver("lead")
assert(release_sends == 1, "no automatic resend while the reservation is kept")

-- 14f. Capture order: an agent replaced with the SAME recipient id/new instance
-- inside the writer must not be adopted by the old continuation.
reset("opencode")
queue()
local old_agent = bus.agents.lead
remuda._butler_delivery_journal = journal_module.new({ path = "notice-journal",
  read = function(path)
    if journal_files[path] == nil then return nil, "missing" end
    return journal_files[path]
  end,
  write = function(path, text)
    journal_files[path] = text
    bus.agents.lead = { id = "lead-id", kind = "opencode", parent = "root",
      instance_id = "instance-2" }
    rows = { { name = "lead", alive = true, attached = false, instance_id = "instance-2" } }
    return true
  end,
  now = function() return now end,
  hash = function(body) return string.format("%x", #body) end,
  json = test_codec })
local replacement_sends = 0
remuda.send = function() replacement_sends = replacement_sends + 1 end
assert(deliver("lead") == false, "a same-id agent replacement during the writer is refused")
assert(replacement_sends == 0, "zero transport after a same-id agent replacement")
local replaced_journal = new_journal()
assert(replaced_journal.load() == true, "the replacement journal loads the reserved attempt")
assert(replaced_journal.state_of("lead-id", "m1") == "uncertain",
  "the old attempt stays reserved as uncertain")
bus.agents.lead = old_agent
rows = { { name = "lead", alive = true, attached = false, instance_id = "instance-1" } }

-- 14g. Capture order: the notice module itself is replaced during the writer.
reset("opencode")
queue()
local original_module = remuda._butler_notice
remuda._butler_delivery_journal = journal_module.new({ path = "notice-journal",
  read = function(path)
    if journal_files[path] == nil then return nil, "missing" end
    return journal_files[path]
  end,
  write = function(path, text)
    journal_files[path] = text
    remuda._butler_notice = { deliver_notice = function() return true end }
    return true
  end,
  now = function() return now end,
  hash = function(body) return string.format("%x", #body) end,
  json = test_codec })
local module_sends = 0
remuda.send = function() module_sends = module_sends + 1 end
assert(deliver("lead") == false, "a notice-module replacement during the writer is refused")
assert(module_sends == 0, "zero transport after a notice-module replacement")
remuda._butler_notice = original_module

-- 14h. Pre-snapshot yield: remuda.ls replacing only the notice module must not
-- bless the new module; zero transport.
reset("opencode")
queue()
local original_notice = remuda._butler_notice
local real_ls = remuda.ls
remuda.ls = function()
  remuda._butler_notice = { deliver_notice = function() return true end }
  return real_ls()
end
local ls_module_sends = 0
remuda.send = function() ls_module_sends = ls_module_sends + 1 end
assert(deliver("lead") == false, "an ls-yield notice-module reload is refused")
assert(ls_module_sends == 0, "zero transport after an ls-yield module reload")
remuda._butler_notice = original_notice
remuda.ls = real_ls

-- 14i. Pre-snapshot yield: an in-place agent instance change during remuda.ls
-- (same object, same id) must invalidate the snapshot; zero transport.
reset("opencode")
queue()
real_ls = remuda.ls
remuda.ls = function()
  bus.agents.lead.instance_id = "instance-2"
  return { { name = "lead", alive = true, attached = false, instance_id = "instance-2" } }
end
local ls_agent_sends = 0
remuda.send = function() ls_agent_sends = ls_agent_sends + 1 end
assert(deliver("lead") == false, "an ls-yield in-place instance change is refused")
assert(ls_agent_sends == 0, "zero transport after an ls-yield instance change")
remuda.ls = real_ls

-- 14j. Writer yield: an in-place agent instance mutation with a matching row
-- (same agent object) must still be caught by the guard.
reset("opencode")
queue()
remuda._butler_delivery_journal = journal_module.new({ path = "notice-journal",
  read = function(path)
    if journal_files[path] == nil then return nil, "missing" end
    return journal_files[path]
  end,
  write = function(path, text)
    journal_files[path] = text
    bus.agents.lead.instance_id = "instance-3"
    rows = { { name = "lead", alive = true, attached = false, instance_id = "instance-3" } }
    return true
  end,
  now = function() return now end,
  hash = function(body) return string.format("%x", #body) end,
  json = test_codec })
local mutation_sends = 0
remuda.send = function() mutation_sends = mutation_sends + 1 end
assert(deliver("lead") == false, "a writer-yield in-place instance mutation is refused")
assert(mutation_sends == 0, "zero transport after a writer-yield instance mutation")

-- 14k. Writer yield: the SAME agent record changes only its id to another
-- recipient. The frozen recipient must not follow it; zero transport.
reset("opencode")
queue()
remuda._butler_delivery_journal = journal_module.new({ path = "notice-journal",
  read = function(path)
    if journal_files[path] == nil then return nil, "missing" end
    return journal_files[path]
  end,
  write = function(path, text)
    journal_files[path] = text
    bus.agents.lead.id = "other-recipient-id"
    return true
  end,
  now = function() return now end,
  hash = function(body) return string.format("%x", #body) end,
  json = test_codec })
local id_mutation_sends = 0
remuda.send = function() id_mutation_sends = id_mutation_sends + 1 end
assert(deliver("lead") == false, "a writer-yield recipient-id mutation is refused")
assert(id_mutation_sends == 0, "zero transport after a recipient-id mutation")

-- 14l. Legacy unbound agent (nil instance) whose ROW instance changes during
-- the writer: the fresh preflight must not match the frozen target.
reset("opencode")
queue()
bus.agents.lead.instance_id = nil
remuda._butler_delivery_journal = journal_module.new({ path = "notice-journal",
  read = function(path)
    if journal_files[path] == nil then return nil, "missing" end
    return journal_files[path]
  end,
  write = function(path, text)
    journal_files[path] = text
    rows = { { name = "lead", alive = true, attached = false, instance_id = "instance-2" } }
    return true
  end,
  now = function() return now end,
  hash = function(body) return string.format("%x", #body) end,
  json = test_codec })
local legacy_sends = 0
remuda.send = function() legacy_sends = legacy_sends + 1 end
assert(deliver("lead") == false, "a legacy row-instance change during the writer is refused")
assert(legacy_sends == 0, "zero transport after a legacy row-instance change")

-- 15. A journal that cannot save blocks the write entirely: explicit status,
-- one alert, no silent PTY bypass, and the mail stays unread.
reset("opencode")
queue()
remuda._butler_delivery_journal = journal_module.new({ path = "blocked",
  read = function() return nil, "missing" end,
  write = function() return false, "disk full" end,
  now = function() return now end,
  hash = function(body) return string.format("%x", #body) end,
  json = test_codec })
local blocked_sends, blocked_alerts = 0, 0
remuda.send = function() blocked_sends = blocked_sends + 1 end
remuda._butler_send = function(_, to) if to == "alice" then blocked_alerts = blocked_alerts + 1 end end
deliver("lead")
assert(blocked_sends == 0, "a blocked journal writes no bytes")
assert(bus.notices.lead and bus.notices.lead.due_at == now + 1, "a blocked journal defers")
assert(blocked_alerts == 1, "a blocked journal alerts once")
local journal_trace
for _, row in ipairs(trace) do
  if row.event == "notice_journal_blocked" then journal_trace = row end
end
assert(journal_trace and journal_trace.detail:find("disk full", 1, true),
  "the explicit journal reason is traced")
deliver("lead")
assert(blocked_alerts == 1 and blocked_sends == 0, "no repeated alert and no bypass write")

-- 16. A 128-ID backlog is one valid reservation and one atomic send (the old
-- 16/32-count caps are gone; the serialized byte cap is the bound).
reset("opencode")
local backlog = {}
for index = 1, 128 do
  backlog[index] = "b" .. index
  unread[backlog[index]] = true
end
queue(backlog)
local backlog_sends = {}
remuda.send = function(_, text) backlog_sends[#backlog_sends + 1] = text end
assert(deliver("lead") == true, "a 128-id notice delivers")
assert(#backlog_sends == 1, "one atomic send for 128 IDs")
assert(backlog_sends[1]:find("128 new Butler messages", 1, true), "the text names the count")

assert_never_destructive("whole suite")
print("ok - automatic notices use one atomic send, preserve drafts and mail, and report uncertainty")
