-- Real classifier/gate + real notice delivery; only synthetic screens and writes.
dofile('tests/butler_dialogs.lua')
local bus = remuda._butler_bus
local screen, now, writes, busy = '', 1000, 0, false
remuda.butler.dialogs.stop()
remuda.capture = function() return screen end
remuda.session = function() return {is_busy=busy, attached=false} end
remuda.type_text = function(_, text)
  writes = writes + 1
  screen = text .. '\n› Ask Codex to do anything'
  busy = true
  return 'submitted'
end
remuda.key = function() error('notice must never press picker keys') end
remuda.butler.dialogs.install()
remuda._butler_notice_clock = function() return now end
remuda._butler_session_trace = function() end
_butler_session_trace = function() end
remuda._butler_notice_config = {
  bus=bus, resolve=function(n) return n end,
  mail_address=function(n) return {alias=n,id=n} end,
  mail_id=function(n) return n,{alias=n,id=n,kind='codex'} end,
  mail={mailbox=function() return {} end, is_unread=function() return true end,
    unread=function() return 1 end, find_message=function() return {from={alias='owner'}} end},
  take_delivery_notice_result=function() end, notify_mail_delivery=function() end,
  deliver_message=function() end,
}
dofile('packages/butler/notice.lua')
remuda._butler_send = function() return 'queued' end
local N = remuda._butler_notice
local picker = 'Select Reasoning Level for GPT-6-Luna\n\n› 1. Low\n  2. Medium (default)\n  3. Max\n\nenter default · s session · esc back'
for _, owned in ipairs({false, true}) do
  busy = false
  bus.notices.codex = {count=1,text='Synthetic mail notice',message_order={'modal-mail'},
    message_ids={['modal-mail']='Synthetic mail notice'}}
  bus.notice_recoveries.codex = nil
  local pending = bus.notices.codex
  screen = picker
  remuda._butler_state.compaction_fleet_active = owned and bus.agents.codex.id or nil
  remuda._butler_state.compaction_members = {[bus.agents.codex.id]={dialog_operation={
    agent=bus.agents.codex, model='gpt-6-luna', effort='low',phase='effort'}}}
  local before = writes
  for _=1,5 do
    now=now+1000
    assert(N.deliver_notice('codex') == false)
    assert(bus.notices.codex == pending and not pending.delivery_attempts,
      'modal wait retains queued mail without exhausting text retries')
    assert(not bus.notice_recoveries.codex and writes == before, 'no text/probe keys enter modal')
  end
  assert(bus.notice_stuck.codex, 'long modal wait is visible via bounded stuck reporting')
  -- Owner/workflow resolves it. Production path rechecks then submits once.
  remuda._butler_state.compaction_fleet_active = nil
  screen = '› Ask Codex to do anything'
  assert(N.deliver_notice('codex') == false)
  assert(writes == before+1 and bus.notice_recoveries.codex, 'delivery resumes after modal resolution')
  N.deliver_notice('codex')
  assert(not bus.notices.codex and not bus.notice_recoveries.codex, 'submission confirmed and queue cleared')
  assert(writes == before+1, 'notice submitted exactly once')
end
print('Modal notice retention and recovery: PASS')
