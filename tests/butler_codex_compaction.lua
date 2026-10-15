-- Standalone production orchestration; no daemon, authentication or real session.
dofile('tests/butler_compaction.lua')
assert(dofile('tests/fixtures/codex-compaction-scenarios.lua') == 'ok')
print('Codex current-model compaction: PASS')
