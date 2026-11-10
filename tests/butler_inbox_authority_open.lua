local target='packages/butler/inbox_authority.lua'
local file=io.open(target,'r')
if file then file:close() else target='packages/butler/inbox_authority_contract.lua' end
local authority=dofile(target)
local root='/private/qa-authority'
local failures,total={},0
local function config(state)
  local calls={marker=0,sql=0,source=0,importer=0,content=0}
  local value={root=root}
  value.marker={read=function(actual)
    assert(actual==root,'marker inspected wrong root')
    calls.marker=calls.marker+1
    local marker={state=state,format_version=1,root=root,epoch=state=='FILE' and 0 or 2,
      operation_id='transition-2',generation='generation-2'}
    if state=='SQL_ACTIVE' or state=='CUTOVER_PREPARED' then
      marker.protocol='sql-inbox-v1';marker.proof_hash=string.rep('a',64);marker.tail_watermark=0
    end
    if state=='FILE_TRACKED' then marker.protocol='tracked-file-v1';marker.tracking_epoch=2 end
    return marker
  end}
  value.writer={claim=function(actual)
    return {root=actual,owner=true,guarded=true,release=function() end}
  end}
  value.sql={open=function()
    assert(calls.marker==1,'DB opened before authority marker')
    calls.sql=calls.sql+1
    return nil,{code='unavailable'}
  end}
  value.source={snapshot=function() calls.source=calls.source+1; error('stale source accessed') end,
    recipients=function() calls.source=calls.source+1; error('stale recipients accessed') end}
  value.importer={import_all=function() calls.importer=calls.importer+1; error('stale import') end,
    status=function() return {partial=false} end,available=function() return false end}
  value.content={publish=function() calls.content=calls.content+1; error('unexpected publication') end,
    hydrate=function() calls.content=calls.content+1; error('unexpected hydration') end}
  value.pump={schedule=function() return {cancel=function() end} end}
  return value,calls
end
local opened={}
local function open(cfg)
  local store,err=authority.open(cfg)
  if store then opened[#opened+1]=store end
  return store,err
end
local function test(name,fn)
  total=total+1
  local ok,err=pcall(fn)
  for _,store in ipairs(opened) do if type(store.close)=='function' then store:close() end end
  opened={}
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
test('FILE tolerates unavailable shadow as degraded file store',function()
  local cfg,calls=config('FILE')
  local store,err=open(cfg)
  assert(store,'FILE open rejected '..tostring(err and err.code))
  local status=assert(store:status())
  assert(status.authority=='file','FILE authority changed')
  assert(calls.marker==1,'marker not checked')
  assert(type(store.close)=='function' and store:close()==true,'FILE owner not released')
end)
for _,state in ipairs({'CUTOVER_PREPARED','SQL_ACTIVE','RECOVERY_REQUIRED'}) do
  test(state..' unavailable SQL cannot fallback to stale files',function()
    local cfg,calls=config(state)
    local store,err=open(cfg)
    assert(store==nil and type(err)=='table','SQL-required open did not fail closed')
    assert(err.code~='contract_unimplemented','abstract stub is not failure classification')
    assert(calls.marker==1,'authority marker not read')
    if state~='RECOVERY_REQUIRED' then
      assert(calls.sql==1 and err.code=='sql_required','valid SQL-required marker did not exercise unavailable DB')
    else assert(calls.sql==0,'recovery marker opened a backend') end
    assert(calls.source==0 and calls.importer==0 and calls.content==0,'stale file fallback occurred')
  end)
end
test('ambiguous marker refuses before DB or file access',function()
  local cfg,calls=config('FILE')
  cfg.marker.read=function() calls.marker=calls.marker+1; return nil,{code='corrupt'} end
  local store,err=open(cfg)
  assert(store==nil and err and err.code=='recovery_required','ambiguous marker guessed authority')
  assert(calls.sql==0 and calls.source==0,'opened backend before resolving marker')
end)
test('marker read exception refuses before DB or file access',function()
  local cfg,calls=config('FILE')
  cfg.marker.read=function() calls.marker=calls.marker+1; error('injected marker read failure') end
  local store,err=open(cfg)
  assert(store==nil and err and err.code~='contract_unimplemented','marker exception not classified')
  assert(calls.sql==0 and calls.source==0,'opened backend despite unreadable marker')
end)
test('writer refusal prevents import and content mutation',function()
  local cfg,calls=config('FILE')
  cfg.writer.claim=function() return nil,{code='writer_conflict'} end
  local store,err=open(cfg)
  assert(store==nil and err and err.code=='writer_conflict','writer conflict not preserved')
  assert(calls.importer==0 and calls.source==0 and calls.content==0,'writer refusal mutated sources')
end)
for _,capability in ipairs({{root=root,owner=false,guarded=true},{root=root,owner=true,guarded=false},{root=root,owner=false,guarded=false}}) do
  test('supplied writer lacks owner or guarded capability',function()
    local cfg,calls=config('FILE')
    cfg.writer.claim=function() return capability end
    local store,err=open(cfg)
    assert(store==nil and err and err.code=='writer_conflict','invalid writer capability admitted')
    assert(calls.importer==0 and calls.source==0 and calls.content==0,'invalid writer accessed sources')
  end)
end
test('FILE epoch2 remains explicitly invalid',function()
  local cfg,calls=config('FILE')
  cfg.marker.read=function() calls.marker=calls.marker+1;return {format_version=1,state='FILE',root=root,epoch=2} end
  local store,err=open(cfg)
  assert(store==nil and err and err.code=='recovery_required','nonzero FILE epoch accepted')
  assert(calls.sql==0,'invalid FILE epoch opened DB')
end)
test('malformed SQL marker refuses before DB separately from outage',function()
  local cfg,calls=config('SQL_ACTIVE')
  cfg.marker.read=function() calls.marker=calls.marker+1;return {format_version=1,state='SQL_ACTIVE',root=root,epoch=2} end
  local store,err=open(cfg)
  assert(store==nil and err and err.code=='recovery_required','partial SQL marker accepted')
  assert(calls.sql==0,'malformed SQL marker exercised wrong outage branch')
end)
test('FILE_TRACKED unavailable journal refuses without source',function()
  local cfg,calls=config('FILE_TRACKED')
  local store,err=open(cfg)
  assert(store==nil and err and err.code=='unavailable','tracked marker unavailable journal not refused')
  assert(calls.sql==1 and calls.source==0 and calls.importer==0 and calls.content==0,'tracked outage touched source')
end)
if #failures>0 then error('authority open '..#failures..'/'..total..' failed\n'..table.concat(failures,'\n')) end
print('PASS authority open '..total..' cases ['..target..']')
