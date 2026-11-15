-- End-to-end owner approval for the real Codex command prompt: the periodic
-- dialog tick recognises the fixture, creates one Matrix request, a live owner
-- answer sends one key, and the resolved dialog leaves the report-only path
-- idle. Synthetic screens, relay and key writer; no daemon or network.
local screens, posts, keys, audits = {}, {}, {}, {}
local bus = { agents = {
  codex = { id = 'codex-id', kind = 'codex', parent = 'leader', instance_id = 'cx',
    session_start_marker = 'launch-1' },
} }
local store = { approvals = {} }
_G.remuda = {
  butler = {}, _butler_bus = bus, _butler_agent_builders = {},
  _butler_agent_startup = {}, _butler_agent_support = {}, _butler_telemetry_adapters = {},
  capture = function(name) return screens[name] end,
  ls = function() return {{ name = 'codex', alive = true, instance_id = 'cx', attached = false }} end,
  random_bytes = function(n) return string.rep(string.char(#posts + 1), n) end,
  json = { null = {}, object = function(value) return value end },
  cli = { parse = function() return { kind = 'help', text = '' } end },
  _butler_dialog_originals = { key = function(_, key)
    keys[#keys + 1] = key
    if key == 'RET' or key == 'ESC' then screens.codex = 'done' end
    return true
  end },
  send = function() return true end,
  type_text = function() return 'submitted' end,
  _butler_send = function() return 'queued' end,
}
remuda.butler.guard_approval = { sha256 = function(text) return 'digest:' .. #text end }
remuda.butler.guard_policy = { append = function(record)
  audits[#audits + 1] = record
  return true
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
local approval = dofile('packages/butler/approval.lua')
approval.attach(store, function() return true end, function(text, _, cb)
  posts[#posts + 1] = text; cb({ event_id = '$post' .. #posts }); return true
end, function() return '!owner' end, '!owner', true)
local D = dofile('packages/butler/dialogs.lua')
D.install()
dofile('packages/butler/dialog_approval.lua')
dofile('packages/butler/dialog_owner_notice.lua')
local fixture = assert(io.open('tests/fixtures/codex-approval-command.txt'))
local COMMAND = fixture:read('*a'); fixture:close()
local function open()
  for _, rec in pairs(store.approvals) do if rec.status == 'open' then return rec end end
end
local function tick_until(fn, limit)
  for _ = 1, limit or 6 do
    D.tick()
    local value = fn()
    if value then return value end
  end
end

-- 1. The tick recognises the prompt, posts one actionable request showing the
-- exact command, and does not also post the report-only notice.
screens.codex = COMMAND
local rec = tick_until(open)
assert(rec, 'the dialog tick creates the owner request')
assert(#posts == 1 and posts[1]:find('touch /private/tmp/codex-esc-probe/outside.txt', 1, true),
  'one request with the exact command')
assert(not posts[1]:find('Press enter', 1, true), 'no screen body')

-- 2. A live owner approval sends one Return and verifies the prompt is gone.
assert(approval.answer(rec.id, 'approve', '@owner:test', '$owner-approve'))
assert(rec.status == 'applied' and #keys == 1 and keys[1] == 'RET', 'one Return applied')
assert(audits[#audits].event == 'dialog_action_result' and audits[#audits].summary == 'verified',
  'verified result audited')

-- 3. The resolved dialog stops the request path; a later identical prompt is a
-- new request and a live owner rejection sends one Escape.
D.tick()
assert(bus.dialog_states.codex.blocked == nil, 'the dialog resolves after the approval')
screens.codex = COMMAND
rec = tick_until(open)
assert(rec and #posts == 2, 'a new identical prompt asks again')
assert(approval.answer(rec.id, 'deny', '@owner:test', '$owner-deny'))
assert(rec.status == 'denied' and #keys == 2 and keys[2] == 'ESC', 'one Escape rejected')
assert(audits[#audits].event == 'dialog_approval_closed', 'rejection closed and audited')
D.tick()
assert(bus.dialog_states.codex.blocked == nil, 'the prompt resolves after the rejection')
assert(#posts == 2, 'no report-only notice during either actionable request')

print('PASS butler_codex_approval_e2e')
