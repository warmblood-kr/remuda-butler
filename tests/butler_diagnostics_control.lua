-- Actual reporting-only control gate, synthetic screens and unchanged state tests.
local original_dofile, collector, broken = dofile, nil, false
local seen = 0
dofile = function(path)
  if path == 'packages/butler/dialogs.lua' then
    collector = original_dofile('packages/butler/diagnostics.lua')
    local record = collector.record
    collector.record = function(subsystem, outcome, reason, correlation)
      assert(subsystem == 'control' and outcome == 'stopped')
      assert(correlation == 'child-id' or correlation == 'codex-id', 'only agent identifier at boundary')
      if reason == 'heuristic_unknown_choice' then seen = seen + 1 end
      if broken then error('broken observer') end
      return record(subsystem, outcome, reason, correlation)
    end
  end
  return original_dofile(path)
end
dofile('tests/butler_dialogs.lua')
assert(seen > 0, 'actual unknown-choice stop boundary was not observed')
for _, event in ipairs(collector.snapshot().events) do
  assert(event.outcome == 'stopped' and event.severity == 'warn')
  assert(event.correlation:match('^c%-%x+$'), 'raw session identifier retained')
end
-- Existing state/write-gate assertions must pass even with a broken recorder.
broken = true
dofile('tests/butler_dialogs.lua')
dofile = original_dofile
print('diagnostics heuristic control stop and recorder isolation: ok')
