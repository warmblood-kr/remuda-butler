-- Actual approval, queue, admission and dialog modules; synthetic terminal IO,
-- real private core storage. No live pane or network.
local api=remuda
local OWNER='@owner:fixture'
local function subject(name,run,without_provider)
  local original,trace=remuda,_butler_session_trace
  local ok,why=pcall(function()
    dofile('tests/butler_dialogs.lua');remuda.butler.dialogs.stop()
    local f,b=remuda,remuda._butler_bus
    local mode={screen='synthetic unparseable footer',instance='fixture-core',seq='1'}
    local fake_clock=0
    local writes,keys,notes={},{},{}
    f.fs={};for k,v in pairs(api.fs)do f.fs[k]=v end
    f.json,f.cli,f.random_bytes,f.clock=api.json,api.cli,api.random_bytes,function() return fake_clock end
    f.butler.approval=nil;f.butler.owner_input=nil;f.butler.guard_grants=nil
    f.butler.matrix={sanitize_directory_text=function(v)return v end}
    f.butler.guard_policy={append=function(record)
      if mode.audit_change and record.event=='dialog_action' then local change=mode.audit_change;mode.audit_change=nil;change()end
      return not mode.audit_fail
    end,enabled=function()return false end,redact=function(v)return v end}
    f.ls=function()return{{name='codex',alive=true,attached=mode.attached or false,
      human_idle=mode.human_idle or math.huge,output_idle=0.3,instance_id=mode.instance}}end
    f.session=function()return{is_busy=true}end -- output activity is not admission.
    f._session_pty_output_sequence=function(_,id) assert(id==mode.instance);return mode.seq end
    f.capture=function()if mode.on_capture then mode.on_capture()end;return mode.screen end;f.capture_styled=nil
    f.type_text=function(_,bytes)
      writes[#writes+1]=bytes
      if mode.write_throw then error('synthetic ambiguous partial write')end
      if mode.write_false then return false end
      if mode.after_text then mode.after_text()end
      return mode.provider or'submitted'
    end
    f.key=function(_,key)keys[#keys+1]=key;if mode.key_false then return false end;if mode.key_nil then return nil end;return true end
    f._butler_queue_bound_provider={identity_fenced=true,
      type_text=function(name,instance,...)assert(instance==mode.instance,'synthetic wrong instance');return f._butler_dialog_originals.type_text(name,...)end,
      key=function(name,instance,...)assert(instance==mode.instance,'synthetic wrong instance');return f._butler_dialog_originals.key(name,...)end}
    f._butler_dialog_originals=nil;b.dialog_states={};b.pending_tasks={};f._butler_state={}
    b.agents.butler={id='butler-id',session_name='butler',session_start_marker='root',kind='codex'}
    b.agents.codex.instance_id=mode.instance;b.agents.codex.parent='butler';b.agents.codex.session_name='codex';b.agents.codex.session_start_marker='marker'
    f._butler_matrix_live_config={allowed_senders={[OWNER]=true},butler_senders={},self_mxid='@relay:fixture',
      home_room='!home:fixture',approve_text=true,typed_lines=true}
    f._butler_notice_config={bus=b,resolve=function(n)return n end,mail_address=function()end,mail_id=function()end,
      mail={mailbox=function()return{}end},take_delivery_notice_result=function()end,notify_mail_delivery=function()end,deliver_message=function()end}
    _butler_session_trace=function()end;f._butler_session_trace=_butler_session_trace
    dofile('packages/butler/notice.lua')
    local approval=dofile('packages/butler/approval.lua')
    local prepared=dofile('packages/butler/approve_text.lua')
    dofile('packages/butler/typed_lines.lua');dofile('packages/butler/guard_approval.lua')
    if without_provider then f._butler_queue_bound_provider=nil end
    dofile('packages/butler/dialogs.lua');f.butler.dialogs.install()
    local dir=assert(os.getenv('REMUDA_LUA_SCRATCH'))..'/owner-'..name
    assert(f.fs.mkdir_new(dir));assert(f.fs.mkdir_new(dir..'/remuda'));assert(f.fs.mkdir_new(dir..'/remuda/butler'))
    f._butler_paths={data_home=dir}
    dofile('packages/butler/system.lua')
    dofile('packages/butler/input_queue.lua')
    local state={approvals={}}
    local function persist()return not mode.marker_fail end
    approval.attach(state,persist,function(text,_,done)notes[#notes+1]=text;if done then done({event_id='$reply'})end;return true end)
    dofile('packages/butler/owner_refresh.lua')
    local queue=dofile('packages/butler/owner_input.lua')
    local function request(id,text,ttl)
      local binding=assert(queue.binding('codex'))
      local rec={id=id,kind='approve_text',status='open',event_id='$request-'..id,
        nonce='nonce-'..id,expires_at=(os.time()+(ttl or 30))*1000,created_ms=os.time()*1000,
        data={request_id=id,registered_text=text,bytes=#text,session='codex',session_id=binding.agent_id,
          session_marker=binding.session_marker,core_instance=binding.instance_id,session_binding_version=2}}
      state.approvals[id]=rec
      assert(approval.answer(rec.event_id,'approve',OWNER,'$answer-'..id));return rec
    end
    local function event(id,text)
      return{event_id='$line-'..id,type='m.room.message',sender=OWNER,origin_server_ts=os.time()*1000,
        content={msgtype='m.text',body='!'..text}}
    end
    run({advance=function(ms) fake_clock=fake_clock+ms end,queue=queue,request=request,event=event,state=state,mode=mode,writes=writes,keys=keys,
      approval=approval,prepared=prepared,bus=b,notes=notes,store_path=dir..'/remuda/butler/input-queue.json'})
  end)
  _G.remuda,_G._butler_session_trace=original,trace
  if not ok then error(why,0)end
end
-- RED acceptance: owner ! input must refresh before its existing admission
-- policy. The redraw function is a synthetic adapter, not a real PTY proof.
local redraw_routes = {'owner_line','prepared'}
for _,route in ipairs(redraw_routes) do
T.test(route..' observes refreshed modal before typing', function()
 subject(route..'-refresh', function(s)
  local events={}
  s.mode.screen='old safe screen'
  remuda._session_refresh=function(name)
   T.eq(name,'codex');events[#events+1]='refresh';s.mode.screen='new modal screen';s.mode.seq='2';return true
  end
  local original=remuda._butler_approved_text_policy
  remuda._butler_approved_text_policy=function(...)
   events[#events+1]='policy:'..s.mode.screen
   if s.mode.screen=='new modal screen' then return false,'synthetic_modal' end
   return original(...)
  end
  if route == 'owner_line' then
   local event=s.event('refresh-red','exact line')
   assert(s.queue.accept_line('codex','exact line',event,'!home:fixture',true))
  else
   s.request('AR01','exact line')
  end
  s.queue.tick()
  T.eq(#s.writes,0,'pending refresh cannot type')
  s.advance(500)
  s.queue.tick()
  s.advance(250)
  s.queue.tick()
  T.eq(#s.writes,0,'redraw must expose modal before owner line write; '..table.concat(events,','))
  T.eq(#s.keys,0,'no Return while modal is visible')
  T.eq(events[1],'refresh','refresh precedes admission')
 end)
end)
end
