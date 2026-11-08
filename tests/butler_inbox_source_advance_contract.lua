assert(assert(loadfile('tests/lib/isolated_test.lua'))()(remuda))
assert(type(remuda.db)=='table','REAL_SQL_UNAVAILABLE: native gate cannot skip')
local F=dofile('tests/lib/qa_inbox_source_fixture.lua')
local source_module=dofile('packages/butler/inbox_source.lua')
local progress_module=dofile('packages/butler/inbox_progress.lua')
local root,base,envelopes=F.fixture()
local json=remuda.json
local db=assert(remuda._qa_native_inbox_handle)
local function size(path)
  local file,_,errno=io.open(path,'rb')
  if not file then return nil,{code=errno==2 and 'not_found' or 'io'} end
  local bytes=file:seek('end');file:close();return bytes
end
local function range(path,offset,limit)
  local file,_,errno=io.open(path,'rb')
  if not file then return nil,{code=errno==2 and 'not_found' or 'io'} end
  assert(file:seek('set',offset))
  local bytes=file:read(limit) or ''
  local position=file:seek();local length=file:seek('end');file:close()
  return {bytes=bytes,eof=position>=length}
end
base.fs.size=size;base.fs.read_range=range
base.max_single_file_bytes=16384
remuda._butler_inbox_db_config={root=root,open=function() return db end}
dofile('packages/butler/inbox_db.lua')
assert(remuda._butler_inbox_db.import_all(),'real585 importer unavailable')
local function clone_recipient(recipient)
  F.write(root..'/inboxes/'..recipient..'.jsonl',assert(F.read(root..'/inboxes/6161.jsonl')))
  F.write(root..'/read/'..recipient..'.jsonl',assert(F.read(root..'/read/6161.jsonl')))
end
local function configure(recipient,options)
  options=options or {}
  db:close();db=assert(remuda._qa_reopen_inbox())
  local lost=false
  local borrowed={query=function(_,sql,params) return db:query(sql,params) end,
    exec=function(_,sql,params)
      local result,err=db:exec(sql,params)
      if options.lost_commit and not lost and sql:match('^%s*[Cc][Oo][Mm][Mm][Ii][Tt]') then
        assert(result~=nil,'underlying native COMMIT failed');lost=true
        return nil,'timeout: lost durable COMMIT return'
      end
      return result,err
    end}
  local progress=assert(progress_module.open({db=borrowed,root=root,json={encode=json.encode,decode=json.decode}}))
  if options.watch_scan then
    local original=progress.scan
    progress.scan=function(r,p,g,k,a,l)
      options.watch_scan(k,a,l)
      return original(r,p,g,k,a,l)
    end
  end
  local cfg={root=root,json=base.json,sha256=base.sha256,progress=progress,
    max_single_file_bytes=options.max_file or base.max_single_file_bytes,
    fs={list=base.fs.list,read=options.read or base.fs.read,read_range=range,size=size}}
  local source,err=source_module.open(cfg)
  assert(source,'source open refused '..tostring(err and err.code))
  assert(type(source.advance)=='function','SOURCE_ADVANCE_UNIMPLEMENTED')
  return source,progress
end
local budget={max_bytes=1024,max_tasks=1,max_ms=10}
local function advance(recipient,previous,options)
  local source,progress=configure(recipient,options)
  local result,err=source:advance(root,recipient,budget)
  if not result then return nil,err,progress end
  assert(result.processed_tasks<=1,'task budget exceeded')
  assert(result.complete==(result.state=='ready'),'readiness inconsistent')
  if not result.complete then assert(result.snapshot==nil,'partial snapshot escaped') end
  local cursor=assert(result.cursor,'durable cursor missing')
  local persisted=assert(progress.load(root,recipient))
  assert(persisted.cursor.protocol_version==2,'durable cursor protocol is not v2')
  if previous then
    assert(cursor.generation==previous.generation,'budget/reopen reset generation')
    assert(cursor.revision>=previous.revision,'revision moved backward')
  end
  return result,nil,progress
end
local function same_deliveries(actual,expected)
  if #actual~=#expected then return false end
  if #actual==0 then return true end
  return F.canonical(actual)==F.canonical(expected)
end
local function same_reads(actual,expected)
  for id,value in pairs(actual) do if expected[id]~=value then return false end end
  for id,value in pairs(expected) do if actual[id]~=value then return false end end
  return true
