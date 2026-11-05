-- Integrated dialogs wrapper regression (real packages/butler/dialogs.lua).
-- Automatic mail wakeups use the narrow `automatic_notice_send` capability:
-- generated notice text only, unconditional attached/live/instance preflight,
-- and their own audit. The general send/type_text/key modal gate is unchanged.
dofile('tests/butler_dialogs.lua')
local D = remuda.butler.dialogs
local bus = remuda._butler_bus
local screens, writes, audits = {}, {}, {}
local attached, live_instance = false, nil
local real_ls = remuda.ls
remuda.ls = function()
  local rows = real_ls()
  for _, row in ipairs(rows) do
    row.attached = attached and row.name == 'child' or false
    if row.name == 'child' and live_instance then row.instance_id = live_instance end
  end
  return rows
end
-- The earlier test file stops the dispatcher; reinstall the real wrapper so
-- notice.lua sees the only production install path. Replacing the raw word
-- first lets this file observe exactly what reaches the pane.
remuda.capture = function(name) return screens[name] end
remuda.send = function(name, text) writes[#writes + 1] = { name, text }; return true end
local real_append = remuda.butler.guard_policy.append
remuda.butler.guard_policy.append = function(record)
  audits[#audits + 1] = record
  return real_append(record)
end
D.install()
remuda._butler_notice_clock = function() return 1000 end
remuda._butler_session_trace = function() end
_butler_session_trace = function() end
remuda._butler_notice_config = {
  bus = bus, resolve = function(n) return n end,
  mail_address = function(n) return { alias = n, id = n } end,
  mail_id = function(n) return n, { alias = n, id = n, kind = 'claude' } end,
  mail = { mailbox = function() return {} end, is_unread = function() return true end,
    unread = function() return 1 end, find_message = function() return { from = { alias = 'owner', id = 'o' } } end },
  take_delivery_notice_result = function() end, notify_mail_delivery = function() end,
  deliver_message = function() end,
}
dofile('tests/notice_journal_stub.lua')
dofile('packages/butler/notice.lua')
remuda._butler_send = function() return 'queued' end
local N = remuda._butler_notice
local MODAL = 'Do you want to proceed?\n❯ 1. Yes\n2. No\n'
local NOTICE = 'Butler message m1 from owner arrived. Read it: remuda butler inbox'

-- 1. The general modal gate is untouched.
screens.child = MODAL
D.tick(); D.tick()
writes = {}
assert(not pcall(remuda.send, 'child', 'task'), 'general send stays modal-gated')
assert(not pcall(remuda.type_text, 'child', 'task'), 'general type_text stays modal-gated')
assert(not pcall(remuda.key, 'child', 'RET'), 'general key stays modal-gated')
assert(#writes == 0, 'no general write entered the modal')

-- 2. The notice-only capability bypasses only that prediction, and audits it.
audits = {}
assert(D.automatic_notice_send('child', NOTICE, { 'm1' }) == true,
  'the generated notice is delivered through the captured raw send')
assert(#writes == 1 and writes[1][1] == 'child' and writes[1][2] == NOTICE,
  'exactly one atomic write reached the pane')
assert(audits[1] and audits[1].event == 'automatic-mail-wakeup'
  and audits[1].summary == 'transport_only', 'the wakeup is audited before writing')
assert(audits[#audits].event == 'automatic-mail-wakeup-result'
  and audits[#audits].summary == 'transport_accepted', 'the transport outcome is audited')
-- General writes remain gated after the wakeup.
assert(not pcall(remuda.send, 'child', 'task'), 'the capability does not unwrap general send')

-- 3. The capability is narrow: no owner text, no unknown session, no bad IDs.
writes = {}
assert(select(2, D.automatic_notice_send('child', 'owner text', { 'm1' })) == 'invalid_notice',
  'only generated wakeup text is allowed')
assert(select(2, D.automatic_notice_send('child', NOTICE, {})) == 'invalid_notice',
  'at least one message ID is required')
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1', 'm 2' })) == 'invalid_notice',
  'malformed IDs are refused')
assert(select(2, D.automatic_notice_send('ghost', NOTICE, { 'm1' })) == 'session_unknown',
  'unknown sessions are refused')
assert(#writes == 0, 'narrow refusals write nothing')

-- 4. Attachment is not an admission gate (owner decision 2026-11-05): the one
-- atomic write still happens and is audited.
attached = true
writes, audits = {}, {}
assert(D.automatic_notice_send('child', NOTICE, { 'm1' }) == true,
  'an attached pane still receives the one atomic send')
assert(#writes == 1 and writes[1][2] == NOTICE, 'an attached pane receives one notice write')
assert(#audits >= 1, 'the attached wakeup is audited')
attached = false

-- 5. A replaced instance is refused; the supported preflight is tested, not an
-- atomic guarantee the name-addressed core send cannot provide.
writes = {}
bus.agents.child.instance_id = 'one'
live_instance = 'two'
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'session_replaced',
  'a replaced instance is refused')
assert(#writes == 0, 'a replaced instance receives no bytes')
live_instance = nil
bus.agents.child.instance_id = 'one'

-- 5b. A coalesced burst is unbounded: 17 IDs still produce one wakeup.
writes, audits = {}, {}
local burst = {}
for index = 1, 17 do burst[#burst + 1] = 'm' .. index end
assert(D.automatic_notice_send('child', '17 new Butler messages arrived. Read them: remuda butler inbox',
  burst) == true, 'a 17-message burst is not rejected by an ID cap')
assert(#writes == 1, 'the 17-message burst is one atomic write')
bus.notice_stuck.child = { ids = burst, since = 0, agent_id = bus.agents.child.id, reason = 'uncertain: x' }
writes = {}
assert(D.automatic_notice_send('child', '17 new Butler messages arrived. Read them: remuda butler inbox',
  burst) == true, 'the capability itself has no ID cap')
assert(#writes == 1, 'a reloaded burst still sends one wakeup')
bus.notice_stuck.child = nil

-- 5c. A legacy false result is classified by its detail, never blindly retried.
writes = {}
local legacy_send = remuda._butler_dialog_originals.send
remuda._butler_dialog_originals.send = function() return false, 'submission is unconfirmed' end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'send_refused: submission is unconfirmed',
  'a false partial result is returned with its detail')
remuda._butler_dialog_originals.send = function() return false, 'session input is busy; nothing was written, retry' end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'send_refused: session input is busy; nothing was written, retry',
  'a false busy result keeps its detail')
remuda._butler_dialog_originals.send = legacy_send
assert(#writes == 0, 'the legacy seam wrote nothing')

-- 5d. An attachment appearing while the audit yields is not a refusal: the
-- same agent object and instance still decide, and the write proceeds.
writes = {}
local audit_once = remuda.butler.guard_policy.append
remuda.butler.guard_policy.append = function(record)
  attached = true
  return audit_once(record)
end
assert(D.automatic_notice_send('child', NOTICE, { 'm1' }) == true,
  'an attachment during the audit does not refuse the transport write')
assert(#writes == 1, 'the post-audit write still happens once')
attached = false
remuda.butler.guard_policy.append = audit_once

-- 5d2. A reload during the audit: the caller's still-current claim is refused
-- immediately before the raw write, so zero bytes reach the pane.
writes = {}
local previous_journal = remuda._butler_delivery_journal
local journal_current = function() return remuda._butler_delivery_journal == previous_journal end
remuda.butler.guard_policy.append = function(record)
  local ok = audit_once(record)
  remuda._butler_delivery_journal = remuda._butler_notice_test_journal.new()
  return ok
end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' }, journal_current)) == 'journal_generation_changed',
  'a reload during the audit refuses the attempt')
assert(#writes == 0, 'zero raw transport after an audit-yield reload')
assert(audits[#audits].summary == 'not_written', 'the fenced attempt is audited as not written')
remuda._butler_delivery_journal = previous_journal
remuda.butler.guard_policy.append = audit_once

-- 5e. The same agent object and the same captured instance must survive the
-- audit. A new record with the same name/id is a different generation.
writes = {}
local agent_before = bus.agents.child
remuda.butler.guard_policy.append = function(record)
  local ok = audit_once(record)
  bus.agents.child = { id = agent_before.id, kind = 'claude', parent = 'leader', instance_id = 'one' }
  return ok
end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'session_changed',
  'a replaced agent record refuses the wakeup')
assert(#writes == 0 and audits[#audits].summary == 'not_written', 'a replaced record writes nothing')
bus.agents.child = agent_before

-- 5f. A bound expected instance with no readable row instance is refused.
remuda.butler.guard_policy.append = function(record)
  local ok = audit_once(record)
  live_instance = ''
  return ok
end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'session_instance_missing',
  'a missing row instance cannot verify the bound instance')
assert(#writes == 0, 'a missing row instance writes nothing')
live_instance = nil

-- 5g. On a legacy record with no bound instance, a different captured instance
-- after the audit is refused.
bus.agents.child.instance_id = nil
remuda.butler.guard_policy.append = function(record)
  local ok = audit_once(record)
  live_instance = 'two'
  return ok
end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'session_changed',
  'a changed captured instance refuses the wakeup')
assert(#writes == 0, 'a changed instance writes nothing')
live_instance = nil
bus.agents.child.instance_id = 'one'

-- 5h. A stopped or reloaded dialogs generation cannot write.
remuda.butler.guard_policy.append = function(record)
  local ok = audit_once(record)
  D.stop()
  return ok
end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'session_changed',
  'a stopped dialogs module cannot write after its audit')
assert(#writes == 0, 'a stopped generation writes nothing')
D.install()
remuda.butler.guard_policy.append = function(record)
  local ok = audit_once(record)
  remuda.butler.dialogs = {}
  return ok
end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'session_changed',
  'a reloaded dialogs generation cannot write after its audit')
assert(#writes == 0, 'a retired generation writes nothing')
remuda.butler.dialogs = D
D.install()
remuda.butler.guard_policy.append = audit_once

-- 6. A missing audit refuses the write; the seam is restored afterwards.
writes = {}
local audit_wrapper = remuda.butler.guard_policy.append
remuda.butler.guard_policy.append = function() return nil, 'disk full' end
assert(select(2, D.automatic_notice_send('child', NOTICE, { 'm1' })) == 'audit_unavailable',
  'an unwritable audit refuses the wakeup')
assert(#writes == 0, 'an unaudited wakeup never writes')
remuda.butler.guard_policy.append = audit_wrapper

-- 7. End to end: notice delivery uses the capability under an open modal, and
-- attachment does not block the atomic write.
screens.child = MODAL
writes = {}
bus.pending_tasks = {}
bus.notices.child = { count = 1, message_order = { 'm1' }, message_ids = { m1 = NOTICE },
  text = NOTICE, kind = 'claude', due_at = 1000 }
attached = true
assert(N.deliver_notice('child') == true, 'an attached pane receives the notice')
assert(#writes == 1, 'an attached pane receives exactly one notice write')
assert(N.deliver_notice('child') == true, 'the notice sends through the capability')
assert(#writes == 1 and writes[1][2] == NOTICE, 'the notice is one atomic write')
assert(bus.notices.child == nil, 'transport acceptance clears the queue')
assert(not pcall(remuda.send, 'child', 'task'), 'the general gate still refuses while the modal is open')
print('Modal bypass and attached preflight: PASS')
