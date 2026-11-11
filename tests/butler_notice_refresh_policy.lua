local agent={id='a',kind='codex',instance_id='i'}
local events, phase={},'pending'
remuda={_butler_notice={},_butler_bus={agents={member=agent}},butler={dialogs={automatic_notice_send=function() events[#events+1]='write';return true end}}}
local policy=dofile('packages/butler/send_policy.lua')
local seam={blocked=function() return false end,unavailable=function()return false end,
 prepare=function(adapter) events[#events+1]='prepare';assert(adapter.route=='legacy');return phase end,
 reserve=function() events[#events+1]='reserve';return {ids={'x'},text='hi',still_current=function()return true end} end,
 resolve=function(sent)events[#events+1]='resolve';return sent end}
assert(policy.bind(remuda._butler_notice,function()return seam end))
assert(policy.send_message('member')==false)
assert(table.concat(events,',')=='prepare','pending refresh must precede reservation and write')
events={};phase='ready';assert(policy.send_message('member')==true)
assert(table.concat(events,',')=='prepare,reserve,write,resolve','ready then exactly one reservation/write')
print('ok - PTY preparation gates journal and transport')
