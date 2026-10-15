-- Production orchestration with synthetic screens only; also run in a private daemon.
remuda._butler_compaction_has_session = function() return true end
remuda._butler_compaction_preflight = function() end
remuda._butler_compaction_action_guard = function() end
remuda._butler_compaction_failure_cooldown = function() return false end
remuda._butler_compaction_failure_exhausted = function() return false end
remuda._butler_mail = {unread=function() return 0 end}
local serial = 0
local function scenario(outcome)
  serial = serial + 1
  local name = 'preserve-' .. serial
  local commands, reports, watcher, options = {}, {}, nil, nil
  local used = 500000
  local footer = 'GPT-6.1-Sol low · /work\n› Ask Codex to do anything'
  remuda._butler_state = {compaction_members={}}
  remuda._butler_bus.agents[name] = {id=name, kind='codex', session_name=name, parent='leader'}
  remuda._butler_telemetry_for = function() return {context_used=used, model='gpt-6.1-sol'} end
  remuda.butler.ctx_level = function() return {used=used, level='critical'} end
  remuda.capture = function() return footer end
  remuda.session = function() return {is_busy=false, attached=false} end
  remuda._butler_send = function(_, _, text) reports[#reports+1] = text; return true end
  remuda._butler_notice_compacted = function() end
  remuda.type_text = function(_, text)
    commands[#commands+1] = text
    return outcome ~= 'refused'
  end
  remuda.key = function() error('new compaction must never press picker keys') end
  remuda.expect = function(_, branches, opts)
    watcher, options = branches[1], opts
    return {cancel=function() end}
  end
  assert(remuda._butler_compaction_execute(name, true) == 'started')
  local state = remuda._butler_state.compaction_members[name]
  assert(table.concat(commands, ',') == '/compact', 'only /compact is sent')
  assert(not state.restore_pending and not state.dialog_operation, 'no model switch or restore debt')
  if outcome == 'success' then
    used = 100000
    assert(watcher.id == 'compact-complete' and watcher.match(footer))
    watcher.action(footer)
    assert(#reports == 0)
  elseif outcome == 'timeout' then
    options.on_timeout(footer)
    assert(reports[1]:find('Compaction not confirmed yet', 1, true))
  elseif outcome == 'unknown' then
    options.on_unknown()
    assert(reports[1]:find('unrecognized dialog', 1, true))
  elseif outcome == 'error' then
    options.on_error('synthetic error')
    assert(reports[1]:find('watcher error', 1, true))
  elseif outcome == 'refused' then
    assert(not watcher and reports[1]:find('command failed', 1, true))
  end
  assert(not state.compaction_in_progress and not remuda._butler_state.compaction_fleet_active)
  assert(footer:find('GPT-6.1-Sol low', 1, true), 'intended model and effort remain')
end
for _, outcome in ipairs({'success','timeout','unknown','error','refused'}) do scenario(outcome) end
-- Legacy restore-only orchestration, including effort movement and bounded
-- abort. No new compaction run creates this state anymore.
local function legacy(outcome)
  local name='legacy-'..outcome
  local prior='codex:gpt-6.1-sol high'
  local state={restore_pending=prior}
  local screen='GPT-6-Luna high · /work\n› Ask Codex to do anything'
  local commands,keys,watcher,options,reports={},{},nil,nil,{}
  remuda._butler_state={compaction_members={[name]=state}}
  remuda._butler_bus.agents[name]={id=name,kind='codex',session_name=name,parent='leader'}
  remuda.capture=function() return screen end
  remuda.type_text=function(_,text) commands[#commands+1]=text;return true end
  remuda.key=function(_,key) keys[#keys+1]=key;return true end
  remuda.expect=function(_,branches,opts) watcher,options=branches[1],opts;return {cancel=function() end} end
  remuda._butler_send=function(_,_,text) reports[#reports+1]=text end
  assert(remuda._butler_compaction_execute(name,true)=='restoring_model')
  local function drive(id,painted)
    screen=painted;assert(watcher.id==id,watcher.id);assert(watcher.match(screen));watcher.action(screen)
  end
  local list='Select Model and Effort\n› 1. GPT-6.1-Sol\n  2. GPT-6-Luna (current)\nenter select · esc back'
  local effort='Select Reasoning Level for GPT-6.1-Sol\n  1. Low\n› 2. Medium (default)\n  3. High\n  4. Max\n  5. Ultra\nenter default · s session · esc back'
  drive('codex-model-picker',list)
  drive('codex-effort-picker',effort)
  assert(keys[2]=='<down>','move only to recorded High effort')
  effort=effort:gsub('› 2','  2'):gsub('  3','› 3')
  drive('codex-effort-row',effort)
  assert(keys[3]=='s','apply session-only')
  if outcome=='success' then
    drive('codex-model-set','GPT-6.1-Sol high · /work\n› Ask Codex to do anything')
    assert(not state.restore_pending,'clear only after observed restored model+effort')
  elseif outcome=='ignored' then
    options.on_timeout(effort)
    drive('codex-picker-escape',effort)
    drive('codex-effort-picker-closed',list)
    drive('codex-picker-escape',list)
    local ready='GPT-6-Luna high · /work\n› Ask Codex to do anything'
    drive('codex-model-picker-closed',ready)
    drive('codex-picker-escape',ready)
    assert(keys[4]=='ESC' and keys[5]=='ESC' and #keys==5,'bounded cleanup')
    assert(state.restore_pending==prior,'failed apply must retain intended settings')
  else
    options.on_unknown()
    assert(state.restore_pending==prior and #keys==3,'unknown dialog preserves restore debt and sends no key')
  end
  assert(table.concat(commands,',')=='/model','legacy recovery only restores; never compacts')
end
for _, outcome in ipairs({'success','ignored','unknown'}) do legacy(outcome) end
-- Malformed records and later owner-selected settings never get overwritten.
for _, pair in ipairs({{'codex:malformed','Ask Codex to do anything'},
    {'codex:gpt-6.1-sol low','GPT-6-Astra high · /work\n› Ask Codex to do anything'}}) do
  local name='legacy-defer'
  local state={restore_pending=pair[1]}
  remuda._butler_state={compaction_members={[name]=state}}
  remuda._butler_bus.agents[name]={id=name,kind='codex',session_name=name}
  remuda.capture=function() return pair[2] end
  remuda.type_text=function() error('must not overwrite unknown/user model') end
  assert(remuda._butler_compaction_execute(name,true)=='restore_pending')
  assert(state.restore_pending==pair[1])
end
return 'ok'
