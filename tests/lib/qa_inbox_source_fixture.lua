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

return {fixture=fixture,write=write,read=read,canonical=canonical,snapshot=snapshot,open=open,sha=sha}
