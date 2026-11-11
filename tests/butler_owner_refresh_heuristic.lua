local now, seq, calls, instance, screen = 0, '9007199254740993', 0, 'i1', 'pane'
remuda = {capture=function() return screen end,clock=function() return now end,
 ls=function() return {{name='agent',alive=true,instance_id=instance,output_idle=0.5}} end,
 _session_pty_output_sequence=function(name,id) assert(name=='agent' and id=='i1');return seq end,
 _session_refresh=function(name,id) assert(name=='agent' and id=='i1');calls=calls+1;return true end}
local gate = dofile('packages/butler/owner_refresh.lua')
assert(gate.step('agent','a','i1')=='pending' and calls==1)
now=400;assert(gate.step('agent','a','i1')=='pending','resize is not output')
seq='9007199254740994';now=500;assert(gate.step('agent','a','i1')=='pending','wait after output')
now=650;assert(gate.step('agent','a','i1')=='pending')
now=701;assert(gate.step('agent','a','i1')=='ready' and calls==1)
gate.finish('agent','a')
now=1000;assert(gate.step('agent','b','i1')=='pending');instance='i2';now=1500
local state,why=gate.step('agent','b','i1');assert(state=='failed' and why=='session_changed')
gate.finish('agent','b');instance='i1';now=2000;assert(gate.step('agent','c','i1')=='pending')
now=7100;state,why=gate.step('agent','c','i1');assert(state=='failed' and why=='refresh_unconfirmed')
gate.finish('agent','c');remuda._session_pty_output_sequence=nil
state,why=gate.step('agent','d','i1');assert(state=='failed' and why=='refresh_observation_unavailable')
remuda._session_pty_output_sequence=function()return seq end
now=8000;assert(gate.step('agent','e','i1')=='pending');seq='9007199254740995';now=8100;assert(gate.step('agent','e','i1')=='pending')
screen=nil;now=8400;state,why=gate.step('agent','e','i1');assert(state=='failed' and why=='refresh_capture_unavailable')
print('ok - actual output sequence gate; quiet is heuristic')
gate.finish('agent','e');screen='pane';now=9000;seq='40';assert(gate.step('agent','f','i1')=='pending')
seq='41';now=9100;assert(gate.step('agent','f','i1')=='pending')
remuda.capture=function()seq='42';return 'pane' end
now=9400;assert(gate.step('agent','f','i1')=='pending','output during capture restarts quiet window')
remuda.capture=function()return 'pane' end
now=9601;assert(gate.step('agent','f','i1')=='ready')
gate.finish('agent','f');now=10000;seq='50';assert(gate.step('agent','g','i1')=='pending')
seq='51';now=10100;assert(gate.step('agent','g','i1')=='pending')
remuda.capture=function()instance='i2';return 'pane' end
now=10400;state,why=gate.step('agent','g','i1');assert(state=='failed' and why=='session_changed')
print('ok - output and session changes during capture hold input')
