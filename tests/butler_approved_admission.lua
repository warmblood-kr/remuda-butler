-- Actual dialog classifier, composer policy and approved delivery; synthetic IO only.
dofile('tests/butler_dialogs.lua')
remuda.butler.dialogs.stop()
local bus = remuda._butler_bus
local screen, writes, human_idle, attached = '', 0, math.huge, false
local fail_capture, core_instance, alive = false, 'cx', true
remuda.capture = function() if fail_capture then error('synthetic capture failure') end; return screen end
remuda.capture_styled = nil
remuda.ls = function() return {{name='codex',alive=alive,attached=attached,
  human_idle=human_idle,instance_id=core_instance}} end
remuda.session = function() return {attached=attached,is_busy=true} end
remuda.type_text = function(_, bytes) writes=writes+1; assert(bytes=='exact synthetic text'); return 'submitted' end
remuda.key = function() error('no extra key or clear permitted') end
remuda._butler_notice_config = {
  bus=bus,resolve=function(n) return n end,mail_address=function() end,mail_id=function() end,
  mail={mailbox=function() return {} end},take_delivery_notice_result=function() end,
  notify_mail_delivery=function() end,deliver_message=function() end,
}
_butler_session_trace=function() end
remuda._butler_session_trace=function() end
dofile('packages/butler/notice.lua')
local handler, during_marker
remuda.butler.approval={handler=function(_, value) handler=value end,
  reply=function() return true end,
  begin_delivery=function(rec) rec.delivery_started=true; during_marker(); return true end}
remuda.cli={parse=function() error('no CLI invocation permitted') end}
local approved=dofile('packages/butler/approve_text.lua')
bus.agents.codex.parent='butler'
bus.agents.codex.session_name='codex'
bus.agents.codex.session_start_marker='synthetic-start'
bus.pending_tasks={}
local function check(frame, allow, reason, provenance)
  screen=frame
  local before=writes
  local ok,why=approved.type_text('codex','exact synthetic text',provenance or {})
  assert(ok==allow and why==reason,tostring(ok)..':'..tostring(why)..' expected '..tostring(reason))
  assert(writes==before+(allow and 1 or 0),'refusal must not attempt transport')
end
local unknown='Synthetic messy redraw\nfooter has no prompt glyph'
check(unknown,true)
assert(remuda._butler_notify_policy('codex')==false,'unsolicited notice policy is unchanged')
check('Synthetic history\n› Ask Codex to do anything',true)
check('Synthetic history\n› actual human draft',false,'composer_nonempty')
-- Menu geometry alone cannot prove the selected row is a draft. Only the
-- last/current prompt's own boundary/footer can disambiguate it.
local menu='Choose a display theme\n\n› 1. Light\n  2. Dark\n\nEnter to choose'
check(menu,true)
local numbered='────────────────────\n› 1. Light\n  2. Dark\n────────────────────\n? for shortcuts'
check(numbered,false,'composer_nonempty')
local boxed='╭──────────────────╮\n│ › 1. Light       │\n│   2. Dark        │\n╰──────────────────╯'
check(boxed,true)
check(boxed..'\n? for shortcuts',false,'composer_nonempty')
check(menu..'\n────────────────────\n› actual current draft\n────────────────────\n? for shortcuts',false,'composer_nonempty')
check('Quoted menu:\n'..menu..'\n› actual borderless draft',false,'composer_nonempty')
-- Inherently ambiguous borderless menu-shaped drafts follow unknown=allow.
check('› 1. First draft item\n  2. Second draft item',true)
check('› 1. First draft item\n  2. Second draft item\n? for shortcuts',false,'composer_nonempty')

check('Select Reasoning Level for GPT-6-Luna\n\n› 1. Low\n  2. Medium (default)\n  3. Max\n\nenter default · s session · esc back',false,'known_modal')
check('Old Select Model and Effort title\n'..unknown,true)
attached,human_idle=true,0
check(unknown,false,'human_active')
human_idle=100
check(unknown,true)
human_idle=nil
check(unknown,false,'human_pause_pending')
assert(remuda._butler_approved_text_policy('codex',os.time()+5)==true,
  'legacy human-pause guard allows unknown rendering after its pause')
human_idle=100
attached=false
bus.pending_tasks.codex=true
check(unknown,false,'workflow_owned')
bus.pending_tasks.codex=nil
remuda._butler_state.compaction_fleet_active=bus.agents.codex.id
check(unknown,false,'workflow_owned')
remuda._butler_state.compaction_fleet_active=nil
fail_capture=true
check(unknown,true)
fail_capture=false
alive=false
check(unknown,false,'session_not_live')
alive=true
check(unknown,false,'session_changed',{before_write=function() core_instance='replacement'; return true end})
core_instance='cx'
check(unknown,false,'session_changed',{before_write=function()
  bus.agents.codex.session_start_marker='replacement'; return true
end})
bus.agents.codex.session_start_marker='synthetic-start'
for _, case in ipairs({
  {reason='human_active',change=function() attached=true;human_idle=0 end},
  {reason='composer_nonempty',change=function() screen='› new draft' end},
  {reason='workflow_owned',change=function() bus.pending_tasks.codex=true end},
  {reason='session_changed',change=function() core_instance='replacement' end},
}) do
  attached,human_idle,core_instance=false,100,'cx'
  bus.pending_tasks.codex=nil
  screen=unknown
  during_marker=case.change
  local rec={id='TEST',data={session='codex',registered_text='exact synthetic text',
    bytes=#'exact synthetic text',request_id='TEST',session_id=bus.agents.codex.id,
    session_marker='synthetic-start'}}
  local before, outcome, reason=writes
  handler.approve(rec,function(ok,why) outcome,reason=ok,why end)
  assert(outcome==false and reason==case.reason,tostring(outcome)..':'..tostring(reason))
  assert(rec.delivery_started and writes==before,'post-marker refusal is terminal and writes no bytes')
end
attached,human_idle,core_instance=false,100,'cx'
bus.pending_tasks.codex=nil
screen=unknown
local saved_policy=remuda._butler_approved_text_policy
remuda._butler_approved_text_policy=function() error('synthetic policy fault') end
check(unknown,false,'input_policy_error')
remuda._butler_approved_text_policy=saved_policy
local policy_calls=0
remuda._butler_approved_text_policy=function(...)
  policy_calls=policy_calls+1
  if policy_calls==2 then
    core_instance='replacement'
    bus.agents.codex.session_start_marker='replacement'
  end
  return true
end
check(unknown,false,'session_changed',{before_write=function() return true end})
remuda._butler_approved_text_policy=saved_policy
core_instance='cx'
bus.agents.codex.session_start_marker='synthetic-start'
local capture=remuda.capture
remuda.capture=function()
  core_instance='replacement'
  bus.agents.codex.session_start_marker='replacement'
  return unknown
end
remuda._butler_approved_text_policy=function() return true end
check(unknown,false,'session_changed')
remuda.capture=capture
remuda._butler_approved_text_policy=saved_policy
core_instance='cx'
bus.agents.codex.session_start_marker='synthetic-start'
remuda.butler.dialogs.install()
local audit=remuda.butler.guard_policy.append
remuda.butler.guard_policy.append=function() return false end
check(unknown,false,'type_failed')
remuda.butler.guard_policy.append=audit
check(unknown,true)
print('butler_approved_admission: PASS')
