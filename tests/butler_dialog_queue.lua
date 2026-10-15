-- Guarded queue handoff only; synthetic IO, no daemon or input endpoint.
dofile('tests/butler_dialogs.lua')
remuda.butler.dialogs.stop()
local calls,before,recheck,identity=0,0,0,0
local outcome,audit_failure='tuple',false
remuda.capture=function()return'synthetic unknown renderer'end
remuda._butler_dialog_originals=nil
remuda.type_text=function()
 calls=calls+1
 if outcome=='throw'then error('synthetic partial')end
 if outcome=='false'then return false,'refused'end
 return'submitted',42,nil,'tail'
end
local audits={}
remuda.butler.guard_policy.append=function(record)audits[#audits+1]=record;return not audit_failure end
remuda._butler_queue_bound_provider={identity_fenced=true,
 type_text=function(name,instance,...)assert(instance=='cx');return remuda._butler_dialog_originals.type_text(name,...)end,
 key=function(name,instance,...)assert(instance=='cx');return remuda._butler_dialog_originals.key(name,...)end}
dofile('packages/butler/dialogs.lua');local dialogs=remuda.butler.dialogs;dialogs.install()
local write;assert(dialogs.register_queue_writer(function(cap)write=cap end))
assert(not dialogs.register_queue_writer(function()error('second owner')end))
local function hooks(value)
 return{expected_instance='cx',before=function()before=before+1;if value=='throw'then error('marker')end;return value end,
 recheck=function()recheck=recheck+1;return true end,identity=function()identity=identity+1;return true end}
end
for _,value in ipairs({false,'throw','nil'})do
 local h=hooks(value=='nil'and nil or value)
 if value=='nil'then h.before=function()before=before+1;return nil end end
 local count=recheck
 assert(not pcall(write,'type_text','codex',h,'exact'))
 assert(calls==0 and recheck==count,'failed before never runs recheck or core')
end
audit_failure=true;local count=before
assert(not pcall(write,'type_text','codex',hooks(true),'exact'));assert(calls==0 and before==count)
audit_failure=false
local h=hooks(true);h.recheck=function()return nil end
assert(not pcall(write,'type_text','codex',h,'exact'));assert(calls==0)
h=hooks(true);h.identity=function()return false end
assert(not pcall(write,'type_text','codex',h,'exact'));assert(calls==0)
local a,b,c,d=write('type_text','codex',hooks(true),'exact')
assert(calls==1 and a=='submitted'and b==42 and c==nil and d=='tail','original return tuple preserved')
outcome='false';a,b=write('type_text','codex',hooks(true),'exact');assert(calls==2 and a==false and b=='refused')
outcome='throw';assert(not pcall(write,'type_text','codex',hooks(true),'exact'));assert(calls==3)
dialogs.stop();count=before
assert(not pcall(write,'type_text','codex',hooks(true),'exact'));assert(calls==3 and before==count)
print('butler dialog queue handoff: PASS')
