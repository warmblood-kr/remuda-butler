assert(assert(loadfile('tests/lib/isolated_test.lua'))()(remuda))
assert(type(remuda.db)=='table','REAL_SQL_UNAVAILABLE: never skip native SQL contract')
local target='packages/butler/inbox_progress.lua'
local file=io.open(target,'r')
if file then file:close() else target='packages/butler/inbox_progress_contract.lua' end
local json=remuda.json
local root=os.getenv('XDG_DATA_HOME')..'/qa-progress-mail'
for _,dir in ipairs({'inboxes','read','messages','objects'}) do remuda.mkdir(root..'/'..dir) end
local function write(path,text)
  local out=assert(io.open(path,'w')); assert(out:write(text)); assert(out:close())
end
write(root..'/inboxes/6161.jsonl','{"message_id":"A"}\n{"message_id":"A"}\n{"message_id":"B"}\n')
write(root..'/read/6161.jsonl','B\nORPHAN\n')
write(root..'/read/6262.jsonl','READ_ONLY\n')
local db=assert(remuda._qa_native_inbox_handle,'test-owned mod must open native inbox DB')
remuda._butler_inbox_db_config={root=root,open=function() return db end}
dofile('packages/butler/inbox_db.lua')
assert(remuda._butler_inbox_db.import_all(),'existing585 importer failed actual SQL')
assert(remuda._butler_inbox_db.count('aa','inbox')==2,'actual585 import missing identities')
assert(remuda._butler_inbox_db.count('aa','read')==2,'actual585 whole read set missing')
local counts={exec=0,query=0,closed=0}
local function borrowed(options)
  options=options or {}
  return {exec=function(_,sql,params)
    counts.exec=counts.exec+1
    if options.fail_statement and sql:match('^%s*[Ii][Nn][Ss][Ee][Rr][Tt]') then
      return nil,'sql: injected statement failure'
    end
    local result,why=db:exec(sql,params)
    if options.lost_commit and sql:match('^%s*[Cc][Oo][Mm][Mm][Ii][Tt]') then
      assert(result~=nil,'real COMMIT failed before lost-return injection')
      return nil,'timeout: injected lost COMMIT return'
    end
    return result,why
  end,query=function(_,sql,params)
    counts.query=counts.query+1
    return db:query(sql,params)
  end,close=function() counts.closed=counts.closed+1; error('borrower closed owner handle') end}
end
local function backend(options)
  local product=dofile(target)
  local result,err=product.open({db=borrowed(options),root=root,json={encode=json.encode,decode=json.decode}})
  assert(result,'progress open rejected '..tostring(err and err.code))
  return result
end
local function cursor(generation)
  return {protocol_version=2,generation=generation,phase='logs1',log='inbox',offset=0,parse_offset=0,
    line_tail='',chain=string.rep('0',64),next_seq=1,complete=false}
end
local function state(progress,recipient)
  local value,err=progress.load(root,recipient)
  assert(value,'load failed '..tostring(err and err.code))
  return value
end
local function create(progress,recipient,generation)
  local value,err=progress.commit(root,recipient,0,cursor(generation),{
    {op='delivery',message_id='A',seq=1,resent='{"note":"R"}'},
    {op='delivery',message_id='A',seq=1},
    {op='delivery',message_id='B',seq=2},
    {op='read',message_id='ORPHAN'}})
  assert(value and value.revision==1,'initial atomic create failed '..tostring(err and err.code))
  return value
