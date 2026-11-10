assert(assert(loadfile("tests/lib/isolated_test.lua"))()(remuda))
local base=os.getenv('XDG_DATA_HOME')..'/qa-metadata'
local serial, case_number=0,0
remuda._butler_new_ulid=function() serial=serial+1; return string.format('%026d',serial) end
remuda.butler=remuda.butler or {}
remuda.butler.matrix=remuda.butler.matrix or {utf8_prefix=function(text,n) return text:sub(1,n) end}
local sender={id='sender',alias='sender'}
local receiver={id='recipient',alias='recipient'}
local function fresh(root)
  remuda._butler_mail_config={root=root,bus={agents={},inboxes={},messages={},objects={}},
    json_quote=function(value) return remuda.json.encode(value) end}
  dofile('packages/butler/mail.lua')
  return remuda._butler_mail
end
local function queue(mail,event,room,to)
  return mail.queue(sender,to or receiver,'new payload',nil,nil,nil,
    {event_id=event,room_id=room or '!qa',sender='@human:qa'})
end
local function fixture()
  case_number=case_number+1
  local root=base..case_number
  local mail=fresh(root)
  local message=assert(queue(mail,'$existing'))
  mail.inbox('recipient')
  return root,message,fresh(root)
end
local function write(path,text)
  local file=assert(io.open(path,'w'))
  assert(file:write(text)); assert(file:close())
end
local function files(root)
  return #(remuda.list_dir(root..'/messages') or {})
end
local failures,total={},0
local function test(name,fn)
  total=total+1
  local ok,err=pcall(fn)
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function refusal(root,mail,event)
  local before,ids=files(root),serial
  local message,err=queue(mail,event)
  assert(message==nil and err~=nil,'unprovable dedup did not refuse')
  assert(serial==ids,'refusal minted a replacement id')
  assert(files(root)==before,'refusal wrote an envelope')
end
test('memory-only exact duplicate preserves id and queue state',function()
  local mail=fresh(nil)
  local first=assert(queue(mail,'$memory'))
  local before=serial
  local duplicate=assert(queue(mail,'$memory'))
  assert(duplicate.id==first.id,'memory duplicate minted another id')
  assert(serial==before,'memory duplicate consumed a new ULID')
  assert(mail.unread('recipient')==1,'memory duplicate added inbox entry')
end)
test('memory-only room and recipient isolation',function()
  local mail=fresh(nil)
  local first=assert(queue(mail,'$memory'))
  local other=assert(queue(mail,'$memory','!other'))
  local recipient=assert(queue(mail,'$memory','!qa',{id='other',alias='other'}))
  assert(first.id~=other.id and first.id~=recipient.id,'memory scopes collided')
  assert(queue(mail,'$memory','!other').id==other.id,'memory room duplicate changed id')
end)
test('new event opens no historical read bodies',function()
  local root,first,mail=fixture()
  local original,opens=io.open,0
  io.open=function(path,mode)
    local file,err=original(path,mode)
    if file and mode=='r' and path==root..'/objects/object-'..first.id then opens=opens+1 end
    return file,err
  end
  local ok,message=pcall(queue,mail,'$new')
  io.open=original
  assert(ok and message,'new delivery failed')
  assert(opens==0,'historical read body opened '..opens..' times')
end)
test('exact duplicate reload preserves id read state and files',function()
  local root,first,mail=fixture()
  local before,ids=files(root),serial
  local duplicate=assert(queue(mail,'$existing'))
  assert(duplicate.id==first.id,'duplicate identity changed')
  assert(not mail.is_unread('recipient',first.id),'duplicate resurrected read mail')
  assert(files(root)==before and serial==ids,'duplicate created new durable identity')
end)
test('room and recipient exact key isolation',function()
  local root,first,mail=fixture()
  local other=assert(queue(mail,'$existing','!other'))
  local recipient=assert(queue(mail,'$existing','!qa',{id='other',alias='other'}))
  assert(other.id~=first.id and recipient.id~=first.id and recipient.id~=other.id,'dedup escaped scope')
  mail=fresh(root)
  assert(queue(mail,'$existing','!other').id==other.id,'room identity lost across reload')
end)
test('missing historical envelope cannot prove absence',function()
  local root,first,mail=fixture()
  assert(os.remove(root..'/messages/'..first.id..'.json'))
  refusal(root,mail,'$new')
end)
test('malformed JSON with plausible fragments cannot prove absence',function()
  local root,first,mail=fixture()
  write(root..'/messages/'..first.id..'.json','BROKEN {"object_id":"object-'..first.id..'"}')
  refusal(root,mail,'$new')
end)
test('partial Matrix envelope cannot prove absence',function()
  local root,first,mail=fixture()
  write(root..'/messages/'..first.id..'.json','{"body":{"object_id":"object-'..first.id..'"},"matrix":{"event_id":"$existing"}}')
  refusal(root,mail,'$new')
end)
for _,invalid in ipairs({'[]','null','{"body":{"object_id":"object-placeholder"},"matrix":false}'}) do
  test('invalid envelope shape '..invalid,function()
    local root,first,mail=fixture()
    write(root..'/messages/'..first.id..'.json',invalid)
    refusal(root,mail,'$new')
  end)
end
test('matched missing body refuses without replacement id',function()
  local root,first,mail=fixture()
  assert(os.remove(root..'/objects/object-'..first.id))
  refusal(root,mail,'$existing')
end)
test('unrelated damaged id does not hide exact good match',function()
  local root,first,mail=fixture()
  local good=assert(queue(mail,'$good'))
  mail.inbox('recipient')
  assert(os.remove(root..'/messages/'..first.id..'.json'))
  mail=fresh(root)
  local before=files(root)
  assert(queue(mail,'$good').id==good.id,'good match blocked by unrelated damage')
  assert(files(root)==before,'good duplicate wrote replacement')
end)
test('shadow DB is never negative lookup authority',function()
  local root,first,mail=fixture()
  remuda._butler_mail_config.inbox_db={lookup_matrix=function() error('shadow queried') end,
    deliver=function() return nil,'db unavailable' end}
  assert(queue(mail,'$existing').id==first.id,'shadow changed existing identity')
  assert(queue(mail,'$new'),'shadow failure blocked file delivery')
end)
test('new hydrate seam preserves safe object and refuses traversal before open',function()
  local root,first=fixture()
  local authority=dofile('packages/butler/inbox_authority.lua')
  local store=assert(authority.open({root=root,json=remuda.json}))
  local original_content=assert(store:hydrate(first.id))
  assert(original_content.content=='new payload','safe legacy object content changed')
  write(root..'/outside','outside fixture')
  write(root..'/messages/'..first.id..'.json','{"body":{"object_id":"../outside"}}')
  local original,opens=io.open,0
  io.open=function(path,mode)
    if path==root..'/objects/../outside' then opens=opens+1 end
    return original(path,mode)
  end
  local ok,content,err=pcall(store.hydrate,store,first.id)
  io.open=original
  assert(ok and content==nil and err,'unsafe object reference accepted')
  assert(opens==0,'unsafe object path was opened')
end)
if #failures>0 then error('metadata contract '..#failures..'/'..total..' failed\n'..table.concat(failures,'\n')) end
print('PASS metadata contract '..total..' cases')
