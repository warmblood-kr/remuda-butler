-- Recognised dialog states (#499): named reports, the Teach "Not now" answer,
-- and reporting of an unchanged unrecognised choice. Synthetic screens plus
-- the Teach/Codex transcript fixtures; no daemon or agent process.
local screens, reports, audits, writes, logs = {}, {}, {}, {}, {}
local fail_audit, human, on_key, before_write
local bus = { agents = {
  child = { id = 'child-id', kind = 'claude', parent = 'leader', instance_id = 'one' },
  codex = { id = 'codex-id', kind = 'codex', parent = 'leader', instance_id = 'cx' },
} }
_G.remuda = {
  butler = {}, _butler_bus = bus, _butler_agent_builders = {},
  _butler_agent_startup = {}, _butler_agent_support = {}, _butler_telemetry_adapters = {},
  capture = function(name) return screens[name] end,
  ls = function() return {
    { name = 'child', alive = true, instance_id = 'one' },
    { name = 'codex', alive = true, instance_id = 'cx' },
  } end,
  key = function(name, key)
    writes[#writes + 1] = name .. ':' .. key
    if on_key then on_key(name, key) end
    return true
  end,
  type_text = function(name, text) writes[#writes + 1] = name .. ':' .. text; return 'submitted' end,
  send = function(name, text) writes[#writes + 1] = name .. ':' .. text; return true end,
  log = function(level, text) logs[#logs + 1] = level .. ' ' .. text end,
  _butler_human_active = function() return human end,
  _butler_send = function(from, to, text) reports[#reports + 1] = {from, to, text}; return 'queued' end,
}
remuda.butler.guard_policy = { append = function(record)
  if fail_audit then return nil, 'disk full' end
  audits[#audits + 1] = record
  if before_write then before_write(record) end
  return true
end }
remuda.butler.guard_approval = { sha256 = function(text) return 'digest:' .. #text end }
remuda._butler_compaction_module_config = { registered_agent_kind = function() end, registered_agent_working = function() end }
remuda._butler_system = {}
dofile('packages/butler/compaction.lua')
local function noop() end
remuda._butler_chooser_config = { bus = bus, call_callback = noop, file_exists = noop,
  contributions = function() return {} end,
  numbered_option = remuda._butler_compaction.numbered_option,
  bottom_screen_lines = remuda._butler_compaction.bottom_screen_lines }
remuda._butler_contribute = noop
remuda._butler_prompt_delivery = {}
remuda.contribute = noop
dofile('packages/butler/agents_launch.lua')
remuda._butler_state = {}
dofile('packages/butler/agents/claudecode.lua')
dofile('packages/butler/agents/codex.lua')
local D = dofile('packages/butler/dialogs.lua')
D.install()
local function read(path)
  local f = assert(io.open(path, 'r')); local text = f:read('*a'); f:close(); return text
end
local function try(fn, ...) return (pcall(fn, ...)) end
local function reset() reports, audits, writes, logs = {}, {}, {}, {} end
local READY = 'done\n─\n❯ \n'

-- 1. Every recognised state is well formed, unique and documented.
local doc = read('docs/butler.md')
local ids = {}
for _, kind in ipairs({ 'claude', 'codex' }) do
  for _, entry in ipairs(remuda._butler_agent_startup[kind].dialog_states) do
    assert(type(entry.id) == 'string' and not ids[entry.id], 'unique id: ' .. tostring(entry.id))
    ids[entry.id] = true
    assert(entry.response == 'approval' or entry.response == 'report' or entry.response == 'auto', entry.id)
    assert(entry.response ~= 'auto' or type(entry.choose) == 'string', 'auto names its option: ' .. entry.id)
    assert(entry.heading or entry.match, 'matcher: ' .. entry.id)
    assert(doc:find('`' .. entry.id .. '`', 1, true), 'documented in docs/butler.md: ' .. entry.id)
  end
end
for _, id in ipairs({ 'claude_trust', 'codex_trust', 'codex_update', 'codex_model_picker',
    'codex_effort_picker', 'unknown_choice' }) do
  assert(doc:find('`' .. id .. '`', 1, true), 'documented in docs/butler.md: ' .. id)
end

-- 2. Approval-requiring and decision states stop writes and report by name.
local cases = {
  { 'child', 'Do you want to allow Claude to fetch this content?\n❯ 1. Yes\n2. No', 'claude_fetch_permission', 'approval' },
  { 'child', 'What do you want to do?\n❯ 1. Stop and wait for limit to reset\n2. Upgrade your plan', 'claude_usage_limit', 'report' },
  { 'child', 'Switch model?\n❯ 1. Yes\n2. No', 'claude_model_confirm', 'report' },
  { 'codex', read('tests/fixtures/codex-approval-command.txt'), 'codex_command_approval', 'approval' },
  { 'codex', 'Trust this folder?\n/proj\n\n› 1. Trust and continue\n  2. Back to Agent Command Center\n\nEnter to confirm',
    'codex_trust', 'approval' },
  { 'codex', read('tests/fixtures/codex-approval-edit.txt'), 'codex_edit_approval', 'approval' },
  { 'codex', 'Automatic approval review rejected too many approval requests for this turn (3 consecutive, 3 in the last 3 reviews); interrupting the turn.\n› 1. Confirm\n2. Cancel',
    'codex_auto_review_refused', 'approval' },
}
for _, case in ipairs(cases) do
  local name, screen, id, response = case[1], case[2], case[3], case[4]
  reset(); screens[name] = screen
  D.tick(); D.tick(); D.tick()
  assert(#writes == 0 and not try(remuda.key, name, 'RET') and #writes == 0, 'stopped: ' .. id)
  assert(#reports == 1 and reports[1][2] == 'leader', 'one report to leader: ' .. id)
  assert(reports[1][3]:find('state=' .. id .. ' response=' .. response, 1, true), 'named report: ' .. reports[1][3])
  assert(audits[1].event == 'dialog_blocked' and audits[1].dialog_id == id, 'audited by id: ' .. id)
  screens[name] = READY; D.tick()
  assert(try(remuda.key, name, 'RET'), 'resolved: ' .. id)
end

-- 3. Teach auto mode page 1 (transcript): Butler moves to "Not now" by its text,
-- confirms it once a capture shows it selected, and audits every key.
local teach = read('tests/fixtures/claude-teach-auto-mode-modal-transcript/modal-page1-win-styled.txt')
local selected = teach:gsub('❯ 1%. Yes', '  1. Yes'):gsub('  2%. Not now', '❯ 2. Not now')
assert(selected ~= teach)
reset(); screens.child = teach
on_key = function(_, key)
  if key == '<down>' then screens.child = selected elseif key == 'RET' then screens.child = READY end
end
D.tick()
assert(#writes == 0, 'waits for a stable second capture')
assert(not try(remuda.key, 'child', 'RET') and #writes == 0, 'Teach stops other writers; their check sends no key')
D.tick()
assert(#writes == 1 and writes[1] == 'child:<down>', 'moves onto Not now: ' .. table.concat(writes, ','))
D.tick(); D.tick()
assert(#writes == 2 and writes[2] == 'child:RET', 'confirms Not now: ' .. table.concat(writes, ','))
for _, write in ipairs(writes) do assert(not write:find('child:1', 1, true), 'never chooses Yes') end
local actions = {}
for _, record in ipairs(audits) do
  if record.event == 'dialog_action' then actions[#actions + 1] = record.action .. '/' .. record.summary end
end
assert(table.concat(actions, ',') == 'key/<down>/auto:Not now,key/RET/auto:Not now', table.concat(actions, ','))
assert(#reports == 0 and logs[#logs]:find('answered claude_teach_auto_mode in child: Not now', 1, true), 'logged, not reported')
D.tick()
assert(audits[#audits].event == 'dialog_resolved' and try(remuda.key, 'child', 'RET'), 'resolved after answer')
on_key = nil

-- Already selected: one Return. Partial option list (no Yes) still matches.
reset(); screens.child = "Teach auto mode about your environment?\n❯ 1. Not now\n  2. Don't show again\n"
D.tick(); D.tick()
assert(table.concat(writes, ',') == 'child:RET', 'selected Not now confirmed directly')
screens.child = READY; D.tick()

-- 4. Teach is left alone while someone types; audit failure and a changed
-- dialog during the audit write nothing.
reset(); screens.child = teach; human = true
D.tick(); D.tick(); D.tick()
assert(#writes == 0 and #reports == 0, 'human typing: no automatic key')
human = nil
fail_audit = true; D.tick(); fail_audit = false
assert(#writes == 0, 'audit failure: no key')
screens.child = READY; D.tick(); D.tick()
reset(); screens.child = teach
before_write = function(record) if record.event == 'dialog_action' then screens.child = selected end end
D.tick(); D.tick()
before_write = nil
assert(#writes == 0 and audits[#audits].event == 'dialog_action_result'
  and audits[#audits].summary == 'not_written', 'changed during audit: not written')
screens.child = READY; D.tick()

-- 5. A Teach answer that never takes effect is reported after the limit.
reset(); screens.child = teach
for _ = 1, D.auto_limit + 3 do D.tick() end
assert(#writes == D.auto_limit, 'bounded tries: ' .. #writes)
assert(#reports == 1 and reports[1][3]:find('state=claude_teach_auto_mode response=report', 1, true)
  and reports[1][3]:find('did not take effect', 1, true), 'auto failure reported')
screens.child = READY; D.tick()

-- Ambiguous options are never guessed.
reset(); screens.child = 'Teach auto mode about your environment?\n❯ 1. Not now\n  2. Not now\n'
D.tick(); D.tick()
assert(#writes == 0 and #reports == 1, 'ambiguous Not now reported, not answered')
screens.child = READY; D.tick()

-- 6. Teach page 2 (only after a human chose Yes) is never answered.
reset(); screens.child = read('tests/fixtures/claude-teach-auto-mode-modal-transcript/modal-page2-lua-b06.txt')
D.tick(); D.tick(); D.tick()
assert(#writes == 0 and not try(remuda.key, 'child', 'RET'), 'page 2 stops writes')
assert(#reports == 1 and reports[1][3]:find('state=claude_teach_auto_mode_setup response=report', 1, true), 'page 2 reported')
screens.child = 'quoted: Teach auto mode about your environment? Also scan shell history ... Enter to continue\n' .. READY
D.tick()
assert(try(remuda.key, 'child', 'RET'), 'page 2 text above a composer is history')

-- 7. An unrecognised current choice keeps input allowed but is reported once
-- after it has stayed unchanged; a composer below makes it history.
local now = 1000
D.clock = function() return now end
reset(); screens.codex = 'Pick a colour\n› 1. Blue\n  2. Green'
D.tick()
assert(try(remuda.key, 'codex', '1'), 'unknown choice allows input')
now = now + D.unknown_report_seconds - 1; D.tick()
assert(#reports == 0, 'not yet reported')
now = now + 1; D.tick(); D.tick()
assert(#reports == 1 and reports[1][1] == 'codex' and reports[1][3]:find('state=unknown_choice', 1, true)
  and reports[1][3]:find('Input is not stopped', 1, true), 'stable unknown reported once')
assert(audits[#audits].event == 'dialog_reported' and audits[#audits].dialog_id == 'unknown_choice', 'audited')
screens.codex = 'Pick a colour\n› 1. Blue\n  2. Red'; D.tick()
now = now + D.unknown_report_seconds; D.tick()
assert(#reports == 2, 'changed choice reported separately')
screens.codex = 'Pick a colour\n› 1. Blue\n  2. Red\n› Ask Codex to do anything'; D.tick()
now = now + D.unknown_report_seconds * 2; D.tick()
assert(#reports == 2, 'choice above a composer is history')
local box = '╭──────────╮\n│ Welcome │\n╰──────────╯'
screens.codex = box; D.tick(); now = now + D.unknown_report_seconds * 2; D.tick()
assert(#reports == 2, 'a box alone is not reported')

D.stop()
print('butler dialog states: PASS')