end
local failures,total={},0
local function test(name,fn)
  total=total+1
  local ok,err=pcall(fn)
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
test('real585 borrowed handle initial absence create and reopened parity',function()
  local progress=backend()
  local absent,err=progress.load(root,'6363')
  assert(absent==nil and err and err.code=='not_found','missing state not proven absent')
  create(progress,'6363','generation-C')
  assert(counts.exec>0 and counts.query>0,'native SQL not exercised')
  db:close(); db=assert(remuda._qa_reopen_inbox())
  progress=backend()
  local restored=state(progress,'6363')
  assert(restored.revision==1 and restored.cursor.generation=='generation-C','durable cursor lost')
  local first=assert(progress.scan(root,'6363','generation-C','deliveries',nil,1))
  assert(#first.rows==1 and first.rows[1].message_id=='A' and first.rows[1].seq==1,'first distinct order lost')
  assert(first.rows[1].resent=='{"note":"R"}','plain duplicate cleared last PRESENT')
  assert(not first.complete and first.next_key,'page1 incorrectly terminal')
  local second=assert(progress.scan(root,'6363','generation-C','deliveries',first.next_key,1))
  assert(#second.rows==1 and second.rows[1].message_id=='B' and second.complete,'page2 canonical order lost')
  assert(counts.closed==0,'backend closed borrowed handle')
end)
test('two recipients keep independent revisions and rows',function()
  local progress=backend()
  create(progress,'6464','generation-D')
  local a,b=state(progress,'6363'),state(progress,'6464')
  assert(a.cursor.generation=='generation-C' and b.cursor.generation=='generation-D','recipient cursors crossed')
  assert(a.revision==1 and b.revision==1,'recipient revisions crossed')
end)
test('stale CAS changes neither revision nor rows',function()
  local progress=backend()
  local value,err=progress.commit(root,'6363',0,cursor('generation-C'),{{op='read',message_id='NEVER'}})
  assert(value==nil and err and err.code=='stale_generation','stale CAS admitted')
  assert(state(progress,'6363').revision==1,'stale CAS advanced cursor')
  local row=assert(progress.get(root,'6363','generation-C','delivery','A'))
  assert(row.message_id=='A','stale CAS destroyed prior delivery')
  local reads=assert(progress.scan(root,'6363','generation-C','reads',nil,10))
  assert(reads.complete and #reads.rows==1 and reads.rows[1].message_id=='ORPHAN','stale CAS changed exact read set')
end)
test('statement failure rolls back rows and cursor',function()
  local progress=backend({fail_statement=true})
  local next=cursor('generation-C');next.offset=64
  local value,err=progress.commit(root,'6363',1,next,{{op='delivery',message_id='NEVER',seq=3}})
  assert(value==nil and err and err.code=='not_committed','statement failure not known rollback')
  local clean=backend()
  assert(state(clean,'6363').revision==1,'failed statement advanced cursor')
  local rows=assert(clean.scan(root,'6363','generation-C','deliveries',nil,10))
  assert(#rows.rows==2,'failed batch left a delivery')
end)
test('actual COMMIT lost return reconciles after close reopen',function()
  local progress=backend({lost_commit=true})
  local next=cursor('generation-C');next.offset=64
  local value,err=progress.commit(root,'6363',1,next,{{op='delivery',message_id='C',seq=3}})
  assert(value==nil and err and err.code=='unknown_commit','lost COMMIT not uncertain')
  assert(err.expected_revision==1 and err.next_revision==2 and err.generation=='generation-C','reconciliation identity missing')
  db:close(); db=assert(remuda._qa_reopen_inbox())
  local recovered=backend()
  assert(state(recovered,'6363').revision==2,'committed cursor not durable')
  local rows=assert(recovered.scan(root,'6363','generation-C','deliveries',nil,10))
  assert(#rows.rows==3 and rows.rows[3].message_id=='C','committed row lost or duplicated')
end)
test('partial stage cannot be promoted by empty ready guess',function()
  local progress=backend()
  local next=cursor('generation-D');next.phase='ready';next.complete=true
  local value,err=progress.commit(root,'6464',1,next,{{op='ready',witness='source-progress-v2:sha256:'..string.rep('0',64),first_chain=string.rep('0',64),second_chain=string.rep('0',64)}})
  assert(value==nil and err,'incomplete stage became ready')
  assert(not state(progress,'6464').cursor.complete,'partial state published')
end)
test('same borrowed DB rejects or isolates other root commit scan get',function()
  local product=dofile(target)
  local other_root=root..'-other'
  local alternate=product.open({db=borrowed(),root=other_root,json={encode=json.encode,decode=json.decode}})
  if not alternate then return end
  local value=alternate.load(other_root,'6363')
  assert(value==nil,'different root read existing cursor')
  local created=alternate.commit(other_root,'6363',0,cursor('generation-C'),{{op='delivery',message_id='X',seq=1}})
  if not created then created=alternate.commit(other_root,'6363',0,cursor('generation-C'),{}) end
  if created then
    local rows=assert(alternate.scan(other_root,'6363','generation-C','deliveries',nil,10))
    for _,row in ipairs(rows.rows) do assert(row.message_id=='X','other root exposed original delivery '..row.message_id) end
    local found=alternate.get(other_root,'6363','generation-C','delivery','A')
    assert(found and found.state=='absent','other root get exposed original A')
  end
  local original=assert(backend().scan(root,'6363','generation-C','deliveries',nil,10))
  assert(#original.rows==3 and original.rows[1].message_id=='A' and original.rows[3].message_id=='C','other root changed original deliveries')
  local reads=assert(backend().scan(root,'6363','generation-C','reads',nil,10))
  assert(#reads.rows==1 and reads.rows[1].message_id=='ORPHAN','other root changed original read set')
end)
test('unknown generation cannot masquerade as empty scan',function()
  local value,err=backend().scan(root,'6363','missing-generation','deliveries',nil,10)
  assert(value==nil and err and err.code=='source_unreadable','unknown generation answered empty')
end)
test('delivery scans carry exact staged metadata and content refs',function()
  local progress=backend(); create(progress,'6565','generation-E')
  local next=cursor('generation-E')
  assert(progress.commit(root,'6565',1,next,{{op='metadata',message_id='A',
    envelope_ref='messages/A.json',object_ref='objects/object-A',metadata='{"preserve":"opaque"}'}}))
  local rows=assert(progress.scan(root,'6565','generation-E','deliveries',nil,10))
  assert(rows.rows[1].envelope_ref=='messages/A.json' and rows.rows[1].object_ref=='objects/object-A','scan dropped content refs')
  assert(rows.rows[1].metadata=='{"preserve":"opaque"}','scan lost canonical metadata')
end)
test('shared dependency path enumerated once',function()
  local progress=backend();create(progress,'6666','generation-F')
  assert(progress.commit(root,'6666',1,cursor('generation-F'),{
    {op='dependency',owner='A',role='body',path='objects/shared'},
    {op='dependency',owner='B',role='body',path='objects/shared'}}))
  local rows=assert(progress.scan(root,'6666','generation-F','dependencies',nil,10))
  assert(rows.complete and #rows.rows==1 and rows.rows[1].path=='objects/shared','shared dependency duplicated')
end)
test('keyset chunkproof pagination retains both passes at same offset',function()
  local progress=backend();create(progress,'6767','generation-G')
  local delta={}
  for pass=1,2 do delta[pass]={op='chunkproof',pass=pass,path='inboxes/6767.jsonl',
    offset=0,bytes=8,sha256=string.rep('a',64),eof=true} end
  assert(progress.commit(root,'6767',1,cursor('generation-G'),delta))
  local first=assert(progress.scan(root,'6767','generation-G','chunkproofs',nil,1))
  assert(#first.rows==1 and not first.complete and first.next_key,'proof page1 not bounded')
  local second=assert(progress.scan(root,'6767','generation-G','chunkproofs',first.next_key,1))
  assert(second.complete and #second.rows==1,'proof pass lost after keyset cursor')
  assert(first.rows[1].pass~=second.rows[1].pass,'same proof pass repeated')
end)
test('delta budget rejects257 rows atomically',function()
  local progress=backend();create(progress,'6868','generation-H')
  local delta={}
  for index=1,257 do delta[index]={op='read',message_id='R'..index} end
  local value,err=progress.commit(root,'6868',1,cursor('generation-H'),delta)
  assert(value==nil and err and err.code=='invalid_snapshot','oversized delta admitted')
  assert(state(progress,'6868').revision==1,'oversized delta advanced cursor')
end)
test('invalid generation record is durable not an unknown operation',function()
  local progress=backend();create(progress,'6969','generation-I')
  local next=cursor('generation-I');next.phase='invalid'
  local value,err=progress.commit(root,'6969',1,next,{{op='invalid',reason='stale_generation'}})
  assert(value and value.revision==2,'defined invalid operation rejected '..tostring(err and err.code))
  assert(state(progress,'6969').cursor.phase=='invalid','invalid generation not durable')
end)
test('complete cursor cannot bypass ready proof with empty delta',function()
  local progress=backend();create(progress,'7070','generation-J')
  local next=cursor('generation-J');next.phase='ready';next.complete=true
  local value,err=progress.commit(root,'7070',1,next,{})
  assert(value==nil and err,'complete cursor bypassed ready operation')
  assert(not state(progress,'7070').cursor.complete,'bypass published partial generation')
end)
local function mismatched_proof_test(recipient,generation,second_path,second_hash)
  local progress=backend()
  assert(progress.commit(root,recipient,0,cursor(generation),{}))
  local phase2=cursor(generation);phase2.phase='files2'
  assert(progress.commit(root,recipient,1,phase2,{
    {op='fileproof',pass=1,path='objects/A',present=true,bytes=4,sha256=string.rep('a',64)},
    {op='fileproof',pass=2,path=second_path,present=true,bytes=4,sha256=second_hash}}))
  local ready=cursor(generation);ready.phase='ready';ready.complete=true
  local value,err=progress.commit(root,recipient,2,ready,{{op='ready',
    witness='source-progress-v2:sha256:'..string.rep('0',64),first_chain=string.rep('0',64),second_chain=string.rep('0',64)}})
  assert(value==nil and err,'same-count mismatched proof streams certified')
  assert(state(progress,recipient).revision==2 and not state(progress,recipient).cursor.complete,'mismatched proofs published')
end
test('same-count different proof paths cannot become ready',function()
  mismatched_proof_test('7171','generation-K','objects/B',string.rep('a',64))
end)
test('same-count same-path changed proof digest cannot become ready',function()
  mismatched_proof_test('7272','generation-L','objects/A',string.rep('b',64))
end)
test('equal complete empty-source proof sets permit ready',function()
  local progress=backend()
  assert(progress.commit(root,'8181',0,cursor('generation-ready'),{}))
  local proof={}
  for pass=1,2 do
    for _,path in ipairs({'inboxes/8181.jsonl','read/8181.jsonl'}) do
      proof[#proof+1]={op='fileproof',pass=pass,path=path,present=false,bytes=0,
        sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'}
    end
  end
  local phase2=cursor('generation-ready');phase2.phase='files2'
  assert(progress.commit(root,'8181',1,phase2,proof))
  local ready=cursor('generation-ready');ready.phase='ready';ready.complete=true
  local value,err=progress.commit(root,'8181',2,ready,{{op='ready',
    witness='source-progress-v2:sha256:'..string.rep('0',64),first_chain=string.rep('0',64),second_chain=string.rep('0',64)}})
  assert(value and value.revision==3,'valid staged readiness rejected '..tostring(err and err.code))
  assert(state(progress,'8181').cursor.complete,'valid ready cursor not durable')
end)
test('unknown cursor field cannot hide mailbox state',function()
  local progress=backend()
  local next=cursor('generation-extra');next.deliveries={'HIDDEN'}
  local before=counts.exec
  local value,err=progress.commit(root,'8282',0,next,{})
  assert(value==nil and err and err.code=='invalid_snapshot','unknown cursor field accepted')
  assert(counts.exec==before,'invalid cursor began a SQL mutation')
end)
test('line tail over1MiB rejected before transaction',function()
  local progress=backend()
  local next=cursor('generation-tail');next.line_tail=string.rep('x',1024*1024+1)
  local before=counts.exec
  local value,err=progress.commit(root,'8383',0,next,{})
  assert(value==nil and err and err.code=='invalid_snapshot','unbounded line tail accepted')
  assert(counts.exec==before,'oversized tail began a SQL mutation')
end)
if #failures>0 then error('native SQL progress '..#failures..'/'..total..' failed ['..target..']\n'..table.concat(failures,'\n')) end
print('PASS native SQL progress '..total..' cases (existing585 importer, real commits/reopen)')