end
local function finish(recipient,expected,first_options)
  local previous,ready
  for call=1,160 do
    local result,err=advance(recipient,previous,call==1 and first_options or nil)
    if result then
      previous=result.cursor
      if result.complete then ready=result.snapshot;break end
    else
      assert(err and err.code=='unknown_commit','advance failed '..tostring(err and err.code))
    end
  end
  assert(ready,'bounded calls starved before ready')
  assert(same_deliveries(ready.deliveries,expected.deliveries),'final ordered metadata drift')
  assert(same_reads(ready.reads,expected.reads),'final read set drift')
  assert(ready.witness:match('^source%-progress%-v2:sha256:%x+$'),'wrong progress witness version')
  return ready
end
local failures,total={},0
local function test(name,fn)
  total=total+1
  local ok,err=pcall(fn)
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local expected=F.snapshot(F.open(base),root)
-- Exceeds per-call task/byte budget without a synchronous large snapshot.
for _,id in ipairs({'C','D','E','F','G','H'}) do
  local envelope=assert(json.decode(assert(json.encode(envelopes.A))))
  envelope.id=id;envelope.body.object_id='object-'..id;envelope.body.bytes=2048
  envelope.matrix.event_id='$'..id
  local body=string.rep(id,2048)
  F.write(root..'/messages/'..id..'.json',assert(json.encode(envelope)))
  F.write(root..'/objects/object-'..id,body)
  local out=assert(io.open(root..'/inboxes/6161.jsonl','a'))
  assert(out:write('{"message_id":"'..id..'"}\n'));out:close()
  expected.deliveries[#expected.deliveries+1]={message_id=id,seq=#expected.deliveries+1,
    envelope_ref='messages/'..id..'.json',object_ref='objects/object-'..id,
    metadata=F.canonical({envelope=envelope,object={id='object-'..id,bytes=2048,sha256=F.sha(body)}})}
