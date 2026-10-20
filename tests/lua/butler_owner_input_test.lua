-- Actual approval, queue, admission and dialog modules; synthetic terminal IO,
-- real private core storage. No live pane or network.
local api=remuda
local OWNER='@owner:fixture'
local function subject(name,run,without_provider)
  local original,trace=remuda,_butler_session_trace
  local ok,why=pcall(function()
    dofile('tests/butler_dialogs.lua');remuda.butler.dialogs.stop()
    local f,b=remuda,remuda._butler_bus
    local mode={screen='synthetic unparseable footer',instance='fixture-core'}
    local writes,keys,notes={},{},{}
    f.fs={};for k,v in pairs(api.fs)do f.fs[k]=v end
    f.json,f.cli,f.random_bytes,f.clock=api.json,api.cli,api.random_bytes,api.clock
    f.butler.approval=nil;f.butler.owner_input=nil;f.butler.guard_grants=nil
    f.butler.matrix={sanitize_directory_text=function(v)return v end}
    f.butler.guard_policy={append=function(record)
      if mode.audit_change and record.event=='dialog_action' then local change=mode.audit_change;mode.audit_change=nil;change()end
      return not mode.audit_fail
    end,enabled=function()return false end,redact=function(v)return v end}
    f.ls=function()return{{name='codex',alive=true,attached=mode.attached or false,
      human_idle=mode.human_idle or math.huge,instance_id=mode.instance}}end
    f.session=function()return{is_busy=true}end -- output activity is not admission.
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
    run({queue=queue,request=request,event=event,state=state,mode=mode,writes=writes,keys=keys,
      approval=approval,prepared=prepared,bus=b,notes=notes,store_path=dir..'/remuda/butler/input-queue.json'})
  end)
  _G.remuda,_G._butler_session_trace=original,trace
  if not ok then error(why,0)end
