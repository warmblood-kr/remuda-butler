-- Report-only owner notice for Codex approvals. Synthetic screens plus the real
-- approval.notify wrapper behind a fake Matrix post; no daemon or network.
local screens, reports, audits, writes = {}, {}, {}, {}
local notices, attempts, notify_mode, pending_done = {}, {}, 'ok'
local bus = { agents = {
  child = { id = 'child-id', kind = 'claude', parent = 'leader', instance_id = 'one' },
  codex = { id = 'codex-id', kind = 'codex', parent = 'leader', instance_id = 'cx' },
} }
local tmpdir = os.tmpname()
os.remove(tmpdir)
local made = os.execute('mkdir -p ' .. tmpdir) -- true on LuaJIT 2.1.1761+, else 0
assert(made == 0 or made == true, 'temporary directory')
_G.remuda = {
  butler = {}, _butler_bus = bus, _butler_agent_builders = {},
  _butler_agent_startup = {}, _butler_agent_support = {}, _butler_telemetry_adapters = {},
  _butler_guard_dir = tmpdir,
  capture = function(name) return screens[name] end,
  ls = function() return {
    { name = 'child', alive = true, instance_id = 'one' },
    { name = 'codex', alive = true, instance_id = bus.agents.codex.instance_id },
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
remuda.butler.matrix = { sanitize_directory_text = function(value) return value end }
remuda.json = { null = {}, object = function(value) return value end }
remuda.cli = { parse = function() return { kind = 'help', text = '' } end }
-- The fake Matrix post behind the real approval.notify: 'ok' completes with an
-- event id, 'offline' returns nothing like a stopped relay, 'error' completes
-- with an error, 'pending' starts a post that never reports back.
local approval = dofile('packages/butler/approval.lua')
approval.attach({ approvals = {} }, function() return true end, function(text, _, done)
  attempts[#attempts + 1] = text
  local handle = { cancel = function() end }
  if notify_mode == 'offline' then return nil end
  if notify_mode == 'pending' then pending_done = done; return handle end
  if notify_mode == 'error' then
    if done then done({ error = 'Matrix approval post failed' }) end
    return handle
  end
  notices[#notices + 1] = text
  if done then done({ event_id = 'evt' .. tostring(#notices), room_id = '!room' }) end
  return handle
end, function() return '!room' end, '!room')
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
local function state(id, signature, instance)
  return { id = id, signature = signature or id, instance = instance or 'cx',
    entry = { response = 'approval' } }
end
local function treat(notice_state, agent)
  return N.consider('codex', agent or { kind = 'codex' }, notice_state)
end

-- 1. The assembled path: one stable Codex approval posts once, metadata only,
-- while the leader report is unchanged and no input is written. Resolving it
-- clears the receipt, so the same approval afterwards notifies again.
reset(); screens.codex = COMMAND
ticks(2)
assert(#attempts == 0, 'waits for stability and debounce')
ticks(6)
assert(#reports == 1 and reports[1][2] == 'leader', 'leader report preserved')
assert(reports[1][3]:find('state=codex_command_approval', 1, true), 'leader sees the state')
assert(#notices == 1, 'exactly one owner notice')
local notice = notices[1]
assert(notice:find('session codex', 1, true) and notice:find('codex_command_approval', 1, true)
  and notice:find('no option', 1, true) and notice:find('no node or request detail', 1, true),
  'names the session and state and states the limits')
assert(not notice:find('cargo test', 1, true) and not notice:find('Reason:', 1, true)
  and not notice:find('Yes, proceed', 1, true), 'no screen body, command or option text')
assert(#writes == 0 and #attempts == 1, 'no input, one post')
assert(not pcall(remuda.key, 'codex', 'RET') and #attempts == 1 and #writes == 0,
  'a writer gate check posts nothing and sends no key')
ticks(5)
assert(#attempts == 1, 'an unchanged dialog posts once, not per tick')
screens.codex = READY; ticks(1)
reset(); t = t + 100; screens.codex = COMMAND
ticks(8)
assert(#notices == 1, 'the resolved receipt no longer suppresses an identical approval')
screens.codex = READY; ticks(1)

-- 2. Claude approval keeps its leader-only behavior.
reset(); screens.child = CLAUDE
ticks(8)
assert(#reports == 1 and reports[1][1] == 'child' and #notices == 0 and #attempts == 0,
  'Claude reports to its leader and never posts an owner notice')
screens.child = READY; ticks(1)

-- 3. The auto-review refusal is a classifier refusal, not a pending approval:
-- the real classifier marks it `approval` so it still blocks, and the notice
-- says no approval is pending. It is noticed even if a row says `report`.
reset(); screens.codex = AUTO; t = t + 100
ticks(8)
assert(bus.dialog_states.codex and bus.dialog_states.codex.id == 'codex_auto_review_refused'
  and bus.dialog_states.codex.entry.response == 'approval', 'the refusal classifier is approval')
assert(#notices == 1 and notices[1]:find('classifier refusal', 1, true)
  and notices[1]:find('no approval is pending', 1, true), 'the refusal reads differently')
screens.codex = READY; ticks(1)
reset(); t = t + 100
local refusal = state('codex_auto_review_refused', 'refusal', 'd0')
refusal.entry.response = 'report'
assert(treat(refusal) == false and #attempts == 0, 'refusal waits for its debounce')
t = t + 4
assert(treat(refusal) == true and #notices == 1 and notices[1]:find('classifier refusal', 1, true),
  'a report-classified refusal is still noticed with refusal wording')

-- 4. A changed choice block is held behind the session window, then posted.
reset(); t = t + 100
local first = state('codex_edit_approval', 'sig-a', 'd2')
treat(first); t = t + 3
assert(treat(first) == true, 'first edit approval noticed')
local changed = state('codex_edit_approval', 'sig-b', 'd2')
treat(changed); t = t + 3
assert(treat(changed) == false and #notices == 1, 'changed block held inside the window')
t = t + 31
assert(treat(changed) == true and #notices == 2, 'noticed after the window')

-- 5. An offline relay and a failed post retry after the backoff.
reset(); notify_mode = 'offline'; t = t + 100
local offline = state('codex_command_approval', 'offline', 'd3')
treat(offline); t = t + 3
assert(treat(offline) == false and #attempts == 1 and #notices == 0, 'offline is not delivery')
notify_mode = 'ok'; t = t + 2
assert(treat(offline) == false and #notices == 0, 'retry waits for the backoff')
t = t + 31
assert(treat(offline) == true and #notices == 1, 'the retry delivers')

-- 6. A restart repeats neither a delivered receipt nor an uncertain post; the
-- uncertainty is retried once because a receipt is never guessed.
reset(); t = t + 100
local restart = state('codex_edit_approval', 'restart', 'd4')
treat(restart); t = t + 3
assert(treat(restart) == true and #notices == 1)
bus.dialog_owner_notice_state = nil
N = dofile('packages/butler/dialog_owner_notice.lua'); N.clock = function() return t end
reset(); t = t + 100
assert(treat(restart) == false and #notices == 0, 'a restart does not repeat a delivered notice')
reset(); notify_mode = 'pending'; t = t + 100
local uncertain = state('codex_command_approval', 'uncertain', 'd5')
treat(uncertain); t = t + 3
assert(treat(uncertain) == true and #attempts == 1 and #notices == 0, 'no callback is not a receipt')
local stale = pending_done
bus.dialog_owner_notice_state = nil
N = dofile('packages/butler/dialog_owner_notice.lua'); N.clock = function() return t end
reset(); notify_mode = 'ok'; t = t + 100
treat(uncertain); t = t + 3
assert(treat(uncertain) == true and #notices == 1, 'the uncertain post repeats once')
t = t + 10
treat(uncertain)
assert(#notices == 1, 'and only once')

-- 7. A replaced session instance notifies even while the old receipt is pending.
reset(); t = t + 100
local old = state('codex_command_approval', 'inst', 'e1')
treat(old); t = t + 3
assert(treat(old) == true and #notices == 1)
local replacement = state('codex_command_approval', 'inst', 'e2')
treat(replacement); t = t + 3
assert(treat(replacement) == true and #notices == 2, 'the new instance is a new request')

-- 8. Resolution lands before the post callback and a same-signature request
-- starts: its late success must not suppress the new request.
reset(); notify_mode = 'pending'; t = t + 100
local raced = state('codex_command_approval', 'race', 'f1')
treat(raced); t = t + 3
assert(treat(raced) == true and pending_done ~= nil, 'the first post is in flight')
local late = pending_done
N.resolved('codex', 'f1', 'codex_command_approval', 'race')
reset(); notify_mode = 'ok'; t = t + 5
local again = state('codex_command_approval', 'race', 'f1')
treat(again)
late({ event_id = 'stale-event' })
t = t + 3
assert(treat(again) == true and #notices == 1, 'the stale success does not suppress the new request')
assert(#attempts == 1, 'and it did not clear the new attempt deadline')

-- 9. A lost callback retried before the original success leaves a late success:
-- the retry is a second message, one duplicate, one receipt.
reset(); notify_mode = 'pending'; t = t + 100
local doubled = state('codex_edit_approval', 'late', 'f2')
treat(doubled); t = t + 3
assert(treat(doubled) == true)
local older = pending_done
notify_mode = 'ok'; t = t + 31
assert(treat(doubled) == true and #notices == 1 and #attempts == 2,
  'the retry posts a second message')
older({ event_id = 'late-event' })
assert(#notices == 1, 'the late success writes no second receipt')
N.resolved('codex', 'f2', 'codex_edit_approval', 'late')

-- 10. Unfenced and non-approval states are refused.
assert(treat(state('codex_command_approval', 'x', {})) == false, 'no notice without a string instance')
local reported = state('codex_command_approval', 'x', 'g1'); reported.entry.response = 'report'
assert(treat(reported) == false, 'no notice for a report-only state')
assert(N.consider('codex', { kind = 'claude' }, state('codex_command_approval', 'x', 'g2')) == false,
  'no notice for Claude')

assert(#writes == 0, 'the whole path sent no input')
os.execute('rm -rf ' .. tmpdir)
print('PASS butler_dialog_owner_notice')
