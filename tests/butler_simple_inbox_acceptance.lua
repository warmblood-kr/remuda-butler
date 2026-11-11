local phase=assert(remuda._qa_restart_phase)
local mail=assert(remuda._butler_mail)
assert(remuda._butler_simple_inbox, "SQLite inbox did not start")
local db=remuda._butler_simple_inbox.db
local sender={host='local',id='sender',alias='sender',session='sender'}
local recipient={host='local',id='aa',alias='aa',session='aa'}
if phase==1 then
  assert(mail.unread('aa')==1,'legacy unread missing before restart')
  local sent,err=mail.queue(sender,recipient,'new before restart')
  assert(sent,'send before restart failed: '..tostring(err))
  local f=assert(io.open(os.getenv('XDG_DATA_HOME')..'/sent-id','wb'))
  f:write(sent.id);f:close()
  assert(mail.unread('aa')==2,'both messages should be unread')
  local rows=assert(db:query('SELECT message_id FROM simple_inbox WHERE recipient=? ORDER BY seq',{'6161'}))
  assert(#rows==2 and rows[1].message_id=='A' and rows[2].message_id==sent.id,'SQLite delivery order')
elseif phase==2 then
  local f=assert(io.open(os.getenv('XDG_DATA_HOME')..'/sent-id','rb'))
  local id=f:read('*a');f:close()
  assert(mail.unread('aa')==2,'unread messages did not survive process restart: '..tostring(mail.unread('aa')))
  local other={host='local',id='bb',alias='bb',session='bb'}
  local forwarded,forward_err=mail.forward(recipient,'A',other,'forward note')
  assert(forwarded,'forward failed: '..tostring(forward_err))
  local forwarded_body=mail.inbox('bb')
  assert(forwarded_body:find('body',1,true) and forwarded_body:find('forward note',1,true),'forward missing')
  local body=mail.inbox('aa')
  assert(body:find('A',1,true) and body:find('body',1,true),'legacy message missing')
  assert(body:find(id,1,true) and body:find('new before restart',1,true),'new message missing')
  assert(mail.unread('aa')==0,'read state not committed')
  local nextmsg,err=mail.queue(sender,recipient,'new after restart')
  assert(nextmsg,'send after restart failed: '..tostring(err))
  assert(mail.unread('aa')==1,'new message not unread')
  assert(mail.inbox('aa'):find('new after restart',1,true),'new body missing')
  assert(mail.unread('aa')==0,'new read state missing')
elseif phase==3 then
  assert(mail.unread('aa')==0,'read state did not survive second process restart')
  assert(mail.inbox('aa')=='inbox empty','read messages returned again')
else error('invalid phase') end
return 'phase '..phase..' ok'
