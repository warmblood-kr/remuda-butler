-- Actual queue + actual private core filesystem. No transport/pane/model.
local previous=remuda.butler
local noop=function()end
remuda.butler={approval={handler=noop,tick=noop},guard_policy={},approve_text={}}
dofile('packages/butler/guard_approval.lua')
local module=dofile('packages/butler/input_queue.lua')
local sha=remuda.butler.guard_approval.sha256
local function path(name)return assert(os.getenv('REMUDA_LUA_SCRATCH'))..'/queue-'..name..'.json'end
local function open(name)return assert(module.open(path(name)))end
local function request(id,text,instance,route)
 return{id=id,text=text or id,route=route or 'prepared',submission=route=='owner_line'and'composite+RET'or'composite',session='subject',agent_id='agent-id',
 session_marker='start-marker',instance_id=instance or 'instance-A',owner='@owner:fixture',event_id='$'..id,
 approval_id='APPROVAL-'..id,approval_nonce='nonce-'..id,origin_digest=sha(id)}
end
T.test('accept second and third while first waits; durable FIFO and explicit backpressure',function()
 local q=open('fifo');for i=1,3 do local r=assert(q:accept(request('r'..i)));T.eq(r.status,'queued');T.eq(r.sequence,i)end
 T.eq(#q:list(),3);T.eq(q:heads()[1].id,'r1');T.eq(#q:heads(),1)
 local r,why=q:begin('r2');T.eq(r,nil);T.eq(why,'head_blocked')
 assert(q:defer('r1','human_active'));T.eq(#q:heads(),0)
 assert(q:begin('r1'));assert(q:finish('r1','delivered','submitted'))
 T.eq(q:heads()[1].id,'r2');T.eq(#open('fifo'):list(),3,'restart retains tombstones')
 for i=4,33 do
  local r,why=q:accept(request('r'..i))
  if i<=33 then T.ok(r,why)end
 end
 local r,why=q:accept(request('overflow'));T.eq(r,nil);T.eq(why,'queue_full');T.eq(#q:list(),33)
end)
T.test('stable ID lost ACK reaffirms durability; conflicts and failed persistence never ACK',function()
 local q=open('ack');local write=remuda.fs.write_atomic;local once=true
 remuda.fs.write_atomic=function(p,b,o)
  local ok,why=write(p,b,o)
  if once then once=false;return nil,'synthetic sync failure after rename'end
  return ok,why
 end
 local r,why=q:accept(request('stable'));T.eq(r,nil);T.eq(why,'storage_uncertain')
 r=assert(q:accept(request('stable')));T.eq(r.sequence,1);T.eq(#q:list(),1)
 remuda.fs.write_atomic=write
 local other=request('stable','different');r,why=q:accept(other);T.eq(r,nil);T.eq(why,'request_id_conflict')
 local lock=remuda.fs.lock;remuda.fs.lock=function()return nil,'held'end
 r,why=q:accept(request('not-accepted'));T.eq(r,nil);T.eq(why,'storage_busy')
 remuda.fs.lock=lock;T.eq(#q:list(),1)
end)
T.test('restart preserves queued intent but quarantines dispatch uncertainty without replay',function()
 local q=open('restart');assert(q:accept(request('first')));assert(q:accept(request('second')))
 assert(q:begin('first'));q=open('restart')
 T.eq(q:get('first').status,'uncertain');T.eq(#q:heads(),0)
 local r,why=q:resolve('first','cancel','operator');T.eq(r,nil);T.eq(why,'resolution_refused')
 assert(q:resolve('first','not_sent','operator'));T.eq(q:heads()[1].id,'second')
 assert(q:quarantine('second'));T.eq(q:get('second').status,'quarantined');T.eq(#q:heads(),0)
 assert(q:accept(request('fresh','fresh payload','instance-B')))
 T.eq(q:heads()[1].id,'fresh','new instance separate stream, never retarget old')
 assert(q:resolve('second','cancel','operator'));T.eq(q:get('second').status,'cancelled')
end)
T.test('route and exact instance are immutable; corrupted stored payload fails closed',function()
 local q=open('integrity');local original=request('one','exact text','A','owner_line')
 assert(q:accept(original));local conflict=request('one','exact text','A','prepared')
 local r,why=q:accept(conflict);T.eq(r,nil);T.eq(why,'request_id_conflict')
 conflict=request('one','exact text','B','owner_line');r,why=q:accept(conflict);T.eq(r,nil);T.eq(why,'request_id_conflict')
 local f=assert(io.open(path('integrity'),'rb'));local s=remuda.json.decode(f:read('*a'));f:close()
 s.records[1].text='tampered';assert(remuda.fs.write_atomic(path('integrity'),remuda.json.encode(s),{private=true}))
 r,why=module.open(path('integrity'));T.eq(r,nil);T.eq(why,'storage_invalid')
end)
T.test('missing acknowledged ledger cannot silently reset its namespace',function()
 local q=open('missing');assert(q:accept(request('kept')))
 assert(os.remove(path('missing')))
 local r,why=q:accept(request('new'));T.eq(r,nil);T.eq(why,'storage_missing')
 r,why=module.open(path('missing'));T.eq(r,nil);T.eq(why,'storage_missing')
end)
T.test('initialization crash and malformed witness require explicit storage recovery',function()
 local write=remuda.fs.write_atomic
 remuda.fs.write_atomic=function(p,...)
  if p==path('initial-crash') then return nil,'synthetic initial ledger failure'end
  return write(p,...)
 end
 local r,why=module.open(path('initial-crash'));T.eq(r,nil);T.eq(why,'storage_uncertain')
 remuda.fs.write_atomic=write
 r,why=module.open(path('initial-crash'));T.eq(r,nil);T.eq(why,'storage_missing')
 local q=open('witness');assert(q:accept(request('retained')))
 assert(write(path('witness')..'.initialized','input-queue-v2\n',{private=true}))
 r,why=module.open(path('witness'));T.eq(r,nil);T.eq(why,'storage_witness_invalid')
end)
