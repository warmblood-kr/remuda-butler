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
  local member={kind='session',session=bus.agents.butler.session_name,
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
