-- Focused relay test with real core JSON, synthetic transport and tmp files.
assert(remuda and remuda.json)
remuda.butler = { matrix = {} }
local timers, events, broken, mode, sequence = {}, {}, false, 'success', 0
remuda.schedule = function(spec)
  local timer = { spec = spec }; timers[#timers + 1] = timer; return timer
end
remuda.cancel = function(timer) timer.cancelled = true end
remuda._butler_new_ulid = function() sequence = sequence + 1; return 'synthetic-' .. sequence end
remuda.fs = { write_atomic = function(path, content)
  local file = assert(io.open(path, 'w')); assert(file:write(content)); assert(file:close()); return true
end }
remuda._butler_diagnostics = { record = function(subsystem, outcome, reason, correlation)
  assert(subsystem == 'matrix' and type(correlation) == 'string')
  if broken then error('synthetic observer failed') end
  events[reason] = (events[reason] or 0) + 1
end }
local matrix = dofile('packages/butler/matrix_request.lua')
local saved_exec = remuda.exec
remuda.exec = function() end
dofile('packages/butler/matrix.lua')
remuda.exec = saved_exec
dofile('packages/butler/matrix_delivery_policy.lua')
dofile('packages/butler/system.lua')
dofile('packages/butler/typed_lines.lua')
dofile('packages/butler/approval.lua')
dofile('packages/butler/approve_text.lua')
dofile('packages/butler/status_command.lua')
local relay = dofile('packages/butler/matrix_relay.lua')
local path = os.tmpname()
local config = assert(io.open(path, 'w'))
config:write('https://matrix.invalid\n!room:example.org\n@bot:example.org\n@alice:example.org\nfalse\n30000\n')
config:close()
local callbacks = {}
local client = { request_json = function(args, callback)
  callbacks[#callbacks + 1] = callback
  return { cancel = function() end }
end }
local instance = relay.new({ config_path = path, matrix = client, deliver = function()
  if mode == 'error' then error('SECRET payload error') end
  if mode == 'nil' then return nil end
  return true
end })
instance:start()
callbacks[1]({ json = { next_batch = 'baseline' } })
local function event(id)
  return { type = 'm.room.message', event_id = id, sender = '@alice:example.org',
    origin_server_ts = os.time() * 1000, content = { msgtype = 'm.text', body = 'SECRET message' } }
end
local cursor = 0
local function ingest(items)
  cursor = cursor + 1
  instance._response({ next_batch = 'cursor-' .. cursor, rooms = { join = {
    ['!room:example.org'] = { timeline = { events = items } },
  } } }, '/_matrix/client/v3/sync')
end
local invalid = event('$invalid'); invalid.content.body = nil
ingest({ invalid, event('$success') })
mode = 'nil'; ingest({ event('$deferred') })
assert(instance:state().pending['$deferred'], 'nil delivery remains pending')
mode = 'error'; ingest({ event('$failed') })
assert(instance:state().pending['$failed'], 'failed delivery remains pending')
mode = 'success'
for _, timer in ipairs(timers) do if not timer.cancelled then timer.spec.run() end end
assert(not instance:state().pending['$failed'], 'scheduled retry can deliver')
local normal_mode = matrix.notification_mode
matrix.notification_mode = function() return 'none' end
ingest({ event('$filtered') })
assert(not instance:state().pending['$filtered'], 'filter does not queue delivery')
matrix.notification_mode = normal_mode
broken, mode = true, 'nil'; ingest({ event('$observer-broken') })
assert(instance:state().pending['$observer-broken'], 'broken recorder preserves pending')
mode = 'success'; instance._response({ next_batch = 'final' }, '/_matrix/client/v3/sync')
assert(not instance:state().pending['$observer-broken'], 'broken recorder permits delivery')
for _, reason in ipairs({ 'conversion_ok', 'conversion_failed', 'filter_policy',
    'routing_accepted', 'delivery_ok', 'delivery_failed', 'delivery_deferred', 'retry_scheduled' }) do
  assert(events[reason] and events[reason] > 0, 'missing relay branch: ' .. reason)
end
instance:stop()
for _, suffix in ipairs({ '', '.since', '.since.bak', '.acks', '.acks.drain' }) do os.remove(path .. suffix) end
print('diagnostics Matrix conversion/filter/delivery/retry and recorder isolation: ok')