end
T.test('approved FIFO retains waiting first and later requests beyond TTL',function()
 subject('fifo',function(s)
  s.bus.pending_tasks.codex=true
  local first=s.request('AA01','first',1);local second=s.request('AA02','second',1);local third=s.request('AA03','third',1)
  T.eq(first.status,'queued');T.eq(second.status,'queued');T.eq(third.status,'queued')
  T.eq(#s.queue.status(),3);s.queue.tick();T.eq(#s.writes,0);T.eq(first.delivery_started,nil)
  s.approval.sweep((os.time()+100)*1000)
  T.eq(first.status,'queued','accepted intent does not expire');T.eq(second.status,'queued')
  s.bus.pending_tasks.codex=nil
  -- Retry clock is advanced only in this disposable interpreter.
  local clock=os.time;os.time=function()return clock()+400 end
  s.queue.tick();s.queue.tick();s.queue.tick();os.time=clock
  T.eq(table.concat(s.writes,','),'first,second,third',api.json.encode(s.queue.status()));T.eq(#s.keys,0)
  for _,r in ipairs(s.queue.status())do T.eq(r.status,'delivered')end
 end)
end)
T.test('audit refusal is prewrite queued; admission or identity changes after intent are uncertain',function()
 subject('audit',function(s)
  local rec=s.request('AB01','exact')
  s.mode.audit_fail=true;s.queue.tick();T.eq(#s.writes,0);T.eq(s.queue.status()[1].status,'queued');T.eq(rec.delivery_started,nil)
 end)
 subject('identity',function(s)
  s.request('AB02','exact');s.mode.audit_change=function()s.mode.instance='replacement'end
  s.queue.tick();T.eq(#s.writes,0);T.eq(s.queue.status()[1].status,'quarantined')
 end)
 subject('after-intent',function(s)
  local rec=s.request('AB03','exact');local write=remuda.fs.write_atomic
  remuda.fs.write_atomic=function(p,body,opts)
   local ok,why=write(p,body,opts)
   if p==s.store_path and body:find('dispatch_intent',1,true)then s.mode.screen='› actual human draft'end
   return ok,why
  end
  s.queue.tick();T.eq(#s.writes,0);T.eq(s.queue.status()[1].status,'uncertain');T.eq(rec.delivery_started,true)
  s.mode.screen='synthetic footer';s.queue.tick();T.eq(#s.writes,0,'no replay after intent')
 end)
end)
T.test('marker failure and ambiguous provider outcomes never replay',function()
 subject('marker',function(s)
  local rec=s.request('AC01','exact');s.mode.marker_fail=true;s.queue.tick()
  T.eq(#s.writes,0);T.eq(s.queue.status()[1].status,'uncertain');T.eq(rec.delivery_started,true)
 end)
 for index,outcome in ipairs({'write_false','write_throw','late','unverified'})do
  subject('provider-'..index,function(s)
   s.request('AC02','exact')
   if outcome=='late'or outcome=='unverified'then s.mode.provider=outcome else s.mode[outcome]=true end
   s.queue.tick();T.eq(#s.writes,1);T.eq(s.queue.status()[1].status,'uncertain')
   s.queue.tick();T.eq(#s.writes,1)
  end)
 end
end)
T.test('cross-ledger acceptance and marker gaps cannot expire or replay accepted input',function()
 subject('association-gap',function(s)
  local rec=s.request('AD01','exact');rec.status='approved';rec.queue_id=nil;rec.expires_at=0
  s.bus.pending_tasks.codex=true;s.approval.sweep(os.time()*1000)
  T.eq(rec.status,'queued');T.ok(rec.queue_id);T.eq(#s.writes,0)
 end)
 subject('intent-no-marker',function(s)
  local rec=s.request('AD02','exact');local write=remuda.fs.write_atomic;local once=true
  remuda.fs.write_atomic=function(p,body,opts)
   local ok,why=write(p,body,opts)
   if once and p==s.store_path and body:find('dispatch_intent',1,true)then once=false;return nil,'synthetic lost fsync ACK'end
   return ok,why
  end
  s.queue.tick();T.eq(#s.writes,0);T.eq(rec.delivery_started,nil);T.eq(s.queue.status()[1].status,'uncertain')
  s.queue.tick();T.eq(#s.writes,0)
 end)
 subject('marker-no-intent',function(s)
  local rec=s.request('AD03','exact');rec.delivery_started=true
  s.approval.sweep(os.time()*1000)
  T.eq(#s.writes,0);T.eq(s.queue.status()[1].status,'uncertain');T.eq(rec.status,'delivery_uncertain')
 end)
end)
T.test('owner line preserves separate RET; failed RET never repeats payload or key',function()
 subject('line-visible',function(s)
  local event=s.event('visible','exact line')
  assert(s.queue.accept_line('codex','exact line',event,'!home:fixture',true))
  s.mode.after_text=function()s.mode.screen='› exact line'end
  s.queue.tick();T.eq(#s.writes,1);T.eq(#s.keys,1);T.eq(s.queue.status()[1].status,'delivered')
 end)
 for _,change in ipairs({'different','human','attached','clock','missing-idle','missing-clock'})do
  subject('line-proof-'..change,function(s)
   local event=s.event(change,'exact line')
   assert(s.queue.accept_line('codex','exact line',event,'!home:fixture',true))
   if change=='missing-clock'then remuda.clock=nil end
   if change=='missing-idle'then
    local ls=remuda.ls;remuda.ls=function()local rows=ls();rows[1].human_idle=nil;return rows end
   end
   s.mode.after_text=function()
    s.mode.screen=change=='different'and'› human draft'or'› exact line'
    if change=='human'then s.mode.human_idle=0 end
    if change=='attached'then s.mode.attached=true end
    if change=='clock'then remuda.clock=function()return -1 end end
   end
   s.queue.tick();T.eq(#s.writes,1);T.eq(#s.keys,0,change)
   T.eq(s.queue.status()[1].status,'uncertain');s.queue.tick();T.eq(#s.writes,1)
  end)
 end
 subject('line',function(s)
  local event=s.event('one','exact line')
  local accepted=assert(s.queue.accept_line('codex','exact line',event,'!home:fixture',true));T.eq(accepted.status,'queued')
  local duplicate=assert(s.queue.accept_line('codex','exact line',event,'!home:fixture',true));T.eq(duplicate.duplicate,true)
  s.mode.key_false=true;s.queue.tick();T.eq(#s.writes,1);T.eq(#s.keys,1);T.eq(s.keys[1],'RET')
  T.eq(s.queue.status()[1].status,'uncertain');s.queue.tick();T.eq(#s.writes,1);T.eq(#s.keys,1)
 end)
 subject('line-key-unknown',function(s)
  local event=s.event('key-unknown','exact line')
  assert(s.queue.accept_line('codex','exact line',event,'!home:fixture',true))
  s.mode.key_nil=true;s.queue.tick()
  T.eq(s.queue.status()[1].status,'uncertain','missing explicit key success cannot report delivered')
  s.queue.tick();T.eq(#s.writes,1);T.eq(#s.keys,1)
 end)
 subject('line-auth',function(s)
  local event=s.event('evil','text');event.sender='@evil:fixture'
  local r=s.queue.accept_line('codex','text',event,'!home:fixture',true);T.eq(r,nil);T.eq(#s.queue.status(),0)
  event=s.event('backfill','text');r=s.queue.accept_line('codex','text',event,'!home:fixture',false);T.eq(r,nil)
 end)
end)

T.test('missing bound provider accepts independent requests but never dispatches by name',function()
 subject('missing-provider',function(s)
  local first=s.request('AE01','first');s.request('AE02','second');s.request('AE03','third')
  s.queue.tick();T.eq(#s.writes,0);T.eq(#s.keys,0);T.eq(first.delivery_started,nil)
  local rows=s.queue.status();T.eq(#rows,3);T.eq(rows[1].reason,'provider_identity_unavailable')
  for _,r in ipairs(rows)do T.eq(r.status,'queued')end
  local cli=dofile('packages/butler/input_queue_cli.lua')
  local ok=pcall(cli.cli,{'cancel',rows[1].id},{tag='member'});T.eq(ok,false,'member cannot cancel owner intent')
  ok=pcall(cli.cli,{'resolve',rows[1].id,'delivered'},{tag='unknown'});T.eq(ok,false)
  local status=cli.cli({'status'},{tag='operator'});T.ok(not status:find('first',1,true),'status omits bytes')
  local cancelled=remuda.json.decode(cli.cli({'cancel',rows[1].id},{tag='operator'}))
  T.eq(cancelled.status,'cancelled');T.eq(cancelled.may_have_written,false)
  s.queue.tick();T.eq(#s.writes,0,'next head still defers without capability')
 end,true)
end)

T.test('human reset at every posttext capture blocks separate Return',function()
 for _,screen in ipairs({'›','unknown renderer'})do
  for point=1,16 do
   subject('capture-'..#screen..'-'..point,function(s)
    local event=s.event('capture-'..point,'exact line')
    assert(s.queue.accept_line('codex','exact line',event,'!home:fixture',true))
    local after,count,injected=false,0,false
    s.mode.after_text=function()after=true;s.mode.screen=screen end
    local capture=remuda.capture
    remuda.capture=function(...)
     if after then
      count=count+1
      if count==point then s.mode.human_idle=0;injected=true end
     end
     return capture(...)
    end
    s.queue.tick()
    if point==8 then T.eq(injected,true,'exercise independent RED cut')end
    if injected then
     T.eq(#s.keys,0,'human reset during capture '..point..' '..screen)
     T.eq(s.queue.status()[1].status,'uncertain')
     s.queue.tick();T.eq(#s.writes,1);T.eq(#s.keys,0)
    end
   end)
  end
 end
end)
T.test('open, denied and expired approvals never enter the queue or block plain input',function()
 subject('pending-outside-queue',function(s)
  local binding=assert(s.queue.binding('codex'))
  for _,id in ipairs({'AE01','AE02','AE03'})do
   local text='unapproved '..id
   s.state.approvals[id]={id=id,kind='approve_text',status='open',event_id='$request-'..id,nonce='nonce-'..id,
    expires_at=(os.time()+30)*1000,created_ms=os.time()*1000,
    data={request_id=id,registered_text=text,bytes=#text,session='codex',session_id=binding.agent_id,
     session_marker=binding.session_marker,core_instance=binding.instance_id,session_binding_version=2}}
  end
  assert(s.approval.answer('$request-AE02','deny',OWNER,'$deny'))
  s.state.approvals.AE03.expires_at=1;s.approval.sweep(os.time()*1000+5000)
  T.eq(s.state.approvals.AE01.status,'open');T.eq(s.state.approvals.AE02.status,'denied');T.eq(s.state.approvals.AE03.status,'expired')
  T.eq(#s.queue.status(),0,'no approval request is a queue record until approved')
  local line=s.event('L1','plain');local receipt=assert(s.queue.accept_line('codex','plain',line,'!home:fixture',true))
  s.queue.tick();T.eq(table.concat(s.writes,','),'plain');T.eq(#s.queue.status(),1);T.eq(receipt.status,'queued')
  assert(s.approval.answer('$request-AE01','approve',OWNER,'$ok'))
  T.eq(#s.queue.status(),2,'approval enqueues exactly once');T.eq(s.approval.answer("$request-AE01","approve",OWNER,"$ok2"),nil)
  T.eq(#s.queue.status(),2,'double approval is idempotent');s.queue.tick()
  T.eq(table.concat(s.writes,','),'plain,unapproved AE01')
 end)
end)
local function resolve_notes(s)
 local out={};for _,n in ipairs(s.notes)do if n:find('input-queue resolve',1,true)then out[#out+1]=n end end;return out
end
T.test('later input passes an uncertain head on a verified empty composer; head is never retyped',function()
 subject('pass-uncertain',function(s)
  s.request('AF01','stuck');s.mode.provider='unverified';s.queue.tick()
  local id=s.queue.status()[1].id;T.eq(s.queue.status()[1].status,'uncertain');T.eq(table.concat(s.writes,','),'stuck')
  s.mode.provider=nil;s.mode.screen='› '
  s.request('AF02','later');s.queue.tick()
  T.eq(table.concat(s.writes,','),'stuck,later');T.eq(s.queue.status()[1].status,'uncertain');T.eq(s.queue.status()[2].status,'delivered')
  s.queue.tick();s.queue.tick();T.eq(table.concat(s.writes,','),'stuck,later','no automatic retype')
  local notes=resolve_notes(s);T.eq(#notes,1,'one notice per uncertain record')
  T.ok(notes[1]:find('remuda butler input-queue resolve '..id..' not_sent|delivered',1,true))
  -- Restart/replay: a fresh adapter over the same ledger does not notify again.
  local again=dofile('packages/butler/owner_input.lua');again.tick();again.tick();T.eq(#resolve_notes(s),1)
  assert(again.resolve(id,'not_sent',OWNER));again.tick();again.tick()
  T.eq(table.concat(s.writes,','),'stuck,later','resolving never types the old item');T.eq(again.status()[1].status,'failed')
 end)
end)
T.test('uncertain head keeps later input blocked unless the composer is positively empty',function()
 for index,screen in ipairs({'› leftover partial','synthetic unparseable footer'})do
  subject('dirty-'..index,function(s)
   s.request('AG01','stuck');s.mode.provider='unverified';s.queue.tick();s.mode.provider=nil
   s.mode.screen=screen;s.request('AG02','later');s.queue.tick()
   T.eq(table.concat(s.writes,','),'stuck','later item not typed');T.eq(s.queue.status()[2].status,'queued')
   T.ok(tostring(s.queue.status()[2].reason):find('^uncertain_ahead_'),tostring(s.queue.status()[2].reason))
  end)
 end
end)
-- Core/Butler contract (warmblood-kr/remuda#763): when the first Return only adds a
-- newline, core sends a retry Return. Before the fix it then reported 'unverified'
-- even if the retry had submitted; after it, it reports 'submitted'. Butler marks an
-- entry delivered only on exactly 'submitted', so the core's answer decides whether
-- the entry and the ones behind it move on.
T.test('contract: type_text unverified after a retry Return leaves the entry uncertain and gates later input',function()
 subject('retry-return-unverified',function(s)
  s.request('AH01','first');s.mode.provider='unverified';s.queue.tick()
  local head=s.queue.status()[1]
  T.eq(head.status,'uncertain');T.eq(head.provider_status,'unverified');T.eq(head.reason,nil)
  -- The composer cannot be confirmed empty here (an unparseable screen), so later input waits.
  s.mode.provider=nil;s.request('AH02','second');s.queue.tick();s.queue.tick()
  T.eq(table.concat(s.writes,','),'first','head is not retyped and the next entry is not typed')
  T.eq(s.queue.status()[1].status,'uncertain');T.eq(s.queue.status()[2].status,'queued')
  T.ok(tostring(s.queue.status()[2].reason):find('^uncertain_ahead_'),tostring(s.queue.status()[2].reason))
  -- Since #524 a positively empty composer lets later input pass; the head stays uncertain.
  s.mode.screen='› '
  local clock=os.time;os.time=function()return clock()+400 end -- skip the deferral backoff
  s.queue.tick();os.time=clock
  T.eq(table.concat(s.writes,','),'first,second');T.eq(s.queue.status()[1].status,'uncertain')
  T.eq(s.queue.status()[2].status,'delivered');T.eq(s.queue.status()[2].provider_status,'submitted')
 end)
end)
T.test('contract: type_text submitted after a retry Return delivers the entry and the next one',function()
 subject('retry-return-submitted',function(s)
  -- Same unparseable screen as the unverified case: delivery must not depend on a composer check.
  s.request('AI01','first');s.request('AI02','second');s.mode.provider='submitted';s.queue.tick();s.queue.tick()
  local rows=s.queue.status()
  T.eq(rows[1].status,'delivered');T.eq(rows[1].provider_status,'submitted')
  T.eq(rows[2].status,'delivered');T.eq(rows[2].provider_status,'submitted')
  T.eq(table.concat(s.writes,','),'first,second');T.eq(#resolve_notes(s),0,'no uncertain notice for delivered entries')
 end)
end)
