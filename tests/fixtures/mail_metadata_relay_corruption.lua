-- QA case is loaded by the already-guarded relay suite; no globals at load.
local function read(path)
  local file=assert(io.open(path,'r')); local text=file:read('*a'); file:close(); return text
end
local function write(path,text)
  local file=assert(io.open(path,'w')); assert(file:write(text)); assert(file:close())
end
local function bind_hook(H,fresh)
  local mail=fresh()
  remuda._butler_mail_config.bus.agents.butler={id='butler',alias='butler'}
  local text=read('packages/butler/main.lua')
  local first=assert(text:find('local function inbox_delivery(message)',1,true))
  local last=assert(text:find('remuda._butler_inbox_delivery = inbox_delivery',first,true))
  local factory=assert(load('return function(queue_message,notify_mail_delivery,mail,remuda)\n'..text:sub(first,last-1)..'\nreturn inbox_delivery end','qa-main-delivery'))()
  local delivery=factory(mail.queue,function(_,message) return message end,mail,remuda)
  local init=read('packages/butler/init.lua')
  local hook_text=assert(init:match('run = (function%(_, message%).-\n      end) },'))
  local hook_factory=assert(load('return function(host) return '..hook_text..' end','qa-init-delivery-hook'))()
  local hook=hook_factory({_butler_inbox_delivery=delivery})
  remuda.emit_until_success=function(name,message)
    assert(name=='butler/deliver','unexpected event')
    local result=hook({},message)
    H.last_error=message.delivery_error
    return result
  end
  return mail
end
local function pending(relay,id)
  assert(relay:state().pending[id],'durable pending lost')
  assert(not relay:state().processed[id],'refused event processed')
  assert((relay:state().pending[id]._relay_failures or 0)==0,'nil refusal counted as throw')
end
local function count(root) return #(remuda.list_dir(root..'/messages') or {}) end
local function run(H,client,fresh,root)
  local relay=H.module.instance
  local mail=bind_hook(H,fresh)
  local seed=assert(mail.queue({id='seed',alias='seed'},{id='butler',alias='butler'},'seed body'))
  mail.inbox('butler')
  local path=root..'/messages/'..seed.id..'.json'
  local original=read(path)
  write(path,'BROKEN')
  bind_hook(H,fresh)
  for _=1,7 do
    H.sync(client,H.home,{H.message('$qa-deferred',H.owner,'new durable task')})
    pending(relay,'$qa-deferred')
  end
  assert(H.last_error and H.last_error:find('cannot prove Matrix event',1,true),'actual main hook lost local refusal reason')
  assert(count(root)==1,'refusal wrote mail')
  H.module.stop()
  assert(H.module.start({config_path=H.path}),'relay reconstruction failed')
  relay=H.module.instance
  pending(relay,'$qa-deferred')
  client:sync({json={next_batch='qa-restart'}})
  pending(relay,'$qa-deferred')
  write(path,original)
  mail=bind_hook(H,fresh)
  H.sync(client,H.home,{H.message('$qa-deferred',H.owner,'new durable task')})
  assert(not relay:state().pending['$qa-deferred'] and relay:state().processed['$qa-deferred'],'repair did not ack exactly delivered event')
  assert(count(root)==2,'repair did not write exactly one new envelope')
  local delivered_id
  for id,route in pairs(relay:state().routes) do if route.event_id=='$qa-deferred' then delivered_id=id end end
  assert(delivered_id,'new delivery ULID not retained')
  H.module.stop(); assert(H.module.start({config_path=H.path}))
  client:sync({json={next_batch='qa-restart-2'}})
  mail=bind_hook(H,fresh)
  H.sync(client,H.home,{H.message('$qa-deferred',H.owner,'new durable task')})
  assert(count(root)==2,'replay after restart wrote duplicate')
  assert(mail.unread('butler')==1 and mail.is_unread('butler',delivered_id),'fresh disk unread identity lost')
  assert(mail.find_message(delivered_id).matrix.event_id=='$qa-deferred','envelope correlation lost')
  local text=mail.inbox('butler')
  local _,occurrences=text:gsub('new durable task','')
  assert(occurrences==1,'inbox task count not exactly one')
end
return function(H)
  local dir,path=H.fixture()
  H.path=path
  H.with_dir(dir,function()
    H.production(path,dir..'/mailroot',function(client,_,fresh,root) run(H,client,fresh,root) end)
  end)
end
