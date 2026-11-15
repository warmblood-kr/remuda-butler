-- Report-only owner notice for Codex approval dialogs. Synthetic screens and a
-- fake approval.notify only; no daemon, Matrix, agent process or transcript.
local screens, reports, audits, writes = {}, {}, {}, {}
local notices, attempts, notify_mode, pending_done = {}, {}, 'ok'
local bus = { agents = {
  child = { id = 'child-id', kind = 'claude', parent = 'leader', instance_id = 'one' },
  codex = { id = 'codex-id', kind = 'codex', parent = 'leader', instance_id = 'cx' },
} }
local tmpdir = os.tmpname()
os.remove(tmpdir)
assert(os.execute('mkdir -p ' .. tmpdir) == 0)
_G.remuda = {
  butler = {}, _butler_bus = bus, _butler_agent_builders = {},
  _butler_agent_startup = {}, _butler_agent_support = {}, _butler_telemetry_adapters = {},
  _butler_guard_dir = tmpdir,
  capture = function(name) return screens[name] end,
  ls = function() return {
    { name = 'child', alive = true, instance_id = 'one' },
    { name = 'codex', alive = true, instance_id = 'cx' },
  } end,
  key = function(name, key) writes[#writes + 1] = { name, key }; return true end,
  type_text = function(name, text) writes[#writes + 1] = { name, text }; return 'submitted' end,
  send = function(name, text) writes[#writes + 1] = { name, text }; return true end,
  expect = function() error('reporting-only path must not start an expect writer') end,
  fs = { write_atomic = function(path, text)
    local handle = assert(io.open(path, 'w')); handle:write(text); handle:close()
    return true
  end },
  _butler_send = function(from, to, text) reports[#reports + 1] = { from, to, text }; return 'queued' end,
}
remuda.butler.guard_policy = { append = function(record)
  audits[#audits + 1] = record
  return true
end, dir = function() return tmpdir end }
remuda.butler.guard_approval = { sha256 = function(text) return 'digest:' .. #text end }
-- The fake notice transport: 'ok' completes with an event id, 'offline'
-- refuses like a stopped relay, 'error' completes with an error, 'pending'
-- starts a post that never reports back (a daemon died mid-post).
remuda.butler.approval = { notify = function(text, done)
  attempts[#attempts + 1] = text
  local handle = { cancel = function() end }
  if notify_mode == 'offline' then return nil, 'Matrix relay is not running' end
  if notify_mode == 'pending' then pending_done = done; return handle end
  if notify_mode == 'error' then
    if done then done({ error = 'Matrix approval post failed' }) end
    return handle
  end
  notices[#notices + 1] = text
  if done then done({ event_id = 'evt' .. tostring(#notices), room_id = '!room' }) end
  return handle
end }
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
local N = dofile('packages/butler/dialog_owner_notice.lua')
local t = 1000
N.clock = function() return t end
local function read(path)
  local handle = assert(io.open(path, 'r')); local text = handle:read('*a'); handle:close(); return text
end
local function ticks(count)
  for _ = 1, count do t = t + 1; D.tick() end
end
local function reset()
  reports, audits, writes, attempts, notices = {}, {}, {}, {}, {}
  notify_mode, pending_done = 'ok', nil
end
local READY = 'done\n─\n❯ \n'
local COMMAND = read('tests/fixtures/codex-approval-command.txt')
local EDIT = read('tests/fixtures/codex-approval-edit.txt')
local AUTO = 'Automatic approval review rejected too many approval requests for this turn '
  .. '(3 consecutive, 3 in the last 3 reviews); interrupting the turn.\n› 1. Confirm\n2. Cancel'
local CLAUDE = 'Do you want to proceed?\n❯ 1. Yes\n2. No\n'

-- 1. A recognised Codex approval reaches the owner room once, as metadata only,
-- while the existing leader report is unchanged and no input is written.
reset(); screens.codex = COMMAND
ticks(2)
assert(#attempts == 0, 'waits for the stable second capture and debounce')
ticks(6)
assert(#reports == 1 and reports[1][2] == 'leader', 'leader report preserved')
assert(reports[1][3]:find('state=codex_command_approval', 1, true), 'leader sees the state')
assert(#notices == 1, 'exactly one owner notice: ' .. #notices)
local notice = notices[1]
assert(notice:find('session codex', 1, true) and notice:find('codex_command_approval', 1, true),
  'names the exact session and state')
assert(notice:find('Report only', 1, true) and notice:find('no option', 1, true),
  'says it is report-only')
assert(not notice:find('cargo test', 1, true) and not notice:find('Reason:', 1, true)
  and not notice:find('Yes, proceed', 1, true), 'no screen body, command or option text')
assert(#writes == 0, 'no input was sent')
assert(#attempts == 1, 'a stable dialog posts once, not per tick')
assert(not pcall(remuda.key, 'codex', 'RET') and #attempts == 1 and #writes == 0,
  'a writer gate check posts nothing and sends no key')

-- 2. Claude approval keeps its leader-only behavior.
screens.codex = READY; ticks(1)
reset(); screens.child = CLAUDE
ticks(8)
assert(#reports == 1 and reports[1][1] == 'child', 'Claude still reports to its leader')
assert(#notices == 0 and #attempts == 0, 'Claude never posts an owner notice')
screens.child = READY; ticks(1)

-- 3. The auto-review refusal is a classifier refusal, not a pending approval:
-- the real classifier marks it `approval` (so it still blocks), and the notice
-- says no approval is pending. It is noticed even if a future row says `report`.
reset(); screens.codex = AUTO; t = t + 100
ticks(8)
local live = bus.dialog_states.codex
assert(live and live.id == 'codex_auto_review_refused' and live.entry.response == 'approval',
  'the real classifier marks the refusal approval-classified')
assert(#notices == 1 and notices[1]:find('codex_auto_review_refused', 1, true), 'classifier refusal noticed')
assert(notices[1]:find('classifier refusal', 1, true) and notices[1]:find('no approval is pending', 1, true),
  'distinguishes the refusal from a waiting approval')
assert(#writes == 0, 'no input after a refusal')
screens.codex = READY; ticks(1)
reset()
local refusal = { id = 'codex_auto_review_refused', instance = 'cx-refusal',
  entry = { response = 'report' }, signature = 'refusal-x' }
assert(N.consider('codex', { kind = 'codex' }, refusal) == false, 'refusal waits for its debounce')
t = t + 4
assert(N.consider('codex', { kind = 'codex' }, refusal) == true and #notices == 1,
  'a report-classified refusal is still noticed')
assert(notices[1]:find('classifier refusal', 1, true), 'and uses the refusal wording')

-- 4. A changed choice block is held behind the session window, then posted once.
reset(); screens.codex = EDIT; t = t + 100
ticks(8)
assert(#notices == 1, 'first edit approval noticed')
local before = #attempts
screens.codex = COMMAND:gsub('Yes, proceed', 'Yes, run it now'); ticks(1)
assert(#attempts == before, 'changed screen is kept behind the session window')
assert(#notices == 1, 'no second notice inside the window')
t = t + 35
ticks(8)
assert(#notices == 2, 'the changed dialog is noticed after the window: ' .. #notices)
screens.codex = READY; ticks(1)

-- 5. An offline relay posts nothing and retries; delivery is not repeated.
reset(); notify_mode = 'offline'; screens.codex = COMMAND; t = t + 100
ticks(8)
assert(#notices == 0 and #attempts >= 1, 'offline refusal attempts a retry later')
notify_mode = 'ok'
ticks(2)
assert(#notices == 0, 'retry waits for the backoff')
t = t + 35
ticks(8)
assert(#notices == 1, 'retried once the relay is back')
ticks(10)
assert(#notices == 1, 'delivered dialog is not repeated')
screens.codex = READY; ticks(1)

-- 6. A failed post retries; only an event id records delivery. The dialog stays
-- pending for the restart checks below.
reset(); notify_mode = 'error'; screens.codex = EDIT; t = t + 100
ticks(8)
assert(#notices == 0 and #attempts == 1, 'post error is not delivery')
notify_mode = 'ok'; t = t + 35
ticks(8)
assert(#notices == 1, 'failed post is retried')

-- 7. A restart does not repeat a pending notice; resolving clears the receipt.
bus.dialog_owner_notice_state = nil
N = dofile('packages/butler/dialog_owner_notice.lua')
N.clock = function() return t end
reset(); screens.codex = EDIT; t = t + 100
ticks(12)
assert(#notices == 0 and #reports == 0, 'restart does not repeat a delivered notice')
screens.codex = READY; ticks(1)
reset(); screens.codex = EDIT; t = t + 1
ticks(8)
assert(#notices == 1, 'a resolved dialog clears the persisted receipt')
screens.codex = READY; ticks(1)

-- 8. A post with no callback is repeated once after restart, then stops.
bus.dialog_owner_notice_state = nil
N = dofile('packages/butler/dialog_owner_notice.lua')
N.clock = function() return t end
reset(); notify_mode = 'pending'; screens.codex = AUTO; t = t + 100
ticks(8)
assert(#notices == 0 and #attempts == 1, 'uncertain post is not a receipt')
assert(pending_done ~= nil, 'a post was in flight')
bus.dialog_owner_notice_state = nil
N = dofile('packages/butler/dialog_owner_notice.lua')
N.clock = function() return t end
notify_mode = 'ok'
ticks(8)
assert(#notices == 1, 'uncertain post is repeated once after restart')
ticks(10)
assert(#notices == 1, 'and only once')
screens.codex = READY; ticks(1)

-- 9. A replaced session instance is a new request: the pending receipt for the
-- old instance does not suppress it.
reset(); screens.codex = COMMAND; t = t + 100
ticks(8)
assert(#notices == 1, 'pending approval noticed')
bus.agents.codex.instance_id = 'cx2'
local listed = remuda.ls
remuda.ls = function() return {
  { name = 'child', alive = true, instance_id = 'one' },
  { name = 'codex', alive = true, instance_id = 'cx2' },
} end
ticks(8)
assert(#notices == 2 and notices[2]:find('session codex', 1, true),
  'a replaced instance notifies despite the old pending receipt')
screens.codex = READY; ticks(1)
remuda.ls = listed
bus.agents.codex.instance_id = 'cx'

-- 10. An unfenced instance, a non-approval state and a non-Codex agent are refused.
assert(N.consider('codex', { kind = 'codex' },
  { id = 'codex_command_approval', instance = {}, entry = { response = 'approval' }, signature = 'x' }) == false,
  'no notice without a string instance')
assert(N.consider('codex', { kind = 'codex' },
  { id = 'codex_command_approval', instance = 'cx', entry = { response = 'report' }, signature = 'x' }) == false,
  'no notice for a report-only state')
assert(N.consider('child', { kind = 'claude' },
  { id = 'claude_permission_prompt', instance = 'one', entry = { response = 'approval' }, signature = 'x' }) == false,
  'no notice for Claude')

assert(#writes == 0, 'the whole path sent no input')
assert(audits[#audits] and audits[#audits].event == 'dialog_resolved', 'dialog lifecycle audit intact')
os.execute('rm -rf ' .. tmpdir)
print('PASS butler_dialog_owner_notice')
