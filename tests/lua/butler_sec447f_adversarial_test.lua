T.install_mod('butler', assert(os.getenv('REMUDA_LUA_REPO')))
T.eval([[remuda._butler_argv={'sleep','120'}; remuda._butler_skip_relay=true; remuda.exec('butler')]])
T.wait_until(function() return T.eval('return remuda._butler_bus and remuda._butler_bus.agents.butler ~= nil')=='true' end,5,'root')

T.test('guard_hook_refuses_unresolved_callers_before_approval_mutation',function()
 local result=T.eval([=[
  local gp=remuda.butler.guard_policy
  local dir=os.getenv('XDG_DATA_HOME')..'/hook-probe'; remuda.mkdir(dir); remuda._butler_guard_dir=dir
  gp.set(true); gp.set_approvals(true); gp.set_grants(false)
  local state={approvals=remuda.json.object({})}; local posts,saves=0,0
  remuda.butler.approval.attach(state,function()
    saves=saves+1
    return remuda.fs.write_atomic(dir..'/approval-state.json',remuda.json.encode(state),{private=true})
  end,function(text,relation,cb)
    posts=posts+1; if cb then cb({event_id='$probe'..posts}) end; return {}
  end)
  local pending=remuda.pending
  remuda.pending=function() return {resolve=function() end} end
  local bus=remuda._butler_bus
  bus.agents.duplicate={id='DUPLICATE',alias='duplicate',session_name=bus.agents.butler.session_name}
  local cases={{kind='unknown'},{},{kind='service',service='timer'},
    {kind='session',session='unregistered'},{kind='session',session=bus.agents.butler.session_name}}
  local output={}
  for i,c in ipairs(cases) do
    c.env={REMUDA_BUTLER_AGENT_ALIAS='FORGED-'..i,REMUDA_BUTLER_AGENT_KIND='claude'}
    c.stdin=remuda.json.encode({hook_event_name='PermissionRequest',tool_name='WebFetch',
      tool_input={url='https://example.com/'..i},cwd='/tmp'})
    local principal=remuda._butler_caller_principal.resolve(c)
    local before=posts
    local ok,out=pcall(remuda._extension_commands.butler,{'guard'},c)
    output[#output+1]=principal.tag..'/'..tostring(ok)..'/posts='..(posts-before)..'/out='..tostring(out)
  end
  bus.agents.duplicate=nil
  local member={kind='session',session=bus.agents.butler.session_name,instance_id=_inst(bus.agents.butler.session_name),
    env={REMUDA_BUTLER_AGENT_ALIAS='FORGED-MEMBER',REMUDA_BUTLER_AGENT_KIND='claude'},
    stdin=remuda.json.encode({hook_event_name='PreToolUse',tool_name='Bash',tool_input={command='ls'},cwd='/tmp'})}
  local before=posts
  local member_ok=pcall(remuda._extension_commands.butler,{'guard'},member)
  local audit_file=assert(io.open(gp.log_path(),'r')); local audit_text=audit_file:read('a'); audit_file:close()
  output[#output+1]='legit/member='..tostring(member_ok)..'/posts='..(posts-before)
    ..'/audit-member='..tostring(audit_text:find('"session":"butler"',1,true)~=nil)
    ..'/forged='..tostring(audit_text:find('FORGED-MEMBER',1,true)~=nil)
  remuda.pending=pending
  local f=io.open(dir..'/approval-state.json','r'); local persisted=f and f:read('a') or ''; if f then f:close() end
  output[#output+1]='persisted='..tostring(persisted:find('FORGED-',1,true)~=nil)..'/saves='..saves
  return table.concat(output,';')
 ]=])
 T.expect(not result:find('posts=1',1,true) and not result:find('persisted=true',1,true),result)
 T.expect(result:find('Next:',1,true), 'refusal must include Next: ' .. result)
 T.expect(result:find('legit/member=true/posts=0/audit-member=true/forged=false',1,true),result)
 T.expect(true,'','GUARD-HOOK-REFUSAL '..result)
end)

T.test('status_helpers_refuse_unknown_caller_without_overwriting_member_telemetry',function()
 local result=T.eval([=[
  local path=remuda._butler_status_path
  assert(remuda.fs.write_atomic(path,'MODEL:LIVE CTX:1 CTXWIN:2 CTXPCT:3\n',{private=true}))
  assert(remuda.fs.write_atomic(path..'.state','idle 1\n',{private=true}))
  local bus=remuda._butler_bus; local session=bus.agents.butler.session_name
  local duplicate={id='DUPLICATE',alias='duplicate',kind='claude',session_name=session}
  local cases={{kind='unknown'},{kind='session',session='unregistered'},
    {kind='session',session=session,ambiguous=true}}
  local output={}
  for i,c in ipairs(cases) do
    if c.ambiguous then bus.agents.duplicate=duplicate end
    c.stdin=remuda.json.encode({model={display_name='FORGED-'..i},
      context_window={total_input_tokens=1,context_window_size=2,used_percentage=50}})
    local ok,out=pcall(remuda._extension_commands.butler,{'statusline',path},c)
    c.stdin=remuda.json.encode({hook_event_name='UserPromptSubmit'})
    local stateok,stateout=pcall(remuda._extension_commands.butler,{'status-hook',path},c)
    if c.ambiguous then bus.agents.duplicate=nil end
    local f=assert(io.open(path,'r'));local model=f:read('l');f:close()
    f=assert(io.open(path..'.state','r'));local state=f:read('l');f:close()
    output[#output+1]=tostring(ok)..'/'..tostring(out)..'/'..model..'/'..tostring(stateok)
      ..'/'..tostring(stateout)..'/'..state
  end
  return table.concat(output,';')
 ]=])
 T.expect(result:find('Next:',1,true), 'refusal must include Next: ' .. result)
 T.expect(not result:find('MODEL:FORGED',1,true),result)
 T.expect(result:find('MODEL:LIVE CTX:1 CTXWIN:2 CTXPCT:3'),result)
 T.expect(not result:find('/working ',1,true),result)
 T.expect(result:find('/idle 1',1,true),result)
 T.expect(true,'','TELEMETRY-REFUSAL '..result)
end)

T.test('status_helpers_refuse_another_members_telemetry_path',function()
 local result=T.eval([=[
  local bus=remuda._butler_bus
  local dir=os.getenv('XDG_DATA_HOME')..'/member-telemetry'; remuda.mkdir(dir)
  local pa,pb=dir..'/a.status',dir..'/b.status'
  bus.agents.alice={id='ALICE',alias='alice',kind='claude',session_name='alice-s',telemetry={status_path=pa}}
  bus.agents.bob={id='BOB',alias='bob',kind='claude',session_name='bob-s',telemetry={status_path=pb}}
  assert(remuda.fs.write_atomic(pb,'MODEL:BOB CTX:1 CTXWIN:2 CTXPCT:3\n',{private=true}))
  assert(remuda.fs.write_atomic(pb..'.state','idle 1\n',{private=true}))
  local function read(p) local f=io.open(p,'r'); if not f then return 'none' end local s=f:read('l'); f:close(); return s end
  local function call(verb,path,stdin)
    local c={kind='session',session='alice-s',stdin=remuda.json.encode(stdin)}
    return pcall(remuda._extension_commands.butler,{verb,path},c)
  end
  local snap={model={display_name='FORGED'},context_window={total_input_tokens=1,context_window_size=2,used_percentage=50}}
  local hook={hook_event_name='UserPromptSubmit'}
  call('statusline',pb,snap); call('status-hook',pb,hook)
  local out={'b='..read(pb)..'|'..read(pb..'.state')}
  call('statusline',pa,snap); call('status-hook',pa,hook)
  out[#out+1]='a='..read(pa)..'|'..(read(pa..'.state') or ''):match('^%a+')
  bus.agents.alice=nil; bus.agents.bob=nil
  return table.concat(out,';')
 ]=])
 T.expect(result:find('b=MODEL:BOB CTX:1 CTXWIN:2 CTXPCT:3|idle 1;',1,true),result)
 T.expect(result:find('a=MODEL:FORGED CTX:1 CTXWIN:2 CTXPCT:50|working',1,true),result)
 T.expect(true,'','FOREIGN-TELEMETRY '..result)
end)

T.test('approve_text_tool_refuses_unresolved_requester_before_registering',function()
 local result=T.eval([=[
  local feature=remuda.butler.approve_text
  local tool
  for k,v in pairs(remuda.tools) do
    if k=='butler_approve_text' or (type(v)=='table' and v.name=='butler_approve_text') then tool=v end
  end
  assert(tool,'butler_approve_text tool not found')
  local bus=remuda._butler_bus
  bus.tokens['member-token']={id=bus.agents.butler.id,generation=bus.agents.butler.session_start_marker}
  local real_request,real_allowed=feature.request,feature.target_session_allowed
  local askers={}
  feature.target_session_allowed=function() return true end
  feature.request=function(_,_,asker) askers[#askers+1]=asker; return 'ID' end
  local function try(c)
    askers={}
    local ok,err=pcall(tool.run,{session='butler',text='hello'},c)
    return tostring(ok)..'/'..#askers..'/'..(askers[1] or tostring(err):sub(1,60))
  end
  local out={
    'invalid-token='..try({capability='invalid'}),
    'empty='..try({}),
    'service='..try({kind='service',service='timer'}),
    'unregistered='..try({kind='session',session='unregistered'}),
    'member='..try({capability='member-token'}),
    'operator='..try({kind='outside'}),
  }
  feature.request,feature.target_session_allowed=real_request,real_allowed
  bus.tokens['member-token']=nil
  return table.concat(out,';')
 ]=])
 for _,name in ipairs({'invalid-token','empty','service','unregistered'}) do
  T.expect(result:find(name..'=false/0/',1,true),result)
 end
 T.expect(result:find('member=true/1/butler',1,true),result)
 T.expect(result:find('operator=false/0/',1,true),result)
 T.expect(true,'','APPROVE-TEXT-REQUESTER '..result)
end)

T.test('approve_text_tool_refuses_unresolved_requester_when_member_named_outside',function()
 local result=T.eval([=[
  local feature=remuda.butler.approve_text
  local tool
  for k,v in pairs(remuda.tools) do
    if k=='butler_approve_text' or (type(v)=='table' and v.name=='butler_approve_text') then tool=v end
  end
  assert(tool,'butler_approve_text tool not found')
  local bus=remuda._butler_bus
  bus.agents.outside={id='0123456789ABCDEFGHJKMNPQRS',alias='outside',session_name='outside-sess',session_start_marker='M'}
  bus.identity_ids['0123456789ABCDEFGHJKMNPQRS']={id='0123456789ABCDEFGHJKMNPQRS',alias='outside',state='running'}
  bus.tokens['member-token']={id=bus.agents.butler.id,generation=bus.agents.butler.session_start_marker}
  local real_ls=remuda.ls -- the fixture member has a live native session
  remuda.ls=function() local r=real_ls(); r[#r+1]={name='outside-sess',alive=true}; return r end
  bus.tokens['outside-token']={id='0123456789ABCDEFGHJKMNPQRS',generation='M'}
  local real_request,real_allowed=feature.request,feature.target_session_allowed
  local askers={}
  feature.target_session_allowed=function() return true end
  feature.request=function(_,_,asker) askers[#askers+1]=asker; return 'ID' end
  local function try(c)
    askers={}
    local ok,err=pcall(tool.run,{session='butler',text='hello'},c)
    return tostring(ok)..'/'..#askers..'/'..(askers[1] or tostring(err):sub(1,60))
  end
  local out={
    'invalid-token='..try({capability='invalid'}),
    'empty='..try({}),
    'service='..try({kind='service',service='timer'}),
    'member='..try({capability='member-token'}),
    'outsider='..try({kind='session',session='outside-sess',instance_id='I-OUTSIDE'}),
    'outsider-token='..try({capability='outside-token'}),
    'operator='..try({kind='outside'}),
  }
  feature.request,feature.target_session_allowed=real_request,real_allowed
  remuda.ls=real_ls
  bus.agents.outside,bus.identity_ids['0123456789ABCDEFGHJKMNPQRS']=nil,nil
  bus.tokens['member-token']=nil
  bus.tokens['outside-token']=nil
  return table.concat(out,';')
 ]=])
 for _,name in ipairs({'invalid-token','empty','service'}) do
  T.expect(result:find(name..'=false/0/',1,true),result)
 end
 T.expect(result:find('member=true/1/butler',1,true),result)
 T.expect(result:find('outsider=true/1/outside',1,true),result)
 T.expect(result:find('outsider-token=true/1/outside',1,true),result)
 T.expect(result:find('operator=false/0/',1,true),result)
 T.expect(true,'','APPROVE-TEXT-OUTSIDE-MEMBER '..result)
end)

T.test('archive_listing_error_refuses_operator_resolution',function()
 local result=T.eval([=[
  local gp=remuda.butler.guard_policy
  local dir=os.getenv('XDG_DATA_HOME')..'/list-failure'; remuda.mkdir(dir); remuda._butler_guard_dir=dir
  local base=gp.log_path(); local stamp=os.date('!%Y%m%dT%H%M%SZ')
  for i=1,20 do local f=assert(io.open(base..'.'..stamp..'-'..i,'w'));f:write('evidence');f:close() end
  local list=remuda.list_dir
  remuda.list_dir=function(path) if path==dir then error('injected directory read error') end return list(path) end
  local p=remuda._butler_caller_principal.resolve({kind='outside'})
  remuda.list_dir=list
  local n=0;for _,name in ipairs(list(dir)) do if name:match('^guard%-audit%.jsonl%.%d%d%d%d%d%d%d%dT') then n=n+1 end end
  return p.tag..'|archives='..n
 ]=])
 T.eq(result,'unidentified|archives=20')
 T.expect(true,'','ARCHIVE-LIST-FAILURE '..result)
end)

T.test('read_open_failure_preserves_existing_audit_evidence_and_refuses_operator',function()
 local result=T.eval([=[
  local gp=remuda.butler.guard_policy
  local dir=os.getenv('XDG_DATA_HOME')..'/audit-read-failure';remuda.mkdir(dir);remuda._butler_guard_dir=dir
  assert(gp.append({event='prior-evidence',summary='PRESERVE-ME'}))
  local base,real=gp.log_path(),io.open
  io.open=function(path,mode) if path==base and mode=='r' then return nil,'injected read open failure' end return real(path,mode) end
  local p=remuda._butler_caller_principal.resolve({kind='outside'})
  io.open=real
  local f=assert(real(base,'r'));local body=f:read('a');f:close()
  return p.tag..'|old-preserved='..tostring(body:find('PRESERVE-ME',1,true)~=nil)
 ]=])
 T.eq(result,'unidentified|old-preserved=true')
 T.expect(true,'','AUDIT-READ-FAILURE '..result)
end)

T.test('real_write_only_audit_file_is_replaced_and_mail_mutates',function()
 local result=T.eval([=[
  if remuda.process.run({argv={'id','-u'}}).stdout:match('^%s*0%s*$') then return 'SKIP-root' end
  local gp=remuda.butler.guard_policy
  local dir=os.getenv('XDG_DATA_HOME')..'/real-write-only';remuda.mkdir(dir);remuda._butler_guard_dir=dir
  assert(gp.append({event='prior-evidence',summary='PRESERVE-ME'}))
  local path=gp.log_path()
  local chmod=remuda.process.run({argv={'chmod','200',path}});assert(chmod.code==0)
  local f,why=io.open(path,'r'); assert(not f,'read must really fail')
  local function messages() local n=0;for _ in pairs(remuda._butler_bus.messages) do n=n+1 end;return n end
  local before=messages()
  local c=remuda.caller();assert(c.kind=='outside')
  local ok,out=pcall(remuda._extension_commands.butler,{'send','butler','after-read-failure'},c)
  remuda.process.run({argv={'chmod','600',path}})
  f=assert(io.open(path,'r'));local body=f:read('a');f:close()
  local sent=ok and not tostring(out):find('Next:',1,true)
  return 'read-error='..tostring(why)..'|sent='..tostring(sent)..'|mail-mutated='..tostring(messages()>before)
    ..'|old-preserved='..tostring(body:find('PRESERVE-ME',1,true)~=nil)
    ..'|policy-present='..tostring(body:find('caller_policy',1,true)~=nil)
 ]=])
 if result=='SKIP-root' then T.expect(true,'','SKIP real chmod test when root')
 else T.expect(result:find('|sent=false|mail-mutated=false|old-preserved=true|policy-present=false',1,true),result) end
 T.expect(true,'','REAL-AUDIT-READ-FAILURE '..result)
end)

T.test('real_unlistable_archive_directory_refuses_operator',function()
 local result=T.eval([=[
  if remuda.process.run({argv={'id','-u'}}).stdout:match('^%s*0%s*$') then return 'SKIP-root' end
  local gp=remuda.butler.guard_policy
  local dir=os.getenv('XDG_DATA_HOME')..'/real-list-failure';remuda.mkdir(dir);remuda._butler_guard_dir=dir
  local base=gp.log_path();local stamp=os.date('!%Y%m%dT%H%M%SZ')
  for i=1,20 do local f=assert(io.open(base..'.'..stamp..'-'..i,'w'));f:write('evidence');f:close() end
  remuda.process.run({argv={'chmod','300',dir}})
  local list_ok,err=pcall(remuda.list_dir,dir)
  local p=remuda._butler_caller_principal.resolve({kind='outside'})
  remuda.process.run({argv={'chmod','700',dir}})
  local n=0;for _,name in ipairs(remuda.list_dir(dir)) do if name:match('^guard%-audit%.jsonl%.%d%d%d%d%d%d%d%dT') then n=n+1 end end
  return tostring(list_ok)..'|'..p.tag..'|archives='..n..'|list-result='..tostring(err)
 ]=])
 if result=='SKIP-root' then T.expect(true,'','SKIP real chmod test when root')
 else T.expect(result:find('false|unidentified|archives=20',1,true),result) end
 T.expect(true,'','REAL-ARCHIVE-LIST-FAILURE '..result)
end)

T.test('real_unregistered_managed_cli_cannot_write_root_status',function()
 local result=T.eval([=[
  local path=remuda._butler_status_path
  assert(remuda.fs.write_atomic(path..'.state','working 1\n',{private=true}))
  local scratch=os.getenv('XDG_DATA_HOME')
  local output=scratch..'/native-hook.out'
  local exe=os.getenv('REMUDA_BIN');local server=os.getenv('REMUDA_LUA_CHILD_SERVER')
  local code='local c=remuda.caller();local p=remuda._butler_caller_principal.resolve(c);return c.kind.."|"..p.tag'
  local script=string.format('export REMUDA_BUTLER_AGENT_ID=butler; %q -s %q -e %q > %q; printf %q | %q -s %q --stdin butler status-hook %q; exec sleep 30',
    exe,server,code,output,'{"hook_event_name":"Stop"}',exe,server,path)
  remuda.new('unregistered-native-hook',{'sh','-c',script})
  remuda._sec447f_native_hook_output=output
  remuda._sec447f_native_hook_script=script
  return 'started'
 ]=])
 T.eq(result,'started')
 local waited,err=pcall(T.wait_until,function()
  return T.eval([=[local f=io.open(remuda._butler_status_path..'.state','r');local s=f and f:read('l');if f then f:close() end;return s and s:find('working ',1,true)~=nil]=])=='true'
 end,5,'unregistered hook did not preserve working state')
 T.eval([[remuda.process.run({argv={'sleep','0.3'},timeout=1})]])
 if not waited then error(tostring(err)..'\n'..T.eval([[return remuda._sec447f_native_hook_script..'\n'..remuda.capture('unregistered-native-hook')]])) end
 result=T.eval([=[local f=assert(io.open(remuda._sec447f_native_hook_output,'r'));local s=f:read('a');f:close();return (s:gsub('\n$',''))]=])
 T.eq(result,'session|unidentified')
 T.expect(true,'','REAL-UNREGISTERED-HOOK '..result..'|root-status=working')
end)
