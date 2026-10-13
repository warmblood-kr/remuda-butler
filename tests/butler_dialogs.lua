-- Synthetic screens only; no daemon, agent process or transcript fixtures.
local screens, reports, audits, writes = {}, {}, {}, {}
local fail_audit, fail_report, fail_capture, before_write, live_instance
local bus = { agents = {
  child = { id = 'child-id', kind = 'claude', parent = 'leader', instance_id = 'one' },
  codex = { id = 'codex-id', kind = 'codex', parent = 'leader', instance_id = 'cx' },
} }
_G.remuda = {
  butler = {}, _butler_bus = bus, _butler_agent_builders = {},
  _butler_agent_startup = {}, _butler_agent_support = {}, _butler_telemetry_adapters = {},
  capture = function(name) if fail_capture then error('capture unavailable') end; return screens[name] end,
  session = function(name) return { instance_id = bus.agents[name].instance_id, alive = true } end,
  ls = function() return {
    { name = 'child', alive = true, instance_id = live_instance or bus.agents.child.instance_id },
    { name = 'codex', alive = true, instance_id = bus.agents.codex.instance_id },
  } end,
  key = function(name, key) writes[#writes + 1] = {name, key}; return true end,
  type_text = function(name, text, settle) writes[#writes + 1] = {name, text}; return 'submitted', settle end,
  send = function(name, text) writes[#writes + 1] = {name, text}; return true end,
  expect = function() error('reporting-only dispatcher must not start an expect writer') end,
  _butler_send = function(from, to, text)
    if fail_report then return false end
    reports[#reports + 1] = {from, to, text}; return 'queued'
  end,
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
remuda._butler_model_confirm_signature = function(screen)
  if screen:find('Switch model?', 1, true) then return screen end
end
remuda._butler_state = {}
dofile('packages/butler/agents/claudecode.lua')
dofile('packages/butler/agents/codex.lua')
local D = dofile('packages/butler/dialogs.lua')
D.install()
local function attempt(fn, ...)
  local ok, result, detail = pcall(fn, ...)
  if not ok then return false, result end
  return result, detail
end
local fixture = assert(io.open('tests/fixtures/butler-dialog-historical-update.txt', 'r'))
screens.codex = fixture:read('*a'); fixture:close()
assert(remuda._butler_chooser.known_startup_modal(remuda._butler_agent_startup.codex, screens.codex),
  'real startup matcher sees historical update marker')
assert(remuda._butler_compaction.unknown_dialog_signature(screens.codex), 'real geometry recognises current choice')
assert(attempt(remuda.key, 'codex', 'RET') == false and #writes == 0, 'historical startup marker must not admit unknown Return')
-- Even recorded launch ownership does not authorise a different current dialog.
bus.pending_tasks = {codex = true}
bus.agents.codex.session_start_marker = 'cx-launch'
bus.first_task_delivery = {codex = {state = 'waiting', marker = 'cx-launch'}}
assert(attempt(remuda.key, 'codex', 'RET') == false and #writes == 0, 'pending launch cannot bless unrelated choice')
screens.codex = 'Ask Codex to do anything'; D.tick()
reports, audits = {}, {}
local unknown = 'Allow dangerous thing?\n❯ 1. Yes\n2. No\n─\n❯ \n'
screens.child, screens.codex = unknown, 'Ask Codex to do anything'
local ok, why = attempt(remuda.key, 'child', 'RET')
assert(ok == false and why:find('blocked', 1, true), 'block before first key, even with ready glyph')
assert(#writes == 0 and #reports == 0, 'no write, report waits for stable state')
D.tick()
assert(#reports == 1 and reports[1][1] == 'child' and reports[1][2] == 'leader', 'report to own leader')
assert(not pcall(remuda.key, 'child', 'RET'), 'legacy pcall-based handlers must observe write refusal')
assert(reports[1][3]:find('unknown', 1, true) and not reports[1][3]:find('dangerous', 1, true), 'metadata only')
D.tick(); attempt(remuda.type_text, 'child', 'task', 0.1)
assert(#reports == 1 and #writes == 0, 'dedupe reports and stop text writes')
assert(attempt(remuda.send, 'child', 'task') == false and #writes == 0, 'send API cannot bypass blocked write gate')
assert(audits[1].event == 'dialog_blocked' and audits[1].instance_id == 'one', 'durable block decision')
assert(audits[1].summary ~= unknown, 'never audit raw screen')

-- Ordinary output does not clear a blocker: wait for a positively ready/working screen.
screens.child = 'painting'
D.tick(); assert(attempt(remuda.key, 'child', 'RET') == false, 'ambiguous repaint stays blocked')
screens.child = 'done\n─\n❯ \n'
D.tick()
assert(attempt(remuda.key, 'child', 'RET') == true, 'clear only after ready screen')
assert(audits[#audits - 1].event == 'dialog_action', 'audit before key')
assert(audits[#audits].event == 'dialog_action_result', 'record returned outcome')

-- Changed dialog and reused session alias each get their own stable report.
screens.child = unknown; D.tick(); D.tick()
assert(#reports == 2, 'new occurrence reported after resolution')
bus.agents.child.instance_id = 'two'; D.tick(); D.tick()
assert(#reports == 3, 'same alias/new instance reported separately')
screens.child = unknown:gsub('Yes', 'Different'); D.tick(); D.tick()
assert(#reports == 4, 'changed signature reported once')

fail_report = true
screens.child = unknown:gsub('Yes', 'Third'); D.tick(); D.tick()
fail_report = false; D.tick(); D.tick()
assert(#reports == 5, 'failed report retried, successful report deduped')
fail_audit = true
screens.child = 'done\n─\n❯ \n'; D.tick()
local count = #writes
assert(attempt(remuda.key, 'child', 'RET') == false and #writes == count, 'audit failure refuses key')
assert(attempt(remuda.type_text, 'child', 'task', 0.1) == false and #writes == count, 'audit failure refuses text')
fail_audit = false
fail_capture = true
assert(attempt(remuda.key, 'child', 'RET') == false and #writes == count, 'capture failure refuses key')
fail_capture = false

-- Existing launch policy retains ownership of known startup dialogs.
bus.pending_tasks.child = true
bus.agents.child.session_start_marker = 'child-launch'
bus.first_task_delivery.child = {state = 'waiting', marker = 'child-launch'}
for _, screen in ipairs({
  'Accessing workspace:\n/proj\nQuick safety check:\n\n❯ Yes, I trust this folder\n  No, exit\n\nEnter to confirm',
  "Teach auto mode\n❯ 1. Not now\n2. Don't show again",
}) do
  screens.child = screen
  assert(attempt(remuda.key, 'child', 'RET') == true, 'startup handler retains authority')
end
screens.codex = 'Update available\n› 1. Update now\n2. Skip'
assert(attempt(remuda.key, 'codex', '2') == true, 'Codex update flow unchanged')
screens.codex = 'Trust this folder?\n/proj\n\n› 1. Trust and continue\n  2. Back to Agent Command Center\n\nEnter to confirm'
assert(attempt(remuda.key, 'codex', 'RET') == true, 'owned exact trust options preserve conditional trust handler')
bus.pending_tasks.codex = nil
remuda._butler_state.compaction_fleet_active = bus.agents.codex.id
fixture = assert(io.open('tests/fixtures/butler-dialog-historical-picker.txt', 'r'))
screens.codex = fixture:read('*a'); fixture:close()
assert(remuda._butler_compaction.unknown_dialog_signature(screens.codex), 'real geometry sees unrelated current choice')
count = #writes
assert(not pcall(remuda.key, 'codex', 'RET') and #writes == count,
  'active compaction and historical picker title must not bless current unknown Return')
remuda._butler_state.compaction_members = {[bus.agents.codex.id] = {dialog_operation = {
  agent = bus.agents.codex, model = 'gpt-6-luna', effort = 'high', phase = 'model',
}}}
assert(not pcall(remuda.key, 'codex', 'RET') and #writes == count,
  'recorded target cannot bless a different current choice')
local operation = remuda._butler_state.compaction_members[bus.agents.codex.id].dialog_operation
screens.codex = 'Select Model and Effort\n\n› 1. GPT-6-Luna\n  2. GPT-5.6-Sol (current)\n\nenter select · esc back'
assert(attempt(remuda.key, 'codex', '1') == true, 'genuine current model picker with expected target is owned')
operation.phase = 'effort'
screens.codex = 'Select Reasoning Level for GPT-6-Luna\n\n  1. Medium (default)\n› 2. High\n\nenter default · s session · esc back'
assert(attempt(remuda.key, 'codex', 's') == true, 'genuine current target effort picker is owned')
screens.codex = 'Select Reasoning Level for GPT-5.6-Sol\n\n  1. Medium\n› 2. High\n\nenter default · s session · esc back'
assert(not pcall(remuda.key, 'codex', 's'), 'a different target model never inherits picker ownership')
operation.phase = 'model'
screens.codex = 'Select Model and Effort\n\n› 1. GPT-6-Nova\n  2. GPT-5.6-Sol (current)\n\nenter select · esc back'
assert(not pcall(remuda.key, 'codex', '1'), 'missing expected model never admits selection')
operation.phase = 'escape'
assert(attempt(remuda.key, 'codex', 'ESC') == true, 'existing cleanup can close a genuine picker with missing target')
screens.codex = 'Select Model and Effort\n\nChoose a display color\n› 1. Blue\n  2. Green\nEnter to confirm'
assert(not pcall(remuda.key, 'codex', 'ESC'), 'cleanup phase cannot bless a different current dialog')
remuda._butler_state.compaction_fleet_active = nil
screens.codex = 'Ask Codex to do anything'; D.tick()
screens.child = 'Switch model?\n❯ 1. Yes\n2. No'
assert(attempt(remuda.key, 'child', 'RET') == false, 'unowned model dialog is unknown blocker')
remuda._butler_state.compaction_fleet_active = bus.agents.child.id
assert(attempt(remuda.key, 'child', 'RET') == true, 'owned model switch retains compaction handler')
remuda._butler_state.compaction_fleet_active = nil
screens.codex = 'Odd prompt\n› 1. Yes\n2. No'
D.tick(); D.tick()
assert(reports[#reports][1] == 'codex' and attempt(remuda.key, 'codex', 'RET') == false, 'Codex unknown stops')

-- Reload must not stack wrappers/audits; stop restores core API ownership.
screens.child = 'done\n─\n❯ \n'
D = dofile('packages/butler/dialogs.lua'); D.install(); D.tick()
local n = #audits
local result, settle = attempt(remuda.type_text, 'child', 'task', 0.1)
assert(result == 'submitted' and settle == 0.1 and #audits == n + 2, 'reload single wrapper, returns preserved')
n = #audits
assert(attempt(remuda.key, 'unmanaged', 'RET') == true and #audits == n, 'unmanaged sessions untouched')
before_write = function(record)
  if record.event == 'dialog_action' then screens.child = unknown end
end
count = #writes
assert(attempt(remuda.key, 'child', 'RET') == false and #writes == count, 'screen changed while audit yielded')
before_write = nil
screens.child = 'done\n─\n❯ \n'; D.tick()
before_write = function(record)
  if record.event == 'dialog_action' then live_instance = 'replacement' end
end
assert(attempt(remuda.key, 'child', 'RET') == false and #writes == count, 'instance changed while audit yielded')
before_write, live_instance = nil, nil
screens.child = '╭────────────────╮\n│ Unknown gate │\n╰────────────────╯'
D.tick(); D.tick()
assert(attempt(remuda.key, 'child', 'RET') == false, 'boxed unknown stops writes')
-- Existing composer policy also recognises custom/core-specific ready layouts.
screens.child = 'MODEL:restored CTX:200000'
remuda._butler_prompt_is_empty = function(_, screen)
  return screen == 'MODEL:restored CTX:200000' and 'EMPTY' or 'UNPARSEABLE'
end
D.tick()
assert(attempt(remuda.key, 'child', 'RET') == true, 'existing positive composer probe releases resolved blocker')
-- A descriptor failure is a blocker rather than a schedule exception.
remuda._butler_agent_startup.claude.blocking[1].match = function() error('parser broke') end
screens.child = 'done\n─\n❯ \n'; D.tick(); D.tick()
assert(attempt(remuda.key, 'child', 'RET') == false, 'parser failure refuses input')
D.stop()
n = #audits
assert(attempt(remuda.key, 'child', 'RET') == true and #audits == n, 'stop restores originals')
print('butler dialogs: PASS')