end
test('single mailbox progresses across task1 calls and reopened adapters',function()
  finish('6161',expected)
end)
test('two interleaved callers keep independent durable cursors',function()
  clone_recipient('7373');clone_recipient('7474')
  local cursors,completed={},{}
  for _=1,160 do
    for _,recipient in ipairs({'7373','7474'}) do
      if not completed[recipient] then
        local result,err=advance(recipient,cursors[recipient])
        assert(result,'interleaved call failed '..tostring(err and err.code))
        cursors[recipient]=result.cursor
        if result.complete then
          assert(same_deliveries(result.snapshot.deliveries,expected.deliveries),'recipient content drift')
          completed[recipient]=true
        end
      end
    end
    if completed['7373'] and completed['7474'] then break end
  end
  assert(completed['7373'] and completed['7474'],'one interleaved caller starved')
  assert(cursors['7373'].generation~=nil and cursors['7474'].generation~=nil,'durable recipient cursors missing')
end)
test('oversize content refused before whole-file read',function()
  clone_recipient('7575')
  local opens=0
  local function watched(path) opens=opens+1; return base.fs.read(path) end
  local err
  for _=1,40 do
    local result,why=advance('7575',nil,{max_file=3,read=watched})
    if not result then err=why;break end
    assert(not result.complete,'oversize source became ready')
  end
  assert(err and err.code=='source_oversize','oversize became perpetual backlog or wrong error')
  assert(opens==0,'oversize was read before size refusal')
end)
test('lost real COMMIT return resumes same durable stage without duplicate',function()
  clone_recipient('7676')
  finish('7676',expected,{lost_commit=true})
end)
test('between-checkpoint same-size dependency mutation invalidates generation',function()
  clone_recipient('7777')
  local previous,changed,observed=false,false,nil
  for _=1,160 do
    local result,err,progress=advance('7777',previous or nil)
    if not result then observed=err;break end
    previous=result.cursor
    local proofs=assert(progress.scan(root,'7777',previous.generation,'fileproofs',nil,256))
    if not changed then
      for _,proof in ipairs(proofs.rows) do
        if proof.pass==1 and proof.path=='objects/object-A' then
          F.write(root..'/objects/object-A','bOdy');changed=true
        end
      end
    end
    if result.complete then break end
  end
  F.write(root..'/objects/object-A','body')
  assert(changed,'test never reached durable pass1 body proof')
  assert(observed and observed.code=='stale_generation','changed dependency was certified or silently restarted')
end)
test('read-only orphan recipient progresses through absent inbox',function()
  local source=F.open(base)
  local orphan=assert(source:snapshot(root,'6262'))
  finish('6262',orphan)
end)
test('torn EOF reports partial and completed append resumes durable cursor',function()
  clone_recipient('7878')
  F.write(root..'/read/7878.jsonl','B\nORPH')
  local before,observed
  for _=1,30 do
    local result,err,progress=advance('7878',before)
    if not result then
      observed=err
      local loaded=progress.load(root,'7878')
      before=loaded and {generation=loaded.cursor.generation,revision=loaded.revision} or before
      break
    end
    before=result.cursor
    assert(not result.complete,'torn source became ready')
  end
  assert(observed and observed.code=='partial','torn EOF became perpetual backlog or wrong error')
  local out=assert(io.open(root..'/read/7878.jsonl','a'));assert(out:write('AN\n'));out:close()
  local ready
  for _=1,160 do
    local result,err=advance('7878',before)
    assert(result,'completed tail failed '..tostring(err and err.code))
    before=result.cursor
    if result.complete then ready=result.snapshot;break end
  end
  assert(ready and same_reads(ready.reads,expected.reads),'tail completion did not preserve whole read set')
end)
local function seed_completed_prefix(progress,recipient,generation)
  local records={}
  for index=1,300 do records[#records+1]={op='delivery',message_id=string.format('P%03d',index),seq=index} end
  local body_digest=F.sha('body')
  for index=1,257 do
    local id=string.format('P%03d',index)
    local envelope=assert(json.decode(assert(json.encode(envelopes.A))))
    envelope.id=id
    local encoded=assert(json.encode(envelope))
    F.write(root..'/messages/'..id..'.json',encoded)
    if index<=256 then
      records[#records+1]={op='dependency',owner=id,role='envelope',path='messages/'..id..'.json'}
      records[#records+1]={op='dependency',owner=id,role='body',path='objects/object-A'}
      records[#records+1]={op='fileproof',pass=1,path='messages/'..id..'.json',present=true,bytes=#encoded,sha256=F.sha(encoded)}
      records[#records+1]={op='fileproof',pass=1,path='objects/object-A',present=true,bytes=4,sha256=body_digest}
      records[#records+1]={op='metadata',message_id=id,envelope_ref='messages/'..id..'.json',object_ref='objects/object-A',
        metadata=F.canonical({envelope=envelope,object={id='object-A',bytes=4,sha256=body_digest}})}
    end
  end
  local revision=0
  for start=1,#records,256 do
    local delta={}
    for index=start,math.min(start+255,#records) do delta[#delta+1]=records[index] end
    local cursor={protocol_version=2,generation=generation,phase='files1',offset=0,parse_offset=0,line_tail='',
      chain=string.rep('0',64),next_seq=301,complete=false}
    local result=assert(progress.commit(root,recipient,revision,cursor,delta))
    revision=result.revision
  end
end
test('one discovery page checkpoints and reopens before scanning next page',function()
  local _,progress=configure('7979')
  seed_completed_prefix(progress,'7979','generation-discovery')
  local pages=0
  local result,err=advance('7979',nil,{watch_scan=function(kind)
    if kind=='deliveries' then pages=pages+1 end
  end})
  assert(result,'discovery failed '..tostring(err and err.code))
  assert(pages<=1,'task1 scanned '..pages..' whole-mailbox delivery pages')
  local _,reopened=configure('7979')
  local saved=assert(reopened.load(root,'7979'))
  assert(saved.cursor.after_key~=nil,'discovery page made no durable after_key progress')
  local next_pages,after=0,nil
  local resumed,why=advance('7979',result.cursor,{watch_scan=function(kind,key)
    if kind=='deliveries' then next_pages=next_pages+1;after=key end
  end})
  assert(resumed,'reopened discovery failed '..tostring(why and why.code))
  assert(next_pages<=1 and after~=nil,'reopened discovery restarted at first page')
end)
local function absent_chain(recipient,version)
  local protocol=version==2 and 'source-progress-v2' or 'source-progress-v1'
  local function frame(values)
    local parts={}
    for _,value in ipairs(values) do parts[#parts+1]=#value..':'..value end
    return table.concat(parts)
  end
  local chain=F.sha(frame({protocol,root,recipient}))
  for _,path in ipairs({'inboxes/'..recipient..'.jsonl','read/'..recipient..'.jsonl'}) do
    chain=F.sha(frame({chain,path,'absent','0','0',F.sha('')}))
  end
  return chain,protocol
end
local function seed_protocol(recipient,version,phase)
  local source,progress=configure(recipient)
  local chain,protocol=absent_chain(recipient,version)
  local cursor={protocol_version=version,generation='protocol-'..recipient,phase=phase,
    offset=0,parse_offset=0,line_tail='',chain=chain,next_seq=1,complete=phase=='ready'}
  local delta={}
  if phase=='ready' then
    cursor.first_chain=chain;cursor.witness=protocol..':sha256:'..chain
    delta={{op='ready',witness=cursor.witness,first_chain=chain,second_chain=chain}}
  end
  local seeded,err=progress.commit(root,recipient,0,cursor,delta)
  assert(seeded,'protocol fixture failed '..tostring(err and err.code))
  return source,progress
end
local function valid_protocol_control(recipient,phase)
  seed_protocol(recipient,2,phase)
  local ready
  for _=1,12 do
    local source=configure(recipient)
    local result,err=source:advance(root,recipient,budget)
    assert(result,'v2 control refused '..tostring(err and err.code))
    if result.complete then ready=result;break end
  end
  assert(ready and #ready.snapshot.deliveries==0 and next(ready.snapshot.reads)==nil,'v2 control not complete empty')
end
test('independent v2 framed cross-order shared-path witness and reopen',function()
  local recipient='8787'
  for _,id in ipairs({'QA','QB'}) do
    local envelope=assert(json.decode(assert(json.encode(envelopes.A))))
    envelope.id=id;envelope.body.object_id='protocol-shared';envelope.body.bytes=4
    F.write(root..'/messages/'..id..'.json',assert(json.encode(envelope)))
  end
  F.write(root..'/objects/protocol-shared','DATA');F.write(root..'/objects/protocol-note','NOTE')
  F.write(root..'/inboxes/'..recipient..'.jsonl','{"message_id":"QA","resent":{"note_object_id":"protocol-note"}}\n{"message_id":"QB","resent":{"note_object_id":"protocol-note"}}\n')
  F.write(root..'/read/'..recipient..'.jsonl','QA\nPROTOCOL_ORPHAN\n')
  local expected_token=dofile('tests/lib/qa_inbox_witness_oracle.lua')(F,root,recipient)
  local ready,previous
  for _=1,80 do
    local result,err=advance(recipient,previous)
    assert(result,'v2 protocol progress failed '..tostring(err and err.code))
    previous=result.cursor
    if result.complete then ready=result.snapshot;break end
  end
  assert(ready and ready.witness==expected_token,'expected independent framed chain mismatch')
  assert(#ready.deliveries==2 and ready.reads.QA and ready.reads.PROTOCOL_ORPHAN and not ready.reads.QB,'protocol fixture identities/read set changed')
  local source,progress=configure(recipient)
  local before=assert(progress.load(root,recipient))
  local again=assert(source:advance(root,recipient,budget))
  assert(again.snapshot.witness==expected_token,'reopened ready witness changed')
  assert(progress.load(root,recipient).revision==before.revision,'ready reopen rewrote generation')
end)
for _,case in ipairs({{id='8989',control='8a8a',version=1,phase='files1'},
  {id='8b8b',control='8c8c',version=1,phase='ready'},
  {id='8d8d',control='8e8e',phase='files1'},{id='8f8f',control='9090',phase='ready'}}) do
  test('v1/versionless refuse '..case.id..' '..case.phase..' unchanged',function()
    valid_protocol_control(case.control,case.phase)
    seed_protocol(case.id,case.version,case.phase)
    local source,progress=configure(case.id)
    local before=assert(progress.load(root,case.id))
    local result,err=source:advance(root,case.id,budget)
    assert(result==nil and err and err.code=='unsupported_protocol','legacy protocol not explicitly refused')
    assert(err.required==2 and err.found==case.version and err.restart_required==true,'protocol refusal facts missing')
    local after=assert(progress.load(root,case.id))
    assert(after.revision==before.revision and after.cursor.generation==before.cursor.generation,'legacy generation changed')
    assert(F.canonical(after.cursor)==F.canonical(before.cursor),'legacy cursor mixed/reinterpreted')
  end)
end
if #failures>0 then error('source advance '..#failures..'/'..total..' failed\n'..table.concat(failures,'\n')) end
print('PASS source advance '..total..' realSQL cases; interleaved callers do not prove pump fairness')
