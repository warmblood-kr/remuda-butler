-- Synthetic storage failures: diagnostics never receive payload/error text,
-- and a failing recorder never changes durable mail outcomes.
local original_open = io.open
local events, sequence, fail = {}, 0, nil
local bus = { agents = {}, inboxes = {}, messages = {}, objects = {} }
remuda = {
  _butler_mail_config = { bus = bus, root = '/synthetic',
    json_quote = function(s) return string.format('%q', s) end },
  _butler_new_ulid = function() sequence = sequence + 1; return 'synthetic-' .. sequence end,
  mkdir = function() if fail == 'storage_prepare' then error('SECRET credential') end end,
  _butler_diagnostics = { record = function(subsystem, outcome, reason, correlation)
    events[#events + 1] = { subsystem, outcome, reason, correlation }
  end },
}
io.open = function(path, mode)
  if mode == 'r' or mode == 'rb' then return nil end
  local blocked = (fail == 'body_write' and path:find('/objects/', 1, true))
    or (fail == 'envelope_write' and path:find('/messages/', 1, true))
    or (fail == 'inbox_append' and path:find('/inboxes/', 1, true))
    or (fail == 'read_state_write' and path:find('/read/', 1, true))
  if blocked then return nil, 'SECRET credential' end
  return { write = function() return true end, close = function() return true end }
end
local original_rename = os.rename
os.rename = function() return true end
dofile('packages/butler/mail.lua')
local from, to = { id = 'sender', alias = 'private sender' }, { id = 'recipient', alias = 'private recipient' }
for _, reason in ipairs({ 'storage_prepare', 'body_write', 'envelope_write', 'inbox_append' }) do
  fail = reason
  local result = remuda._butler_mail.queue(from, to, 'SECRET message payload')
  assert(result == nil, 'injected durable failure must prevent delivery')
  local event = events[#events]
  assert(event[1] == 'mail' and event[2] == 'error' and event[3] == reason)
  assert(event[4]:match('^synthetic%-%d+$'), 'only correlation ID reaches recorder')
  assert(#bus.inboxes.recipient == 0, 'failed persistence cannot enter inbox')
end
fail = nil
local message = assert(remuda._butler_mail.queue(from, to, 'SECRET message payload'))
assert(events[#events][2] == 'delivered')
fail = 'read_state_write'
assert(remuda._butler_mail.inbox('recipient'):find('mail read%-state was not saved'))
assert(events[#events][3] == 'read_state_write')
assert(#bus.inboxes.recipient == 1, 'failed read acknowledgement must retain inbox')
assert(remuda._butler_mail.unread('recipient') == 1, 'reviewed read-flag fix must retain unread state')
fail = nil
assert(remuda._butler_mail.inbox('recipient'):find('SECRET message payload', 1, true))
assert(remuda._butler_mail.unread('recipient') == 0, 'successful retry drains original message')
local write_open = io.open
io.open = function(path, mode)
  if mode == 'r' and path:find('/inboxes/', 1, true) then
    return { lines = function()
      local emitted = false
      return function() if not emitted then emitted = true; return '{"message_id":"corrupt-record"}' end end
    end, close = function() return true end }
  end
  return write_open(path, mode)
end
remuda._butler_mail.unread('missing-envelope')
assert(events[#events][3] == 'envelope_read' and events[#events][4] == 'corrupt-record')
local observed = #events
remuda._butler_mail.unread('missing-envelope')
assert(#events == observed, 'repeated unread queries must not flood diagnostics')
io.open = write_open
remuda._butler_diagnostics.record = function() error('broken observer') end
fail = 'body_write'
assert(remuda._butler_mail.queue(from, to, 'SECRET payload') == nil)
fail = nil
assert(remuda._butler_mail.queue(from, to, 'SECRET payload'))
io.open, os.rename = original_open, original_rename
print('diagnostics instrumentation synthetic storage failures: ok')
