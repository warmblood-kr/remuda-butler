assert(assert(loadfile("tests/lib/isolated_test.lua"))()(remuda))
local target='packages/butler/inbox_source.lua'
local handle=io.open(target,'r')
if handle then handle:close() else target='packages/butler/inbox_source_contract.lua' end
local adapter=dofile(target)
local json=remuda.json
local function canonical(value)
  local encoded=assert(json.encode(value))
  if type(value)~='table' or value==json.null then return encoded end
  local parts={}
  if encoded:sub(1,1)=='[' then
    for _,item in ipairs(value) do parts[#parts+1]=canonical(item) end
    return '['..table.concat(parts,',')..']'
  end
  local keys={}
  for key in pairs(value) do keys[#keys+1]=key end
  table.sort(keys)
  for _,key in ipairs(keys) do parts[#parts+1]=assert(json.encode(key))..':'..canonical(value[key]) end
  return '{'..table.concat(parts,',')..'}'
end
local function sha_provider()
  local file=assert(io.open('packages/butler/guard_approval.lua','r'))
  local text=file:read('*a'); file:close()
  local first=assert(text:find('local K = {}',1,true))
  local last=assert(text:find('M.sha256 = sha256',first,true))
  return assert(load(text:sub(first,last-1)..'\nreturn sha256','qa-sha-provider'))()
end
local sha=sha_provider()
assert(sha('abc')=='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad','SHA provider invalid')
local serial=0
local function write(path,text)
  local file=assert(io.open(path,'wb')); assert(file:write(text)); assert(file:close())
end
local function read(path)
  local file,err,errno=io.open(path,'rb')
  if not file then return nil,{code=errno==2 and 'not_found' or 'io'} end
  local text=file:read('*a'); file:close(); return text
end
local function fixture()
  serial=serial+1
  local root=os.getenv('XDG_DATA_HOME')..'/source-'..serial
  for _,dir in ipairs({'inboxes','read','messages','objects'}) do remuda.mkdir(root..'/'..dir) end
  local envelopes={}
  for _,id in ipairs({'A','B'}) do
    local envelope={id=id,from={id='sender',alias='old alias'},to=json.array({{id='recipient'}}),
      body={object_id='object-'..id,bytes=4},unknown={preserve='field'},references=json.array({'ROOT'}),
      matrix={event_id='$'..id,room_id='!qa'}}
    envelopes[id]=envelope
    write(root..'/messages/'..id..'.json',assert(json.encode(envelope)))
    write(root..'/objects/object-'..id,'body')
  end
  write(root..'/objects/note-R','note R'); write(root..'/objects/note-R2','note R2')
  write(root..'/inboxes/6161.jsonl','{"message_id":"A","resent":{"note_object_id":"note-R"}}\n{"message_id":"A"}\n{"message_id":"B"}\n')
  write(root..'/read/6161.jsonl','B\nORPHAN\nB\n')
  write(root..'/read/6262.jsonl','READ_ONLY_ORPHAN\n')
  local cfg={root=root,fs={read=read,list=function(path) return remuda.list_dir(path) end},
    json={decode=json.decode,canonical=canonical},sha256=sha}
  return root,cfg,envelopes
end
local function open(cfg)
  local source,err=adapter.open(cfg)
  assert(source,'source open rejected '..tostring(err and err.code))
  return source
end
local function snapshot(source,root)
  local value,err=source:snapshot(root,'6161')
  assert(value,'snapshot rejected '..tostring(err and err.code))
  assert(value.complete and value.recipient=='6161','not complete exact recipient')
  assert(value.source_before==value.witness and value.source_after==value.witness,'unfenced source witness')
  assert(value.witness:match('^source%-v1:sha256:%x+$') and #value.witness==81,'wrong full witness token')
  return value
end
local failures,total={},0
local function test(name,fn)
  total=total+1
  local ok,err=pcall(fn)
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function reject(name,mutation,code)
  test(name,function()
    local root,cfg=fixture()
    local source=open(cfg)
    snapshot(source,root)
    mutation(root,cfg)
    source=open(cfg)
    local value,err=source:snapshot(root,'6161')
    assert(value==nil and err and err.code==code,'expected '..code..' got '..tostring(err and err.code))
  end)
end
test('exact disk identities read orphans metadata dense order last PRESENT',function()
  local root,cfg,envelopes=fixture()
  local source=open(cfg)
  local value=snapshot(source,root)
  assert(#value.deliveries==2,'duplicates not collapsed')
  assert(value.deliveries[1].message_id=='A' and value.deliveries[1].seq==1,'first distinct A order lost')
  assert(value.deliveries[2].message_id=='B' and value.deliveries[2].seq==2,'first distinct B order lost')
  assert(value.reads.B and value.reads.ORPHAN and not value.reads.A,'whole read set changed')
  assert(value.deliveries[1].resent==canonical({note_object_id='note-R'}),'plain duplicate cleared resent')
  local expected=canonical({envelope=envelopes.A,object={id='object-A',bytes=4,sha256=sha('body')}})
  assert(value.deliveries[1].metadata==expected,'envelope unknown fields/content identity lost')
  local recipients=assert(source:recipients(root))
  assert(recipients.complete and table.concat(recipients.recipients,',')=='6161,6262','read-only recipient lost')
  assert(source:witness(root,'6161')==value.witness,'independent witness differs')
end)
test('empty and read-only orphan mailbox are complete not unknown',function()
  local root,cfg=fixture()
  write(root..'/inboxes/6161.jsonl',''); write(root..'/read/6161.jsonl','')
  local source=open(cfg)
  local empty=snapshot(source,root)
  assert(#empty.deliveries==0 and next(empty.reads)==nil,'empty source invented facts')
  local orphan=assert(source:snapshot(root,'6262'))
  assert(orphan.complete and #orphan.deliveries==0 and orphan.reads.READ_ONLY_ORPHAN,'read-only mailbox lost')
end)
test('retained resent note bytes affect full witness',function()
  local root,cfg=fixture()
  local before=snapshot(open(cfg),root)
  write(root..'/objects/note-R','Note R')
  local after=snapshot(open(cfg),root)
  assert(before.witness~=after.witness,'resent note content omitted from witness')
end)
test('later PRESENT resent replaces R while preserving identity',function()
  local root,cfg=fixture()
  local file=assert(io.open(root..'/inboxes/6161.jsonl','a'))
  assert(file:write('{"message_id":"A","resent":{"note_object_id":"note-R2"}}\n')); file:close()
  local value=snapshot(open(cfg),root)
  assert(#value.deliveries==2 and value.deliveries[1].resent==canonical({note_object_id='note-R2'}),'last PRESENT R2 lost')
end)
test('fresh reader detects same-size body edit in full witness',function()
  local root,cfg=fixture()
  local before=snapshot(open(cfg),root)
  write(root..'/objects/object-A','bOdy')
  local after=snapshot(open(cfg),root)
  assert(before.witness~=after.witness,'same-size body rewrite invisible')
  assert(before.deliveries[1].metadata~=after.deliveries[1].metadata,'content digest unchanged')
end)
reject('empty array resent is not an annotation object',function(root)
  write(root..'/inboxes/6161.jsonl','{"message_id":"A","resent":[]}\n')
end,'source_unreadable')
test('noncanonical configured root cannot be opened',function()
  local _,cfg=fixture()
  cfg.root='relative/source'
  local source,err=adapter.open(cfg)
  assert(source==nil and err and err.code=='invalid_snapshot','relative root accepted')
end)
test('malformed list shape cannot hide recipients',function()
  local root,cfg=fixture()
  cfg.fs.list=function() return {[1]='6161.jsonl',extra='not-a-mailbox'} end
  local result,err=open(cfg):recipients(root)
  assert(result==nil and err and err.code=='source_unreadable','nonarray list entry silently ignored')
end)
reject('torn inbox is partial',function(root) write(root..'/inboxes/6161.jsonl','{"message_id":"A"}') end,'partial')
reject('torn read is partial',function(root) write(root..'/read/6161.jsonl','B') end,'partial')
reject('malformed complete line not skipped',function(root) write(root..'/inboxes/6161.jsonl','BROKEN\n') end,'source_unreadable')
reject('missing envelope not empty',function(root) os.remove(root..'/messages/A.json') end,'source_unreadable')
reject('missing body not empty',function(root) os.remove(root..'/objects/object-A') end,'source_unreadable')
reject('wrong envelope identity refused',function(root) write(root..'/messages/A.json','{"id":"X","body":{"object_id":"object-A"}}') end,'source_unreadable')
reject('explicit null resent not absent',function(root) write(root..'/inboxes/6161.jsonl','{"message_id":"A","resent":null}\n') end,'source_unreadable')
reject('body mutation during snapshot refuses generation',function(root,cfg)
  local original,reads=cfg.fs.read,0
  cfg.fs.read=function(path)
    local value,err=original(path)
    if path==root..'/objects/object-A' then
      reads=reads+1
      if reads==1 then write(path,'bOdy') end
    end
    return value,err
  end
end,'stale_generation')
test('wrong root refused',function()
  local root,cfg=fixture()
  local value,err=open(cfg):snapshot(root..'-other','6161')
  assert(value==nil and err and err.code=='invalid_snapshot','root fence absent')
end)
test('directory denied not empty recipients',function()
  local root,cfg=fixture()
  cfg.fs.list=function() return nil,{code='denied'} end
  local value,err=open(cfg):recipients(root)
  assert(value==nil and err and err.code=='source_unreadable','denied list became empty')
end)
if #failures>0 then error('source contract '..#failures..'/'..total..' failed ['..target..']\n'..table.concat(failures,'\n')) end
print('PASS source contract '..total..' actual disk cases ['..target..']')
