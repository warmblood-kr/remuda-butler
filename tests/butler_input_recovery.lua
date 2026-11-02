-- Real dialog module; synthetic captures/keys only. No live user pane.
dofile('tests/butler_dialogs.lua')
local D, bus = remuda.butler.dialogs, remuda._butler_bus
local function fixture(path)
  local f=assert(io.open(path));local text=f:read('*a');f:close();return text
end
local effort=fixture('tests/fixtures/codex-0162-effort-picker.txt')
local model=fixture('tests/fixtures/codex-0162-model-picker.txt')
local ready='› Ask Codex to do anything\nGPT-6.1-Sol low · /private'
local parser=remuda._butler_agent_startup.codex.picker
assert(parser(effort).kind=='effort' and parser(model).kind=='model')
assert(not parser(effort:gsub('More reasoning…','Unknown action')))
assert(not parser(effort..'Choose another thing\n› 1. Yes\n2. No'))
D.stop()
local screen, instance, keys, watcher, opts, results, fail_audit, audit_hook, refused, stuck
remuda.capture=function() return screen end
remuda.ls=function() return {{name='codex',alive=true,instance_id=instance}} end
remuda._butler_telemetry_for=function() return {model='gpt-6.1-sol'} end
remuda._butler_prompt_is_empty=function(_, s) return s:find('Ask Codex to do anything',1,true) and 'EMPTY' or 'NON-EMPTY' end
remuda.butler.guard_policy.append=function(record)
  if audit_hook then audit_hook(record) end
  return not fail_audit
end
remuda.key=function(_, key)
  assert(key=='ESC','recovery may only cancel')
  if refused then return false end
  keys[#keys+1]=key
  if not stuck then screen=parser(screen).kind=='effort' and model or ready end
  return true
end
remuda.expect=function(_, branches, options)
  watcher,opts=branches[1],options
  return {cancel=function() end}
end
D.install()
local function reset(s)
  screen,instance,keys,watcher,opts,results=s,'cx',{},nil,nil,{}
  fail_audit,audit_hook,refused,stuck=false,nil,false,false
  remuda._butler_state.compaction_fleet_active=nil
  remuda._butler_state.compaction_members={}
  bus.dialog_states={}
end
local function run() D.recover_input('codex',function(text) results[#results+1]=text end) end
local function advance()
  assert(watcher.match(screen),'expected observed transition')
  watcher.action(screen)
end
reset(effort);run()
assert(#keys==1 and #results==0)
run();assert(results[1]:find('already pending',1,true));results={}
advance();assert(#keys==2 and #results==0);advance()
assert(#results==1 and results[1]:find('completed; composer is safe',1,true))
assert(results[1]:find('gpt-6.1-sol low',1,true) and not results[1]:find('restored',1,true))
assert(#keys==2,'bounded two-ESC cancellation')
reset(model);run();advance();assert(#keys==1 and #results==1)
reset('Unknown prompt\n› 1. Yes\n2. No');run();assert(#keys==0 and results[1]:find('refused',1,true))
reset(effort);fail_audit=true;run();assert(#keys==0 and results[1]:find('audit unavailable',1,true))
reset(effort);audit_hook=function(r) if r.event=='dialog_action' then instance='replacement' end end
run();assert(#keys==0 and results[1]:find('changed during audit',1,true))
reset(effort);refused=true;run();assert(#keys==0 and results[1]:find('refused',1,true))
reset(effort);stuck=true;run();assert(not watcher.match(screen));opts.on_timeout()
assert(#keys==1 and #results==1 and results[1]:find('timed out',1,true))
reset(effort);run();screen='Unknown prompt\n› 1. Yes\n2. No';advance()
assert(#keys==1 and results[1]:find('without a verified safe composer',1,true))
reset(effort);run();instance='replacement';advance()
assert(#keys==1 and results[1]:find('session changed',1,true))
reset(effort);run();screen=ready:gsub('Ask Codex to do anything','human draft');advance()
assert(#keys==1 and results[1]:find('without a verified safe composer',1,true))
reset(effort);remuda._butler_state.compaction_members[bus.agents.codex.id]={compaction_in_progress=true}
run();assert(#keys==0 and results[1]:find('workflow still owns',1,true))
reset(effort);audit_hook=function(r) if r.event=='dialog_action' then screen=model end end
run();assert(#keys==0 and results[1]:find('changed during audit',1,true))
reset(effort);run();screen=effort:gsub('GPT%-6%-Luna','GPT-6.1-Sol');advance()
assert(#keys==1 and results[1]:find('unexpected picker transition',1,true))
reset(effort);audit_hook=function(r)
  if r.event=='dialog_action' then remuda._butler_state.compaction_members[bus.agents.codex.id]={dialog_operation={}} end
end
run();assert(#keys==0 and results[1]:find('changed during audit',1,true))
print('Owner picker cancellation: PASS')
