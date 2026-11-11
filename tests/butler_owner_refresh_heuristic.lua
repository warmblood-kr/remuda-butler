local now,calls,instance=0,0,'i1'
remuda={clock=function()return now end,ls=function()return {{name='a',alive=true,instance_id=instance}} end,
 capture=function()return 'pane' end,_session_refresh=function()calls=calls+1;return true end}
local gate=dofile('packages/butler/owner_refresh.lua')
assert(gate.step('a','one','i1')=='pending' and calls==1)
now=299;assert(gate.step('a','one','i1')=='pending')
now=301;assert(gate.step('a','one','i1')=='ready','quiet app cannot block input forever')
assert(calls==1);gate.finish('a','one')
now=1000;assert(gate.step('a','two','i1')=='pending');instance='i2';now=1301
local phase,reason=gate.step('a','two','i1');assert(phase=='failed' and reason=='session_changed')
gate.finish('a','two');instance='i1';now=2000;assert(gate.step('a','three','i1')=='pending')
remuda.capture=function()return nil end;now=2301
phase,reason=gate.step('a','three','i1');assert(phase=='failed' and reason=='refresh_capture_unavailable')
print('ok - bounded best effort refresh, instance and capture checks')
