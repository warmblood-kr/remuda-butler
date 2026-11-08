assert(assert(loadfile('tests/lib/isolated_test.lua'))()(remuda))
assert(type(remuda.db)=='table','REAL_SQL_UNAVAILABLE: Store gate cannot skip')
local F=dofile('tests/lib/qa_inbox_source_fixture.lua')
local allocations=0
dofile('packages/butler/system.lua')
remuda._butler_identity_config={bus={},current_agent=function() return nil end,
  json_quote=function(value) return assert(remuda.json.encode(value)) end,data_home=nil}
dofile('packages/butler/identity.lua')
local native_id=remuda._butler_new_ulid
remuda._butler_new_ulid=function() allocations=allocations+1;return native_id() end
local product_path='packages/butler/inbox_authority.lua'
local product=dofile(product_path)
local root=os.getenv('XDG_DATA_HOME')..'/store-case'
for _,dir in ipairs({'inboxes','read','messages','objects'}) do remuda.mkdir(root..'/'..dir) end
local json=remuda.json
local db=assert(remuda._qa_native_inbox_handle)
local path=root..'/authority.json'
remuda._butler_inbox_db_config={root=root,open=function() return db end}
dofile('packages/butler/inbox_db.lua')
local native_importer=remuda._butler_inbox_db
assert(native_importer.import_all(),'actual585 empty-root import failed')
local native_source=assert(dofile('packages/butler/inbox_source.lua').open({root=root,
  fs={list=remuda.list_dir,read=F.read},json={decode=json.decode,canonical=F.canonical},sha256=F.sha}))
local stats={source=0,import=0,content=0,publishes=0,sql=0}
local function marker_read(actual)
  assert(remuda.fs.realpath(actual)==root,'marker addressed wrong actual root')
  local text,err=F.read(path)
  if not text then return nil,err end
  return json.decode(text)
end
local function publish(value)
  assert(remuda.fs.write_atomic(path,assert(json.encode(value)),{private=true}))
  return true
end
publish({format_version=1,state='FILE',root=root,epoch=0})
local lock,leases=nil,0
local function claim(actual)
  assert(remuda.fs.realpath(actual)==root,'guard addressed wrong root')
  if not lock then lock=assert(remuda.fs.lock(root..'/.qa-store-owner.lock')) end
  leases=leases+1
  local released=false
  return {root=root,owner=true,guarded=true,release=function()
    if released then return end
    released=true;leases=leases-1
    if leases==0 and lock then lock:release();lock=nil end
  end}
end
local function content_publish(intent)
  stats.content=stats.content+1;stats.publishes=stats.publishes+1
  local id=intent.message_id or remuda._butler_new_ulid()
  local bytes=assert(intent.content,'publication missing exact content')
  assert(type(bytes)=='string','fixture expects exact byte content')
  local object='objects/object-'..id
  local existing=io.open(root..'/'..object,'rb')
  if existing then
    local saved=existing:read('*a');existing:close()
    if saved~=bytes then return nil,{code='operation_conflict'} end
  else
    local ok,err=remuda.fs.write_atomic(root..'/'..object,bytes,{private=true})
    if not ok then return nil,{code='unknown_publish',reason=tostring(err)} end
  end
  return {message_id=id,envelope_ref='messages/'..id..'.json',object_ref=object,
    metadata=intent.metadata,content_hash=F.sha(bytes),published=true}
end
local function content_hydrate(id)
  stats.content=stats.content+1
  local bytes,err=F.read(root..'/objects/object-'..id)
  if not bytes then return nil,{code='unavailable'} end
  return {message_id=id,content=bytes,object_ref='objects/object-'..id}
end
local function cfg(actual)
  return {root=actual or root,db={
    query=function(_,sql,params) stats.sql=stats.sql+1;return db:query(sql,params) end,
    exec=function(_,sql,params)
      stats.sql=stats.sql+1
      local result,err=db:exec(sql,params)
      if stats.lost_commit and sql:match('^%s*[Cc][Oo][Mm][Mm][Ii][Tt]') then
        assert(result~=nil,'underlying COMMIT failed');stats.lost_commit=false
        return nil,'timeout: lost real COMMIT return'
      end
      return result,err
    end,
    close=function() error('Store closed borrowed DB') end},
    json={encode=json.encode,decode=json.decode,canonical=F.canonical},sha256=F.sha,
    marker={read=marker_read,prepare=function() error('unexpected marker prepare') end,
      finalize=function() error('unexpected marker finalize') end},writer={claim=claim},
    source={recipients=function(r) stats.source=stats.source+1;return native_source:recipients(r) end,
      snapshot=function(r,p) stats.source=stats.source+1;return native_source:snapshot(r,p) end},
    importer={import_all=function() stats.import=stats.import+1;return native_importer.import_all() end,
      status=native_importer.status,available=native_importer.available},
    content={publish=content_publish,hydrate=content_hydrate}}
end
local function file_store(config)
  local store,err=product.open(config or cfg())
  assert(store,'FILE positive refused '..tostring(err and err.code))
  assert(store:status().authority=='file','FILE source not selected')
  return store
