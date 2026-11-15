-- Captured Codex 0.167.2 command prompt through the dialog tick: one Return
-- approval and fail-closed guards. Synthetic relay/key writer; no daemon.
local screens, keys, audits, posts = {}, {}, {}, {}
local instance, attached, hold, nonce = 'cx', false, false, 0
local bus = { agents = { codex = { id = 'codex-id', kind = 'codex', parent = 'leader',
  instance_id = 'cx', session_start_marker = 'launch-1' } } }
local store = { approvals = {} }
_G.remuda = {
  cli = { parse = function() return { kind = 'help', text = '' } end },
  butler = {}, _butler_bus = bus, _butler_agent_builders = {},
  _butler_agent_startup = {}, _butler_agent_support = {}, _butler_telemetry_adapters = {},
  _butler_system = {},
  capture = function() return screens.codex end,
  ls = function() return {{ name = 'codex', alive = true, instance_id = instance, attached = attached }} end,
  random_bytes = function(n)
    nonce = nonce + 1
    return string.rep(string.char(33 + nonce % 90), n)
  end,
  json = { null = {}, object = function(v) return v end },
  send = function() return true end,
  type_text = function() return 'submitted' end,
  _butler_send = function() return 'queued' end,
  _butler_dialog_originals = { key = function(_, key)
    keys[#keys + 1] = key
    if not hold then screens.codex = 'done' end
    return true
  end },
}
remuda.butler.guard_approval = { sha256 = function(v) return 'digest:' .. v end }
remuda.butler.guard_policy = { append = function(record)
  audits[#audits + 1] = record
  return true
end }
remuda._butler_compaction_module_config = { registered_agent_kind = function() end, registered_agent_working = function() end }
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
local descriptor = remuda._butler_agent_startup.codex.dialog_approvals[1]
local approval = dofile('packages/butler/approval.lua')
local function attach(room, enabled)
  room = room or '!owner'
  approval.attach(store, function() return true end, function(text, _, cb)
    posts[#posts + 1] = text; cb({ event_id = '$post' .. #posts }); return true
  end, function() return room end, room, enabled ~= false)
end
attach()
local D = dofile('packages/butler/dialogs.lua')
D.install()
dofile('packages/butler/dialog_approval.lua')
local NOTICE = dofile('packages/butler/dialog_owner_notice.lua')
local fixture = assert(io.open('tests/fixtures/codex-approval-command.txt'))
local COMMAND = fixture:read('*a'); fixture:close()
local function with_command(text) return (COMMAND:gsub('%$ touch [^\n]+', '$ ' .. text)) end
local function ticks(count) for _ = 1, count do D.tick() end end
local function reset(next)
  screens.codex, bus.dialog_states.codex = next or COMMAND, nil
  instance, attached, hold = 'cx', false, false
  keys, audits, posts = {}, {}, {}
end
local function requests()
  local found = {}
  for _, text in ipairs(posts) do
    if text:sub(1, 23) == 'Butler dialog approval ' then found[#found + 1] = text end
  end
  return found
end
local function open()
  for _, rec in pairs(store.approvals) do if rec.status == 'open' then return rec end end
end
local function ask()
  reset(); ticks(3)
  return assert(open(), 'an actionable request was expected')
end
local function answer(rec, verdict, who, event)
  return approval.answer(rec.id, verdict, who or '@owner:test', event or ('$' .. (rec.id or 'x')))
end
-- 1. The real tick -> classifier -> request -> approve -> resolve path.
local rec = ask()
assert(#requests() == 1, 'one actionable request from the tick')
local text = requests()[1]
assert(text:find('touch /private/tmp/codex-esc-probe/outside.txt', 1, true)
  and text:find('untrusted screen text', 1, true) and text:find('Yes, proceed', 1, true)
  and text:find('Escape cancel', 1, true), 'shows the action and both answers')
assert(not text:find('Press enter', 1, true) and not text:find('Reason:', 1, true), 'no screen body')
assert(#text <= 2048 and approval.target_room() == '!owner', 'bounded request in the owner room')
assert(answer(rec, 'approve') and rec.status == 'applied' and keys[1] == 'RET', 'one Return applied')
assert(audits[#audits].event == 'dialog_action_result' and audits[#audits].summary == 'verified',
  'verified outcome audited')
assert(not answer(rec, 'approve') and #keys == 1, 'a duplicate answer never writes')
D.tick()
assert(not bus.dialog_states.codex.blocked, 'the prompt resolves after approval')
rec = ask()
assert(#requests() == 1, 'a later identical prompt asks again')
-- 2. Parser: only the exact captured 0.167.2 geometry is actionable.
local plan = assert(descriptor.match(COMMAND), 'fixture matches')
assert(plan.key == 'RET' and plan.label == 'Yes, proceed' and descriptor.deny_key == 'ESC'
  and plan.summary == 'run `touch /private/tmp/codex-esc-probe/outside.txt`', 'exact plan')
assert(not descriptor.verify(COMMAND) and descriptor.verify('done'), 'verify is the prompt gone')
local refusals = {
  { with_command('env GITHUB_TOKEN=abc cargo test'), 'token assignment' },
  { with_command('npm publish --token=abcdef'), 'token option' },
  { with_command('mysql --password=secret -e x'), 'password option' },
  { with_command('curl -H "Authorization: Bearer abcdefgh" https://x'), 'bearer header' },
  { with_command('git clone https://user:pass@example.com/repo'), 'URL credentials' },
  { with_command('echo sk-1234567890abcdef'), 'token prefix' },
  { with_command('curl -u user:pass https://x'), 'basic auth option' },
  { with_command('openssl -----BEGIN RSA PRIVATE KEY-----'), 'private key' },
  { COMMAND:gsub('› 1%.', '  1.'):gsub('  2%.', '› 2.'), 'blanket option selected' },
  { COMMAND:gsub('(%$ touch [^\n]+\n)', '%1  $ cargo build\n'), 'two commands' },
  { COMMAND:gsub('(%$ touch [^\n]+\n)', '%1  and more\n'), 'wrapped command line' },
  { COMMAND:gsub('Yes, proceed %(y%)', 'Yes %(y%)'), 'changed approve label' },
  { with_command(string.rep('a', 201)), 'command too long to show' },
  { with_command('cargo\tbuild'), 'control character' },
  { COMMAND .. '\n❯ ', 'composer below the prompt' },
}
for _, case in ipairs(refusals) do
  assert(not descriptor.match(case[1]), 'not actionable: ' .. case[2])
  reset(case[1]); ticks(3)
  assert(#requests() == 0, 'no request for: ' .. case[2])
end
assert(descriptor.match(with_command('cargo test --release --quiet')), 'a benign command is actionable')
-- 3. A live denial sends one Escape; the terminal sends nothing.
rec = ask()
assert(answer(rec, 'deny') and rec.status == 'denied' and rec.delivery_started
  and #keys == 1 and keys[1] == 'ESC', 'a live denial sends one Escape')
assert(not answer(rec, 'deny') and #keys == 1, 'a duplicate denial never writes')
rec = ask()
assert(answer(rec, 'deny', 'operator (terminal)') and rec.status == 'denied' and #keys == 0,
  'terminal denial never writes')
-- 4. Changed screen, instance or attachment refuses before any key.
rec = ask(); screens.codex = with_command('touch /private/tmp/codex-esc-probe/other.txt'); answer(rec, 'approve')
assert(rec.status == 'failed' and #keys == 0, 'changed command refused')
rec = ask(); instance = 'replacement'; answer(rec, 'approve')
assert(rec.status == 'failed' and #keys == 0, 'replaced instance refused')
rec = ask(); attached = true; answer(rec, 'approve')
assert(rec.status == 'failed' and #keys == 0, 'attached human refused')
-- 5. Expiry, restart and an uncertain write never replay input.
rec = ask(); rec.expires_at = 0; approval.sweep()
assert(rec.status == 'expired' and #keys == 0, 'expiry never acts')
rec = ask(); attach()
assert(rec.status == 'expired' and #keys == 0, 'restart expires an unanswered request')
rec = ask(); hold = true
assert(answer(rec, 'approve') and rec.status == 'failed' and rec.delivery_started and #keys == 1,
  'unverified write is consumed once')
hold = false
assert(not answer(rec, 'approve') and #keys == 1, 'uncertain write never retries')
rec = ask(); rec.status, rec.delivery_started = 'approved', true; attach()
assert(rec.status == 'expired' and #keys == 0, 'restart never replays a consumed key')
-- 6. A changed descriptor version refuses the stored request.
rec = ask(); descriptor.version = '2'; answer(rec, 'approve')
assert(rec.status == 'failed' and #keys == 0, 'version change refused')
descriptor.version = '1'
-- 7. An actionable request suppresses the notice; without a descriptor it stays.
rec = ask()
for _, text in ipairs(posts) do assert(text:sub(1, 14) ~= 'Butler notice:', 'no duplicate notice') end
remuda._butler_agent_startup.codex.dialog_approvals = {}
local state = bus.dialog_states.codex
local S = bus.dialog_owner_notice_state
S.delivered, S.index, S.generation, S.seen, S.next_at, S.session_at = {}, {}, {}, {}, {}, {}
NOTICE.clock = function() return 1000 end
assert(NOTICE.consider('codex', bus.agents.codex, state) == false, 'first sighting debounces')
NOTICE.clock = function() return 1004 end
local before = #posts
assert(NOTICE.consider('codex', bus.agents.codex, state) == true and #posts == before + 1,
  'the plain notice remains the fallback')
-- 8. No room or no explicit opt-in fails closed: no request.
dofile('packages/butler/agents/codex.lua')
attach(''); reset(); ticks(3)
assert(#requests() == 0, 'no request without a configured room')
attach('!owner', false); reset(); ticks(3)
assert(#requests() == 0, 'disabled dialog actions post no request')
attach('!owner')
print('PASS butler_codex_dialog_approval')
