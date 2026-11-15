-- Exercise intake through the real diagnostics recorder without a real database.
local secret = 'PRIVATE payload and SQL error \27[31m'
local function setup(failure)
  remuda = {}
  local diagnostics = dofile('packages/butler/diagnostics.lua')
  local db = {}
  function db:query(sql)
    if sql:find('relay_meta', 1, true) then return {{value = 'shadow'}} end
    if sql:find('relay_inbound WHERE event_id', 1, true) then
      return {{room_id = '!room', payload_json = 'original'}}
    end
    return {}
  end
  function db:exec(sql)
    if sql == failure then return nil, secret end
    return true
  end
  function db:close() return true end
  remuda._butler_relay_intake_config = {open = function() return db end}
  return dofile('packages/butler/relay_intake.lua'), diagnostics
end
local function check(diagnostics, reasons)
  local snapshot = diagnostics.snapshot({subsystem = 'relay_intake', severity = 'error'})
  assert(#snapshot.events == #reasons, 'expected retained intake events')
  for i, row in ipairs(snapshot.events) do
    assert(row.reason == reasons[i] and row.subsystem == 'relay_intake')
    assert(row.correlation:match('^event%-%d+$'), 'no error text or event payload as correlation')
    for _, value in pairs(row) do
      assert(not value:find('PRIVATE', 1, true) and not value:find('\27', 1, true))
    end
  end
  local rendered = assert(diagnostics.command({'diagnostics-list', '--subsystem', 'relay_intake'}))
  assert(not rendered:find('PRIVATE', 1, true) and not rendered:find('\27', 1, true))
end
local intake, diagnostics = setup('BEGIN IMMEDIATE')
assert(not intake.admit({}, 'cursor', 1))
check(diagnostics, {'intake_begin_failed'})
intake, diagnostics = setup(nil)
assert(not intake.admit({{event_id = '$id', room_id = '!room', payload_json = secret}}, 'cursor', 1))
check(diagnostics, {'intake_admit_failed'})
intake, diagnostics = setup('ROLLBACK')
assert(not intake.admit({{event_id = '$id', room_id = '!room', payload_json = secret}}, 'cursor', 1))
check(diagnostics, {'intake_disposed', 'intake_rollback_failed'})
assert(not intake.status().available)
intake, diagnostics = setup('COMMIT')
assert(not intake.admit({}, 'cursor', 1))
check(diagnostics, {'intake_disposed'})
assert(not intake.status().available)
intake, diagnostics = setup('BEGIN IMMEDIATE')
remuda._butler_diagnostics.record = function() error(secret) end
assert(not intake.admit({}, 'cursor', 1), 'observer failure must not alter admission outcome')
print('relay intake diagnostics and privacy: ok')