end
local cases={}
function cases.owner_registry()
  local first=file_store()
  local reloaded=dofile(product_path)
  local second,err=reloaded.open(cfg())
  assert(second==nil and err and err.code=='writer_conflict','same-process/reloaded module admitted second Store')
  assert(first:close()==true,'first owner failed to release')
end
function cases.close_replacement()
  local first=file_store()
  assert(type(first.close)=='function','Store.close unimplemented')
  assert(first:close()==true and first:close()==true,'close not idempotent')
  local replacement=file_store()
  assert(first:close()==true,'stale close failed')
  local third,err=product.open(cfg())
  assert(third==nil and err and err.code=='writer_conflict','stale close evicted replacement owner')
  local result,why=first:deliver({operation_id='old-owner',payload_hash=string.rep('a',64)})
  assert(result==nil and why and why.code=='writer_conflict','closed owner mutation not refused')
  assert(replacement:close()==true)
  assert(db:query('SELECT 1 AS alive'),'Store closed borrowed native DB')
end
function cases.alias_owner()
  local alias=root..'-alias'
  assert(remuda.process.run({argv={'ln','-s',root,alias},timeout=5}).code==0,'private alias fixture failed')
  local first=file_store()
  local second,err=product.open(cfg(alias))
  assert(second==nil and err and err.code=='writer_conflict','alias root admitted second owner')
  assert(type(first.close)=='function','Store.close unimplemented')
  assert(first:close()==true)
  local replacement=file_store(cfg(alias))
  assert(replacement:status().root==root,'alias not bound to actual canonical root')
  assert(replacement:close()==true)
end
function cases.new_marker()
  local first=file_store()
  if type(first.close)=='function' then assert(first:close()==true) end
  publish({format_version=999,state='FILE',root=root,epoch=0})
  stats.source,stats.import,stats.content,stats.sql=0,0,0,0
  local store,err=product.open(cfg())
  assert(store==nil and err and (err.code=='schema_too_new' or err.code=='unsupported_protocol'),'unknown marker format guessed compatible FILE')
  assert(stats.sql==0 and stats.source==0 and stats.import==0 and stats.content==0,'unknown marker touched backend/source')
end
function cases.tracked_db_down()
  local first=file_store()
  assert(type(first.close)=='function','Store.close unimplemented')
  assert(first:close()==true)
  publish({format_version=1,state='FILE_TRACKED',protocol='tracked-file-v1',root=root,epoch=1,tracking_epoch=1,generation='tracked-G'})
  assert(db:close())
  stats.source,stats.import,stats.content,stats.sql=0,0,0,0
  local store,err=product.open(cfg())
  assert(store==nil and err,'FILE_TRACKED DB-down selected FILE fallback')
  assert(err.code~='contract_unimplemented','FILE_TRACKED gate unimplemented')
  assert(stats.sql>0,'FILE_TRACKED never consulted actual DB capability')
  assert(stats.source==0 and stats.import==0 and stats.content==0,'FILE_TRACKED DB-down touched source/import/content')
  assert(marker_read(root).state=='FILE_TRACKED','DB-down erased durable gate')
