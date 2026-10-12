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
-- Helpers stand in for existing startup/compaction parsers, not new recognisers.
remuda._butler_chooser = { known_startup_modal = function(_, screen)
  return screen:find('Quick safety check:', 1, true) or screen:find('Teach auto mode', 1, true)
    or screen:find('Update available', 1, true) or screen:find('Trust this folder?', 1, true)
end }
remuda._butler_compaction_module_config = { registered_agent_kind = function() end, registered_agent_working = function() end }
remuda._butler_system = {}
dofile('packages/butler/compaction.lua')
remuda._butler_model_confirm_signature = function(screen)
  if screen:find('Switch model?', 1, true) then return screen end
end
remuda._butler_state = {}
dofile('packages/butler/agents/claudecode.lua')
dofile('packages/butler/agents/codex.lua')
local D = dofile('packages/butler/dialogs.lua')
D.install()
local unknown = 'Allow dangerous thing?\n❯ 1. Yes\n2. No\n─\n❯ \n'
screens.child, screens.codex = unknown, 'Ask Codex to do anything'
local ok, why = remuda.key('child', 'RET')
assert(ok == false and why:find('blocked', 1, true), 'block before first key, even with ready glyph')
assert(#writes == 0 and #reports == 0, 'no write, report waits for stable state')
D.tick()
assert(#reports == 1 and reports[1][1] == 'child' and reports[1][2] == 'leader', 'report to own leader')
assert(reports[1][3]:find('unknown', 1, true) and not reports[1][3]:find('dangerous', 1, true), 'metadata only')
D.tick(); remuda.type_text('child', 'task', 0.1)
assert(#reports == 1 and #writes == 0, 'dedupe reports and stop text writes')
assert(remuda.send('child', 'task') == false and #writes == 0, 'send API cannot bypass blocked write gate')
assert(audits[1].event == 'dialog_blocked' and audits[1].instance_id == 'one', 'durable block decision')
assert(audits[1].summary ~= unknown, 'never audit raw screen')

-- Ordinary output does not clear a blocker: wait for a positively ready/working screen.
screens.child = 'painting'
D.tick(); assert(remuda.key('child', 'RET') == false, 'ambiguous repaint stays blocked')
screens.child = 'done\n─\n❯ \n'
D.tick()
assert(remuda.key('child', 'RET') == true, 'clear only after ready screen')
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
assert(remuda.key('child', 'RET') == false and #writes == count, 'audit failure refuses key')
assert(remuda.type_text('child', 'task', 0.1) == false and #writes == count, 'audit failure refuses text')
fail_audit = false
fail_capture = true
assert(remuda.key('child', 'RET') == false and #writes == count, 'capture failure refuses key')
fail_capture = false

-- Existing launch policy retains ownership of known startup dialogs.
for _, screen in ipairs({
  'Quick safety check:\n❯ 1. Yes\n2. No',
  'Teach auto mode\n❯ 1. Not now\n2. Other',
}) do
  screens.child = screen
  assert(remuda.key('child', 'RET') == true, 'startup handler retains authority')
end
screens.codex = 'Update available\n› 1. Update now\n2. Skip'
assert(remuda.key('codex', '2') == true, 'Codex update flow unchanged')
screens.child = 'Switch model?\n❯ 1. Yes\n2. No'
assert(remuda.key('child', 'RET') == false, 'unowned model dialog is unknown blocker')
remuda._butler_state.compaction_fleet_active = bus.agents.child.id
assert(remuda.key('child', 'RET') == true, 'owned model switch retains compaction handler')
remuda._butler_state.compaction_fleet_active = nil
screens.codex = 'Odd prompt\n› 1. Yes\n2. No'
D.tick(); D.tick()
assert(reports[#reports][1] == 'codex' and remuda.key('codex', 'RET') == false, 'Codex unknown stops')

-- Reload must not stack wrappers/audits; stop restores core API ownership.
screens.child = 'done\n─\n❯ \n'
D = dofile('packages/butler/dialogs.lua'); D.install(); D.tick()
local n = #audits
local result, settle = remuda.type_text('child', 'task', 0.1)
assert(result == 'submitted' and settle == 0.1 and #audits == n + 2, 'reload single wrapper, returns preserved')
n = #audits
assert(remuda.key('unmanaged', 'RET') == true and #audits == n, 'unmanaged sessions untouched')
before_write = function(record)
  if record.event == 'dialog_action' then screens.child = unknown end
end
count = #writes
assert(remuda.key('child', 'RET') == false and #writes == count, 'screen changed while audit yielded')
before_write = nil
screens.child = 'done\n─\n❯ \n'; D.tick()
before_write = function(record)
  if record.event == 'dialog_action' then live_instance = 'replacement' end
end
assert(remuda.key('child', 'RET') == false and #writes == count, 'instance changed while audit yielded')
before_write, live_instance = nil, nil
screens.child = '╭────────────────╮\n│ Unknown gate │\n╰────────────────╯'
D.tick(); D.tick()
assert(remuda.key('child', 'RET') == false, 'boxed unknown stops writes')
-- A descriptor failure is a blocker rather than a schedule exception.
remuda._butler_agent_startup.claude.blocking[1].match = function() error('parser broke') end
screens.child = 'done\n─\n❯ \n'; D.tick(); D.tick()
assert(remuda.key('child', 'RET') == false, 'parser failure refuses input')
D.stop()
n = #audits
assert(remuda.key('child', 'RET') == true and #audits == n, 'stop restores originals')
print('butler dialogs: PASS')
