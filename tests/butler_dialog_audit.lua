-- Exercise the production JSONL writer with synthetic metadata and local files.
-- No daemon or state paths: os.tmpname supplies a disposable audit file.
local path = os.tmpname()
local encoded = {}
_G.remuda = {
  butler = {}, mkdir = function() return true end,
  list_dir = function() return {} end,
  json = {
    encode = function(value)
      local quoted = string.format('%q', value)
      encoded[quoted] = value
      return quoted
    end,
    decode = function(line)
      local record = {}
      for key, value in line:gmatch('"([%w_]+)":("[^"]*")') do record[key] = encoded[value] end
      return record
    end,
  },
  fs = { write_atomic = function(target, text, options)
    assert(target == path and options.private == true, 'audit must request private storage')
    local f = assert(io.open(target, 'w')); assert(f:write(text)); assert(f:close()); return true
  end },
}
local G = dofile('packages/butler/guard_policy.lua')
G.log_path = function() return path end
G.dir = function() return '/unused-mocked-directory' end
local events = { 'dialog_blocked', 'dialog_reported', 'dialog_resolved', 'dialog_action', 'dialog_action_result' }
for _, event in ipairs(events) do
  assert(G.append({ session = 'synthetic', kind = 'claude', event = event, class = 'other',
    instance_id = 'instance-one', dialog_id = 'unknown_choice', handler_version = '1', action = 'stop',
    summary = 'reporting-only', hash = 'synthetic-hash' }))
end
local f = assert(io.open(path, 'r')); local lines = f:read('*a'); f:close()
assert(lines:find('"instance_id":"instance-one"', 1, true), 'instance binding persisted')
assert(lines:find('"dialog_id":"unknown_choice"', 1, true), 'state id persisted')
assert(lines:find('"handler_version":"1"', 1, true) and lines:find('"action":"stop"', 1, true))
local stats = G.run('stats')
for _, event in ipairs(events) do assert(stats:find('event ' .. event .. ': 1', 1, true), 'enumerated stats: ' .. event) end
-- Writer failure must be observable by the dispatcher, even when guard is off.
remuda.fs.write_atomic = function() return false, 'disk full' end
local ok = G.append({ event = 'dialog_action', class = 'other' })
assert(not ok, 'audit storage failure must not report success')
os.remove(path)
print('butler dialog audit: PASS')