end
local function frame(values)
  local out={}
  for _,value in ipairs(values) do out[#out+1]=#value..':'..value end
  return table.concat(out)
end
local function payload(key,content)
  local recipient=(key.destination:gsub('..',function(hex) return string.char(tonumber(hex,16)) end))
  local metadata=F.canonical({from={host='matrix',id='',alias='@human:hs'},
    to=json.array({{id=recipient,alias=recipient}}),subject='Exact : | 한글',created_at='2026-11-08T00:00:00Z',
    references=json.array({'ROOT'}),matrix={account=key.account,room_id=key.room,event_id=key.event}})
  return {content=content,metadata=metadata,
    payload_hash=F.sha(frame({'butler-external-payload-v1',content,metadata}))}
end
local function opid(key)
  return 'external-v1-'..F.sha(frame({'butler-external-key-v1',key.account,key.room,key.event,key.destination}))
end
local function base_key() return {account='matrix-account:primary',room='!room:hs',event='$event:1',destination='6161'} end
local function bootstrap()
  assert(os.remove(path),'bootstrap root marker not empty')
  local create=dofile('tests/support/inbox_authority_fixture.lua').create
  local result,err=create({db=db,root=root,json={encode=json.encode,decode=json.decode,canonical=F.canonical},
    marker={publish=publish},epoch=1,generation='fixture-G',operation_id='fixture-transition',
    proof_hash=F.sha('fixture-proof'),tail_watermark=0})
  assert(result,'actual fixture bootstrap failed '..tostring(err and err.code))
  assert(result.promotion_proof==false and result.bootstrap=='fixture','fixture falsely claims promotion')
  local rows=assert(db:query('SELECT root,epoch,generation,operation_id FROM auth_authority WHERE id=1'))
  assert(#rows==1 and rows[1].root==root and rows[1].epoch==1,'real authority epoch not persisted')
  local receipt=assert(db:query('SELECT state FROM auth_operations WHERE operation_id=?',{'fixture-transition'}))
  assert(#receipt==1 and receipt[1].state=='committed','real transition fixture receipt missing')
  db:close();db=assert(remuda._qa_reopen_inbox())
  local store,why=product.open(cfg())
  assert(store,'SQL_ACTIVE positive refused '..tostring(why and why.code))
  local status=store:status()
  assert(status.authority=='sql' and status.epoch==1,'SQL epoch not selected')
  return store
end
function cases.refused_lease_cleanup()
  for _,fault in ipairs({'root','owner','guarded'}) do
    local config=cfg();local releases=0
    config.writer.claim=function(actual)
      local capability=claim(actual);local release=capability.release
      capability.release=function() releases=releases+1;release() end
      capability[fault]=fault=='root' and root..'-wrong' or false
      return capability
    end
    local store,err=product.open(config)
    assert(store==nil and err,'invalid capability accepted: '..fault)
    assert(releases==1,'refused capability lease not released exactly once: '..fault)
    assert(leases==0 and lock==nil,'actual guard retained after refusal: '..fault)
    local replacement=file_store();assert(replacement:close()==true)
  end
end
function cases.sql_guard_required()
  local first=bootstrap();assert(first:close()==true)
  for _,mode in ipairs({'absent','failed'}) do
    local config=cfg()
    config.writer=nil
    if mode=='failed' then config.writer={claim=function() return nil,{code='writer_conflict'} end} end
    local store,err=product.open(config)
    if store then
      local value,why=store:accept_external(base_key(),payload(base_key(),'unguarded'))
      assert(value==nil and why and why.code=='writer_conflict','unguarded SQL mutation lacks writer_conflict gate: '..mode..' / '..tostring(why and why.code))
      assert(store:close()==true)
    else
      assert(err and err.code=='writer_conflict','unexpected guard refusal: '..mode)
    end
    assert(stats.publishes==0 and allocations==0,'unguarded mutation allocated content')
  end
  local replacement=assert(product.open(cfg()));assert(replacement:close()==true)
end
local function accepted(store,key,body)
  local value,err=store:accept_external(key,payload(key,body))
  assert(value and value.state=='committed','accept failed '..tostring(err and err.code))
  assert(value.operation_id==opid(key) and value.result.receipt_id==opid(key),'framed stable receipt mismatch')
  assert(type(value.result.message_id)=='string' and #value.result.message_id==26,'production mail ULID missing')
  assert(#value.result.recipients==1 and value.result.recipients[1]==key.destination,'recipient changed')
  return value
end
local function reopen(store)
  assert(store:close()==true)
  db:close();db=assert(remuda._qa_reopen_inbox())
  product=dofile(product_path)
  local fresh,err=product.open(cfg())
  assert(fresh,'SQL reopen failed '..tostring(err and err.code))
  return fresh
end
function cases.external_idempotency()
  local store=bootstrap();local key=base_key()
  local first=accepted(store,key,'payload : 한글')
  local page=assert(store:page(key.destination,{limit=10,unread_only=false}))
  assert(page.unread==1 and #page.rows==1,'accepted membership/read default missing')
  local ack=assert(store:mark_read({operation_id='ack-first',payload_hash=F.sha('ack-first')},{first.result.message_id},page.snapshot))
  assert(ack.state=='committed','read ack not committed')
  local before,ids=stats.publishes,allocations
  store=reopen(store)
  local again=accepted(store,base_key(),'payload : 한글')
  assert(again.result.message_id==first.result.message_id and stats.publishes==before,'retry rebuilt/reallocated immutable content')
  assert(allocations==ids,'same-key retry allocated a new ID')
  assert(store:page(key.destination,{limit=10,unread_only=false}).unread==0,'retry resurrected read mail')
  assert(store:close()==true)
end
function cases.external_conflict()
  local store=bootstrap();local key=base_key();accepted(store,key,'original')
  local before,ids=stats.publishes,allocations
  local wrong=payload(key,'original');wrong.payload_hash=string.rep('0',64)
  local value,err=store:accept_external(key,wrong)
  assert(value==nil and err and err.code=='operation_conflict','unverified hash accepted')
  value,err=store:accept_external(key,payload(key,'changed'))
  assert(value==nil and err and err.code=='operation_conflict','same key changed payload accepted')
  assert(stats.publishes==before and allocations==ids,'conflict allocated/published content')
  assert(#store:page(key.destination,{limit=10,unread_only=false}).rows==1,'conflict changed mailbox')
  assert(store:close()==true)
end
function cases.external_key_scope()
  local store=bootstrap();local keys={base_key()}
  for _,change in ipairs({{account='matrix-account:other'},{room='!other:hs'},{event='$event:other'},{destination='6262'}}) do
    local key=base_key();for field,value in pairs(change) do key[field]=value end;keys[#keys+1]=key
  end
  keys[#keys+1]={account='a:b',room='c',event='$utf8:한',destination='6161'}
  keys[#keys+1]={account='a',room='b:c',event='$utf8:한',destination='6161'}
  local ids={}
  for _,key in ipairs(keys) do
    local value=accepted(store,key,'byte-safe | payload')
    assert(not ids[value.result.message_id],'distinct framed key collided');ids[value.result.message_id]=true
  end
  assert(store:close()==true)
end
function cases.external_lost_commit()
  local store=bootstrap();local key=base_key()
  stats.lost_commit=true
  local value,err=store:accept_external(key,payload(key,'committed despite lost return'))
  assert(value and value.state=='unknown' and value.operation_id==opid(key),'lost COMMIT not uncertain')
  local before=stats.publishes
  store=reopen(store)
  local reconciled=assert(store:reconcile(opid(key)))
  assert(reconciled.state=='committed','actual committed receipt not recovered')
  local again=accepted(store,key,'committed despite lost return')
  assert(again.result.message_id==reconciled.result.message_id and stats.publishes==before,'reconcile retried as new mail')
  assert(store:close()==true)
end
function cases.sql_metadata_render()
  local store=bootstrap();local key=base_key();local value=accepted(store,key,'immutable body')
  local id=value.result.message_id;local archive=root..'/messages/'..id..'.json'
  F.write(archive,'BROKEN legacy archive')
  local original,opens=io.open,0
  io.open=function(p,mode) if p==archive then opens=opens+1 end;return original(p,mode) end
  local ok,hydrated,err=pcall(store.hydrate,store,id)
  io.open=original
  assert(ok and hydrated,'SQL hydrate failed '..tostring(err and err.code))
  assert(hydrated.content=='immutable body' and hydrated.envelope.subject=='Exact : | 한글','SQL metadata/body changed')
  assert(opens==0,'SQL mode read stale envelope archive')
  assert(store:close()==true)
end
function cases.sql_root_binding()
  local store=bootstrap();local key=base_key();local value=accepted(store,key,'root A data')
  assert(store:close()==true);db:close();db=assert(remuda._qa_reopen_inbox())
  local other=root..'-other'
  remuda.mkdir(other)
  local marker=assert(marker_read(root));marker.root=other
  assert(remuda.fs.write_atomic(other..'/authority.json',assert(json.encode(marker)),{private=true}))
  local alternative=cfg(other)
  alternative.marker={read=function() return json.decode(assert(F.read(other..'/authority.json'))) end}
  local other_lock=assert(remuda.fs.lock(other..'/.qa-store-owner.lock'))
  alternative.writer={claim=function() return {root=other,owner=true,guarded=true,release=function() end} end}
  stats.source,stats.import,stats.content,stats.sql=0,0,0,0
  local foreign,err=product.open(alternative)
  other_lock:release()
  assert(foreign==nil and err,'same SQL DB accepted another authority root')
  assert(stats.sql>0 and stats.source==0 and stats.import==0 and stats.content==0,'root mismatch touched stale source or skipped SQL proof')
  local restored=assert(product.open(cfg()))
  local result=assert(restored:reconcile(opid(key)))
  assert(result.result.message_id==value.result.message_id,'foreign root changed original receipt')
  assert(restored:close()==true)
end
local function authority_mismatch(fields)
  local store=bootstrap();assert(store:close()==true)
  for _,field in ipairs(fields) do
    assert(db:exec('UPDATE auth_authority SET '..field..' = '..field..' + 1 WHERE id=1'))
    local wrong,err=product.open(cfg())
    if wrong then wrong:close() end
    assert(wrong==nil and err,'SQL authority mismatch accepted: '..field)
    assert(db:exec('UPDATE auth_authority SET '..field..' = '..field..' - 1 WHERE id=1'))
    local restored=assert(product.open(cfg()));assert(restored:close()==true)
  end
end
function cases.sql_authority_match() authority_mismatch({'format_version'}) end
function cases.sql_tail_match() authority_mismatch({'tail_watermark'}) end
function cases.snapshot_ack_fences()
  local store=bootstrap();local key=base_key()
  local first=accepted(store,key,'first snapshot body')
  local page=assert(store:page(key.destination,{limit=10,unread_only=false}))
  local second_key=base_key();second_key.event='$later'
  local second=accepted(store,second_key,'later body')
  for _,field in ipairs({'root','epoch','generation'}) do
    local snapshot={};for k,v in pairs(page.snapshot) do snapshot[k]=v end
    snapshot[field]=field=='epoch' and snapshot[field]+1 or 'wrong'
    local value,err=store:mark_read({operation_id='bad-'..field,payload_hash=F.sha(field)},
      {first.result.message_id},snapshot)
    assert(value==nil and err,'stale snapshot acknowledged: '..field)
  end
  local value,err=store:mark_read({operation_id='later-ack',payload_hash=F.sha('later')},
    {second.result.message_id},page.snapshot)
  assert(value==nil and err,'post-snapshot membership acknowledged')
  assert(store:page(key.destination,{limit=10,unread_only=false}).unread==2,'refusal mutated read state')
  assert(store:mark_read({operation_id='valid-ack',payload_hash=F.sha('valid')},
    {first.result.message_id},page.snapshot).state=='committed','valid sealed snapshot refused')
  assert(store:page(key.destination,{limit=10,unread_only=false}).unread==1,'valid ack changed later mail')
  assert(store:close()==true)
end
function cases.migration_tracking_gate()
  local config=cfg()
  config.marker.publish=publish
  local progress,why=dofile('packages/butler/inbox_progress.lua').open({db=config.db,root=root,
    json={encode=json.encode,decode=json.decode}})
  assert(progress,'actual progress setup failed: '..tostring(why and why.code))
  config.progress=progress
  config.source=native_source
  local store=file_store(config)
  local result,err=store:advance({max_bytes=1024,max_statements=32,max_ms=10})
  assert(result,'B advance unavailable: '..tostring(err and err.code))
  local marker=assert(marker_read(root))
  assert(marker.state=='FILE_TRACKED' and marker.protocol=='tracked-file-v1',
    'migration advanced before durable tracking gate')
  assert(result.state=='backlog' or result.state=='ready','unclassified migration result')
  assert(store:close()==true)
  assert(db:close())
  local restarted,why=product.open(config)
  assert(restarted==nil and why,'tracked migration restart fell back without DB')
  assert(marker_read(root).state=='FILE_TRACKED','restart removed tracking gate')
end
local function migration_config(meter)
  local config=cfg();config.marker.publish=publish
  config.progress=assert(dofile('packages/butler/inbox_progress.lua').open({db=config.db,root=root,
    json={encode=json.encode,decode=json.decode}}))
  local fs={list=remuda.list_dir,read=F.read}
  fs.size=function(path)
    local file,_,errno=io.open(path,'rb')
    if not file then return nil,{code=errno==2 and 'not_found' or 'io'} end
    local length=file:seek('end');file:close();return length
  end
  fs.read_range=function(path,offset,limit)
    local file=assert(io.open(path,'rb'));assert(file:seek('set',offset))
    local bytes=file:read(limit) or '';file:close()
    meter.bytes=meter.bytes+#bytes;meter.calls=meter.calls+1
    if meter.ceiling and meter.bytes>meter.ceiling then error('QA byte ceiling exceeded: '..meter.bytes) end
    return {bytes=bytes,eof=offset+#bytes>=assert(fs.size(path))}
  end
  config.source=assert(dofile('packages/butler/inbox_source.lua').open({root=root,fs=fs,
    json={decode=json.decode,canonical=F.canonical},sha256=F.sha,progress=config.progress}))
  return config
end
function cases.migration_sealed_offsets()
  local line='{"message_id":"A"}\n'
  F.write(root..'/inboxes/6161.jsonl',line..'{"message_id":"B"')
  F.write(root..'/read/6161.jsonl','B\n')
  for _,id in ipairs({'A','B'}) do
    F.write(root..'/messages/'..id..'.json',assert(json.encode({id=id,from={id='sender'},
      to=json.array({{id='aa'}}),body={object_id='object-'..id,bytes=4}})))
    F.write(root..'/objects/object-'..id,'body')
  end
  local config=migration_config({bytes=0,calls=0});local store=file_store(config)
  local result=assert(store:advance({max_bytes=1024,max_statements=32,max_ms=10}))
  local rows=assert(db:query('SELECT * FROM migration_prefix WHERE recipient=?',{'6161'}))
  assert(#rows==1 and rows[1].inbox_end==#line and rows[1].read_end==2,'complete-line seal mismatch')
  assert(rows[1].inbox_torn==1 and rows[1].read_torn==0,'torn suffix lost')
  local generation=result.cursor.generation;assert(store:close()==true)
  F.write(root..'/inboxes/6161.jsonl',line..'{"message_id":"B"}\n')
  db:close();db=assert(remuda._qa_reopen_inbox())
  config=migration_config({bytes=0,calls=0});store=assert(product.open(config))
  result=assert(store:advance({max_bytes=1024,max_statements=32,max_ms=10}))
  rows=assert(db:query('SELECT * FROM migration_prefix WHERE recipient=?',{'6161'}))
  assert(#rows==1 and rows[1].inbox_end==#line,'append/restart reset or duplicated sealed prefix')
  assert(result.cursor.generation==generation and result.state=='backlog','append reset generation or falsely readied')
  assert(store:close()==true)
end
function cases.migration_seal_read_budget()
  F.write(root..'/inboxes/6161.jsonl',string.rep('x',1024*1024))
  local meter={bytes=0,calls=0,ceiling=1024};local store=file_store(migration_config(meter))
  local result,err=store:advance({max_bytes=1024,max_statements=32,max_ms=10})
  assert(meter.bytes<=1024,'seal exceeded byte budget: '..meter.bytes)
  assert(result and result.state=='backlog','torn log lacks bounded backlog: '..tostring(err and err.code))
  assert(store:close()==true)
end
local function store_fairness(preseal)
  F.write(root..'/inboxes/6161.jsonl',string.rep('{"message_id":"A"}\n',4096))
  F.write(root..'/read/6262.jsonl','ORPHAN\n')
  F.write(root..'/messages/A.json',assert(json.encode({id='A',from={id='sender'},
    to=json.array({{id='aa'}}),body={object_id='object-A',bytes=4}})))
  F.write(root..'/objects/object-A','body')
  if preseal then
    local config=migration_config({bytes=0,calls=0})
    config.source.sealed_advance=function() return nil,{code='partial'} end
    local store=assert(product.open(config))
    assert(store:advance({max_bytes=131072,max_statements=2,max_ms=10}))
    assert(store:close()==true)
    local sealed=assert(db:query('SELECT recipient,complete FROM migration_prefix'))
    assert(#sealed==2,'paired fixture failed to seal both prefixes')
    for _,row in ipairs(sealed) do assert(row.complete==0,'paired fixture staged early') end
  end
  for turn=1,8 do
    local config=migration_config({bytes=0,calls=0});local store=assert(product.open(config))
    local result,err=store:advance({max_bytes=256,max_statements=2,max_ms=10})
    assert(result,'Store pump failed: '..tostring(err and err.code))
    assert(store:close()==true);db:close();db=assert(remuda._qa_reopen_inbox())
  end
  local rows=assert(db:query('SELECT recipient,revision,complete FROM migration_prefix ORDER BY recipient'))
  assert(#rows==2,'read-only mailbox not discovered')
  assert(rows[1].complete==0,'large mailbox fixture completed too soon')
  assert(rows[2].revision>0 or rows[2].complete==1,'tiny mailbox starved behind first incomplete mailbox')
end
function cases.migration_store_fairness() store_fairness(false) end
function cases.migration_staging_fairness() store_fairness(true) end
function cases.migration_seal_resume()
  local prefix='{"message_id":"A"}\n'
  F.write(root..'/inboxes/6161.jsonl',prefix..string.rep('x',4096))
  local generation
  for turn=1,8 do
    local meter={bytes=0,calls=0,ceiling=1024}
    local store=assert(product.open(migration_config(meter)))
    local result,err=store:advance({max_bytes=1024,max_statements=4,max_ms=10})
    assert(result,'bounded seal retry failed: '..tostring(err and err.code))
    if generation then assert(result.cursor.generation==generation,'seal retry reset generation') end
    generation=result.cursor.generation
    assert(meter.bytes<=1024,'seal retry exceeded byte budget')
    assert(store:close()==true);db:close();db=assert(remuda._qa_reopen_inbox())
  end
  local rows=assert(db:query('SELECT inbox_end,inbox_torn FROM migration_prefix WHERE recipient=?',{'6161'}))
  assert(#rows==1 and rows[1].inbox_end==#prefix and rows[1].inbox_torn==1,
    'bounded seal never resumed to earlier complete prefix after eight turns')
end
function cases.migration_seal_exact_fit()
  local line='{"message_id":"A"}'
  F.write(root..'/inboxes/6161.jsonl',line..string.rep(' ',1023-#line)..'\n')
  local meter={bytes=0,calls=0,ceiling=1024}
  local config=migration_config(meter)
  local sealed,err=config.source:seal(root,'6161',{max_bytes=1024})
  assert(sealed,'healthy exact-fit seal refused: '..tostring(err and err.code))
  assert(sealed.inbox_end==1024 and sealed.read_end==0,'exact-fit offsets wrong')
  assert(sealed.inbox_torn==0 and sealed.read_torn==0,'healthy exact-fit marked torn')
  assert(meter.bytes==1024,'exact-fit read accounting wrong')
end
function cases.migration_seal_default_linear()
  F.write(root..'/inboxes/6161.jsonl',string.rep('x',65536))
  local config=migration_config({bytes=0,calls=0})
  local started=os.clock()
  local sealed,err=config.source:seal(root,'6161')
  assert(sealed,'default seal failed: '..tostring(err and err.code))
  assert(sealed.inbox_end==0 and sealed.inbox_torn==1,'default torn classification wrong')
  assert(os.clock()-started<1,'default seal nonlinear scan exceeded1CPU second')
end
local function total_seal_budget(multiple)
  F.write(root..'/inboxes/6161.jsonl',string.rep(' ',699)..'\n')
  F.write(root..(multiple and '/inboxes/6262.jsonl' or '/read/6161.jsonl'),string.rep(' ',699)..'\n')
  local meter={bytes=0,calls=0,ceiling=1024}
  local config=migration_config(meter)
  config.source.sealed_advance=function() return nil,{code='partial'} end
  local store=assert(product.open(config))
  local result,err=store:advance({max_bytes=1024,max_statements=4,max_ms=10})
  assert(meter.bytes<=1024,'total seal reads exceeded turn budget: '..meter.bytes)
  assert(result and result.state=='backlog','bounded seal lacks backlog: '..tostring(err and err.code))
  assert(store:close()==true)
end
function cases.migration_seal_total_budget() total_seal_budget(false) end
function cases.migration_seal_recipient_budget() total_seal_budget(true) end
function cases.migration_seal_zero_budget()
  F.write(root..'/inboxes/6161.jsonl','A\n')
  local meter={bytes=0,calls=0};local config=migration_config(meter)
  local value,err=config.source:seal(root,'6161',{max_bytes=0})
  assert(value and value.partial,'zero-budget metadata capture refused: '..tostring(err and err.code))
  assert(meter.bytes==0 and meter.calls==0,'zero budget read file data')
end
function cases.migration_seal_done_shrink()
  F.write(root..'/inboxes/6161.jsonl','A\n')
  F.write(root..'/read/6161.jsonl',string.rep('x',20))
  local config=migration_config({bytes=0,calls=0})
  local first=assert(config.source:seal(root,'6161',{max_bytes=2}))
  assert(first.partial,'shrink fixture not partial')
  F.write(root..'/inboxes/6161.jsonl','')
  local value,err=config.source:seal(root,'6161',{max_bytes=7,resume=first.cursor or first})
  assert(value==nil and err and err.code=='stale_generation','done-log shrink was not detected')
end
function cases.migration_seal_default_aggregate()
  F.write(root..'/inboxes/6161.jsonl',string.rep('x',40000))
  F.write(root..'/read/6161.jsonl',string.rep('x',40000))
  local meter={bytes=0,calls=0,ceiling=65536};local config=migration_config(meter)
  local value,err=config.source:seal(root,'6161')
  assert(meter.bytes<=65536,'default aggregate exceeded65536: '..meter.bytes)
  assert(value and value.partial,'default aggregate lacks partial: '..tostring(err and err.code))
end
function cases.migration_seal_captured_absence()
  local prefix='{"message_id":"A"}\n'
  local text=prefix..string.rep('x',28)
  F.write(root..'/inboxes/6161.jsonl',text)
  for turn=1,12 do
    local store=assert(product.open(migration_config({bytes=0,calls=0,ceiling=7})))
    local value,err=store:advance({max_bytes=7,max_statements=2,max_ms=10})
    assert(value,'capture pump failed: '..tostring(err and err.code))
    assert(store:close()==true);db:close();db=assert(remuda._qa_reopen_inbox())
    if turn==1 then F.write(root..'/read/6161.jsonl','R\n') end
    text=text..'z';F.write(root..'/inboxes/6161.jsonl',text)
  end
  local rows=assert(db:query('SELECT inbox_end,read_end FROM migration_prefix WHERE recipient=?',{'6161'}))
  assert(#rows==1 and rows[1].inbox_end==#prefix,'append/reopen lost original prefix boundary')
  assert(rows[1].read_end==0,'missing-at-capture read log was adopted into sealed prefix')
end
local function cursor_fixture()
  F.write(root..'/inboxes/6161.jsonl','A\n'..string.rep('x',30))
  F.write(root..'/read/6161.jsonl','B\n')
  local config=migration_config({bytes=0,calls=0})
  local value=assert(config.source:seal(root,'6161',{max_bytes=7,generation='qa-G'}))
  assert(value.partial and value.cursor.version==1,'cursor fixture not partialv1')
  return config,value
end
function cases.migration_seal_identity()
  local config,first=cursor_fixture()
  for _,field in ipairs({'root','generation','recipient','version'}) do
    local cursor=assert(json.decode(assert(json.encode(first.cursor))))
    cursor[field]=field=='version' and 2 or 'wrong'
    local value,err=config.source:seal(root,'6161',{max_bytes=0,generation='qa-G',resume=cursor})
    assert(value==nil and err and (err.code=='stale_generation' or err.code=='invalid_snapshot'),
      'cursor identity drift accepted: '..field)
  end
  local value,err=config.source:seal(root,'6161',{max_bytes=7,resume={inbox_offset=10}})
  assert(value==nil and err and err.code=='invalid_snapshot','captureless cursor guessed compatible')
end
function cases.migration_seal_missing_capture()
  local config,first=cursor_fixture()
  first.cursor.logs.read=nil
  local value,err=config.source:seal(root,'6161',{max_bytes=7,generation='qa-G',resume=first.cursor})
  assert(value==nil and err and err.code=='invalid_snapshot','missing captured log was silently recaptured')
end
function cases.migration_seal_short_read()
  local config=cursor_fixture()
  config.source.fs.read_range=function() return {bytes='',eof=false} end
  local value,err=config.source:seal(root,'6161',{max_bytes=7})
  assert(value==nil and err and err.code=='source_unreadable' and err.field=='short_read',
    'short native range accepted or misclassified')
end
function cases.migration_seal_zero_done_shrink()
  F.write(root..'/inboxes/6161.jsonl','A\n')
  F.write(root..'/read/6161.jsonl',string.rep('x',20))
  local meter={bytes=0,calls=0};local config=migration_config(meter)
  local first=assert(config.source:seal(root,'6161',{max_bytes=2,generation='qa-G'}))
  F.write(root..'/inboxes/6161.jsonl','')
  meter.bytes,meter.calls=0,0
  local value,err=config.source:seal(root,'6161',{max_bytes=0,generation='qa-G',resume=first.cursor})
  assert(value==nil and err and err.code=='stale_generation','zero-byte done shrink missed')
  assert(meter.bytes==0 and meter.calls==0,'zero-byte shrink check read data')
end
function cases.migration_seal_legacy_schema()
  F.write(root..'/inboxes/6161.jsonl',string.rep('x',40))
  local store=assert(product.open(migration_config({bytes=0,calls=0})))
  assert(store:advance({max_bytes=7,max_statements=2,max_ms=10}))
  assert(store:close()==true)
  assert(db:exec('BEGIN IMMEDIATE'))
  assert(db:exec('ALTER TABLE migration_seal_cursor RENAME TO qa_new_cursor'))
  assert(db:exec(assert(F.read('tests/fixtures/qa_legacy_seal_0008.sql'))))
  local fields='root,generation,recipient,inbox_offset,read_offset,inbox_done,inbox_end,inbox_torn,read_done,read_end,read_torn'
  assert(db:exec('INSERT INTO migration_seal_cursor ('..fields..') SELECT '..fields..' FROM qa_new_cursor'))
  assert(db:exec('DROP TABLE qa_new_cursor'));assert(db:exec('COMMIT'))
  db:close()
  local ok,reopened,why=pcall(remuda._qa_reopen_inbox)
  if not ok or reopened==nil then
    assert(not ok or why,'legacy DB refusal lacks reason')
    assert(marker_read(root).state=='FILE_TRACKED','legacy schema refusal removed gate')
    return
  end
  db=reopened
  local meter={bytes=0,calls=0};local config=migration_config(meter)
  local fresh,err=product.open(config)
  if fresh then
    local value;value,err=fresh:advance({max_bytes=7,max_statements=2,max_ms=10})
    assert(value==nil and err,'legacy schema silently resumed or resealed')
    assert(fresh:close()==true)
  else assert(err,'legacy open refusal lacks reason') end
  assert(meter.bytes==0,'legacy schema inferred capture from live data')
  assert(marker_read(root).state=='FILE_TRACKED','legacy schema refusal removed gate')
end
function cases.migration_seal_v8_upgrade()
  local version=assert(db:query('SELECT MAX(version) AS v FROM _remuda_migrations'))
  assert(version[1].v==8,'upgrade fixture did not start with actual nativev8')
  publish({format_version=1,state='FILE_TRACKED',protocol='tracked-file-v1',root=root,
    epoch=0,tracking_epoch=0,generation='legacy-G'})
  local marker_bytes=assert(F.read(path))
  local legacy_log='{"message_id":"A"}\nxxxx'
  F.write(root..'/inboxes/6161.jsonl',legacy_log)
  assert(db:exec("INSERT INTO migration_state (root,generation,epoch,protocol,revision) VALUES (?, ?, 0, 'tracked-file-v1', 0)",{root,'legacy-G'}))
  assert(db:exec('INSERT INTO migration_seal_cursor '..
    '(root,generation,recipient,inbox_offset,read_offset,inbox_done,read_done) VALUES (?,?,?,10,0,0,1)',
    {root,'legacy-G','6161'}))
  local migration='packages/butler/migrations/inbox/0009_inbox_seal_cursor_v1.up.sql'
  local installed=os.getenv('XDG_DATA_HOME')..'/remuda/mods/butler/'..migration
  F.write(installed,assert(F.read(migration)))
  local down=migration:gsub('up.sql$','down.sql')
  F.write(os.getenv('XDG_DATA_HOME')..'/remuda/mods/butler/'..down,assert(F.read(down)))
  db:close();local why;db,why=remuda._qa_reopen_inbox()
  assert(db,'actual nativev8->v9 migration refused: '..tostring(why))
  version=assert(db:query('SELECT MAX(version) AS v FROM _remuda_migrations'))
  assert(version[1].v==9,'native migration did not reachv9')
  assert(F.read(path)==marker_bytes,'upgrade changed FILE_TRACKED marker')
  assert(F.read(root..'/inboxes/6161.jsonl')==legacy_log,'upgrade changed authoritative legacy log')
  assert(#assert(db:query('SELECT * FROM migration_seal_cursor'))==0,'legacy cursor inferred into newcapture')
  local columns=assert(db:query('PRAGMA table_info(migration_seal_cursor)'));local names={}
  for _,column in ipairs(columns) do names[column.name]=true end
  assert(names.cursor_version and names.inbox_captured_size and names.read_present,'capture schema missing')
  assert(db:query('SELECT * FROM migration_seal_rotation'),'durable rotation schema missing')
  local store=file_store(migration_config({bytes=0,calls=0}))
  assert(store:advance({max_bytes=7,max_statements=2,max_ms=10}))
  assert(store:close()==true)
end
local name=assert(os.getenv('REMUDA_SQL_CASE'),'Store case required')
assert(cases[name],'unknown Store case')
local ok,err=pcall(cases[name])
if lock then lock:release();lock=nil end
if not ok then error('Store early RED '..name..': '..tostring(err)) end
print('PASS actual SQL Store '..name..' (not migration/promotion proof)')
