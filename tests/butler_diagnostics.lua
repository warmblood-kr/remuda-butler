-- Synthetic boundedness, privacy, filtering and CLI projections. No daemon I/O.
local json = remuda and remuda.json
local cli = remuda and remuda.cli
remuda = { json = json, cli = cli }
local D = dofile('packages/butler/diagnostics.lua')
assert(D.format_all():find('No retained observations; health is unknown.', 1, true))
local secret = 'PRIVATE payload command --password=hunter2\27[31m'
assert(not D.record(secret, 'error', 'body_write', secret))
assert(not D.record('mail', secret, 'body_write', secret))
assert(not D.record('mail', 'error', secret, secret))
assert(#D.snapshot().events == 0, 'unreviewed text must never enter ring')
for i = 1, 205 do
  assert(D.record(i % 2 == 0 and 'mail' or 'matrix', i % 2 == 0 and 'error' or 'delivered',
    i % 2 == 0 and 'body_write' or 'delivery_ok', secret))
end
local snapshot = D.snapshot()
assert(#snapshot.events == 200 and snapshot.capacity == 200 and snapshot.dropped == 5)
assert(snapshot.events[1].subsystem == 'mail', 'eviction must retain chronological order')
assert(snapshot.events[200].subsystem == 'matrix', 'newest event missing')
local expected = {time=true,severity=true,subsystem=true,correlation=true,outcome=true,reason=true}
for _, event in ipairs(snapshot.events) do
  for key, value in pairs(event) do
    assert(expected[key] and type(value) == 'string', 'unexpected retained field')
    assert(not value:find('PRIVATE', 1, true) and not value:find('hunter2', 1, true))
    assert(not value:find('\27', 1, true), 'terminal escape retained')
  end
  assert(event.time:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'))
  assert(event.correlation == snapshot.events[1].correlation, 'grouping token must be stable')
end
assert(not D.format_all():find(secret, 1, true))
assert(#D.snapshot({subsystem='mail',severity='error'}).events == 100)
assert(#D.snapshot({subsystem='mail',severity='info'}).events == 0)
assert(#D.snapshot().events == 200, 'query must not drain history')
local list = assert(D.command({'diagnostics-list','--subsystem','mail','--severity','error'}))
assert(list:find('body_write',1,true) and not list:find('delivery_ok',1,true))
for _, args in ipairs({{'diagnostics','--page','0'}, {'diagnostics','--page','18'},
  {'diagnostics','--page','nan'}, {'diagnostics-list','--page','2'},
  {'diagnostics-list','--subsystem',secret}, {'diagnostics-list','--severity','bad'},
  {'diagnostics-list','--json','--json'}, {'diagnostics','--unknown',secret}}) do
  local result, why = D.command(args)
  assert(result == nil and type(why) == 'string' and not why:find(secret, 1, true))
end
if json then
  local encoded = assert(D.command({'diagnostics-list','--json','--subsystem','notice'}))
  assert(encoded:find('"events":[]',1,true), 'empty events must be a JSON array')
  local decoded = json.decode(assert(D.command({'diagnostics-list','--json'})))
  assert(#decoded.events == 200 and decoded.dropped == 5 and decoded.scope == 'node-local')
end
-- Reload retains current-image memory; a new daemon image begins empty.
dofile('packages/butler/diagnostics.lua')
assert(#remuda._butler_diagnostics.snapshot().events == 200)
remuda._butler_diagnostics_state = nil
assert(#dofile('packages/butler/diagnostics.lua').snapshot().events == 0)
print('diagnostics boundedness, privacy, query and CLI: ok')
