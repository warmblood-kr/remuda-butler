-- Disposable QA RPC seams; product modules are loaded unchanged.
local arrays = setmetatable({}, {__mode='k'})
local function encode(value)
  if type(value) == 'string' then
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
      return string.format('\\u%04x', char:byte()) end) .. '"'
  end
  if type(value) == 'boolean' or type(value) == 'number' then return tostring(value) end
  if value == nil then return 'null' end
  local out = {}
  local list = arrays[value] or #value > 0
  for key, item in pairs(value) do
    if not list then out[#out+1] = encode(key) .. ':' .. encode(item) end
  end
  if list then for _, item in ipairs(value) do out[#out+1] = encode(item) end end
  return (list and '[' or '{') .. table.concat(out, ',') .. (list and ']' or '}')
end
local function rpc(kind, value)
  io.write(encode({kind=kind,value=value}) .. '\n'); io.flush()
  local line = assert(io.read('*l'), 'QA controller closed')
  local chunk = assert(loadstring('return ' .. line)); setfenv(chunk,{})
  return chunk()
end
local codec = {encode=encode, decode=function(text) return rpc('decode',text) end,
  array=function(value) arrays[value]=true; return value end,
  object=function(value) return value end}
local cfg = rpc('config', {})
if cfg.operation == 'launch' then
  remuda={butler={}}
  local module=dofile('packages/butler/native_launch.lua')
  local instance=module.new({paths={data_home=cfg.data_home},
    config={},random=function() return cfg.entropy end,
    fs={mkdir_new=function(path)
      local result=rpc('mkdir',path)
      return result.ok,result.reason
    end}})
  local binding,nonce,why=instance.prepare('qa')
  assert(binding,why)
  local plan={mode='native',binding=binding,nonce=nonce}
  remuda._butler_agent_builders={}
  remuda._butler_agent_startup={}
  remuda._butler_telemetry_adapters={}
  dofile('packages/butler/agents/opencode.lua')
  rpc('result',{binding=binding,nonce=nonce,env=module.env(plan),
    argv=remuda._butler_agent_builders.opencode({name='qa',cwd=cfg.cwd,native=plan})})
  return
end
local bus = {agents={}, notices={}, pending_tasks={}, messages={}, objects={},
  mail_delivered={}, codex_update_relaunches={}, codex_update_state={}, notice_timers={},
  notice_seen={}, unread_seeded={}, notice_retry_reasons={}, notice_fallbacks={},
  notice_failure_alerts={}, notice_uncertain_alerts={}, notice_sent_at={},
  notice_reminder_at={}, notice_stuck={}}
bus.agents.lead={id='qa-recipient',kind='opencode',instance_id='qa-instance',parent='root',
  native={mode='native',path=cfg.binding,nonce=cfg.nonce,row_id=cfg.session,instance='qa-instance'}}
local alerts, pty = 0, 0
local mail={mailbox=function() return {} end, is_unread=function() return true end,
  unread=function() return 1 end, find_message=function(id)
    return {id=id,from={alias='qa-sender',id='qa-sender'}} end}
_butler_session_trace=function() end
remuda={json=codec,_butler_notice_clock=function() return cfg.now end,
  _butler_session_trace=_butler_session_trace,
  _butler_chooser={known_startup_modal=function() return false end},
  _butler_agent_startup={opencode={placeholders={}}},
  _butler_notice_config={bus=bus,resolve=function(name) return name end,
    mail_address=function(name) return {alias=name,id=name} end,
    mail_id=function(name) return name,{alias=name,id=name,kind='opencode'} end,
    mail=mail,take_delivery_notice_result=function() end,
    notify_mail_delivery=function() end,deliver_message=function() end},
  ls=function() return {{name='lead',id=cfg.session,instance_id='qa-instance',alive=true,attached=true}} end,
  capture=function() error('QA unexpected screen read') end,
  send=function() pty=pty+1; return true end,
  process={run=function(spec) return rpc('run',spec) end}}
local jm=dofile('packages/butler/delivery_journal.lua')
remuda._butler_delivery_journal=jm.new({path=cfg.journal,json=codec,
  now=function() return cfg.now end,
  hash=function(text) return rpc('hash',text) end,
  read=function(path) local value=rpc('read',path); if value==false then return nil,'missing' end; return value end,
  write=function(path,text) return rpc('write',{path=path,text=text}) end})
assert(remuda._butler_delivery_journal.load())
dofile('packages/butler/native_dispatch.lua')
dofile('packages/butler/native_launch.lua')
dofile('packages/butler/notice.lua')
remuda._butler_send=function() alerts=alerts+1 end
bus.notices.lead={count=1,message_order={cfg.marker},message_ids={[cfg.marker]='notice'},
  text='notice',kind='opencode',due_at=cfg.now}
local completed=remuda._butler_notice.deliver_notice('lead')
rpc('result',{completed=completed,pty=pty,alerts=alerts,mode=bus.agents.lead.native.mode,
  state=remuda._butler_delivery_journal.state_of('qa-recipient',cfg.marker) or 'none'})
