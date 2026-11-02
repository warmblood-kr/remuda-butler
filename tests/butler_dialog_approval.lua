-- Synthetic acknowledgement only: this is not a Claude/Codex permission fixture.
local screen, instance, attached = 'SYNTHETIC acknowledge once', 'instance-1', false
local writes, audits, posts, fail_audit, fail_persist, after_audit = 0, {}, {}, false, false
local agent = { id = 'agent-1', kind = 'claude', instance_id = instance, session_start_marker = 'launch-1' }
local blocked = { blocked = true, id = 'unknown_choice', captures = 2, instance = instance, signature = screen, agent = agent }
local store = { approvals = {} }
_G.remuda = {
  butler = {}, _butler_bus = { agents = { child = agent }, dialog_states = { child = blocked } },
  _butler_agent_startup = { claude = { dialog_approvals = {} } },
  capture = function() return screen end,
  ls = function() return {{ name = 'child', alive = true, instance_id = instance, attached = attached }} end,
  random_bytes = function(n) return string.rep(string.char(#posts + 1), n) end,
  json = { object = function(v) return v end },
  _butler_dialog_originals = { key = function(_, key)
    assert(key == '1'); writes = writes + 1; screen = 'SYNTHETIC done'; return true
  end },
}
remuda.butler.guard_approval = { sha256 = function(v) return 'digest:' .. v end }
remuda.butler.guard_policy = { append = function(record)
  if fail_audit then return false end
  audits[#audits + 1] = record
  if after_audit then after_audit(record) end
  return true
end }
remuda.butler.dialogs = { check = function() return not blocked.blocked, blocked end }
local approval = dofile('packages/butler/approval.lua')
local function attach()
  approval.attach(store, function() return not fail_persist end, function(text, _, cb)
    posts[#posts + 1] = text; cb({event_id = '$post' .. #posts}); return true
  end, function() return '!owner' end, '!owner')
end
attach()
local D = dofile('packages/butler/dialog_approval.lua')
local descriptor = { id = 'synthetic_ack', version = '1', category = 'acknowledgement',
  action_scope = 'once',
  fixture = 'tests/fixtures/butler-dialog-synthetic-ack.txt',
  match = function(value)
    if value == 'SYNTHETIC acknowledge once' then
      return { signature = value, key = '1', label = 'Acknowledge once', summary = 'acknowledge the synthetic test' }
    end
  end,
  verify = function(value) return value == 'SYNTHETIC done' end,
}
remuda._butler_agent_startup.claude.dialog_approvals = { descriptor }
local function ask()
  screen, instance, attached = 'SYNTHETIC acknowledge once', 'instance-1', false
  blocked.signature, blocked.captures, blocked.instance = screen, 2, instance
  blocked.approval_attempted = nil
  D.consider('child')
  local record
  for _, rec in pairs(store.approvals) do if rec.status == 'open' then record = rec end end
  return assert(record)
end
local function answer(rec) return approval.answer(rec.id, 'approve', '@owner:test', '$owner' .. rec.id) end
local rec = ask()
D.consider('child'); assert(#posts == 1 and writes == 0, 'stable request deduped, never auto-write')
assert(not approval.answer(rec.id, 'approve', 'operator (terminal)'), 'terminal cannot approve dialog input')
assert(answer(rec) and rec.status == 'applied' and writes == 1, 'live scoped approval applies once')
assert(not answer(rec) and writes == 1, 'duplicate answer never repeats input')
assert(audits[#audits].event == 'dialog_action_result' and audits[#audits].id == rec.id, 'request-linked outcome')
assert(rec.data.signature == nil and rec.data.screen == nil, 'no raw screen persisted')
rec = ask(); screen = 'different choice'; answer(rec)
assert(rec.status == 'failed' and writes == 1, 'changed screen refused')
rec = ask(); instance = 'replacement'; answer(rec)
assert(rec.status == 'failed' and writes == 1, 'replaced session refused')
rec = ask(); attached = true; answer(rec)
assert(rec.status == 'failed' and writes == 1, 'human attachment refused')
rec = ask(); fail_audit = true; assert(not answer(rec) and writes == 1, 'audit failure before answer refuses')
fail_audit = false; approval.answer(rec.id, 'deny', '@owner:test', '$deny')
rec = ask(); after_audit = function(r) if r.summary == 'before_write' then screen = 'repaint' end end
answer(rec); after_audit = nil
assert(rec.status == 'failed' and writes == 1, 'screen changes during yielding audit refused')
rec = ask(); fail_persist = true; answer(rec); fail_persist = false
assert(rec.status == 'failed' and writes == 1, 'durable consumed marker required before input')
rec = ask(); attach()
assert(rec.status == 'expired' and writes == 1, 'restart expires unanswered request')
rec = ask(); rec.expires_at = 0; approval.sweep()
assert(rec.status == 'expired' and writes == 1, 'expiry never acts')
rec = ask(); approval.answer(rec.id, 'deny', '@owner:test', '$deny2')
assert(rec.status == 'denied' and writes == 1, 'denial never acts')
rec = ask(); descriptor.version = '2'; answer(rec)
assert(rec.status == 'failed' and writes == 1, 'changed handler version refused'); descriptor.version = '1'
rec = ask(); descriptor.match = function(value)
  if value == 'SYNTHETIC acknowledge once' then return {
    signature = value, key = '2', label = 'Other choice', summary = 'different target' } end
end
answer(rec); assert(rec.status == 'failed' and writes == 1, 'changed option refused')
descriptor.match = function(value)
  if value == 'SYNTHETIC acknowledge once' then return {
    signature = value, key = '1', label = 'Acknowledge once', summary = 'acknowledge the synthetic test' } end
end
rec = ask(); descriptor.verify = function() return false end; answer(rec)
assert(rec.status == 'failed' and rec.delivery_started and writes == 2, 'unverified write consumed once')
assert(not answer(rec) and writes == 2, 'unverified write never retries')
rec = ask(); rec.status, rec.delivery_started = 'approved', true; attach()
assert(rec.status == 'expired' and writes == 2, 'restart with consumed input never replays')
rec = ask(); local cancelled = approval.answer(rec.id, 'deny', 'operator (terminal)')
assert(cancelled and writes == 2,
  'terminal may cancel but cannot approve')
descriptor.category = 'classifier_denial'; blocked.approval_attempted = nil
D.consider('child'); assert(#approval.list() == 0, 'classifier denial is never an approval action')
print('butler dialog approval: PASS')
