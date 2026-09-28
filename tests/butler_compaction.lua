-- Run from the repo root: luajit tests/butler_compaction.lua
-- Exercise the scheduled tick's shared compaction gate without a daemon.
local used, busy, composer_empty = "?", false, true
remuda = {
  _butler_test_mode = true,
  _butler_compaction_threshold = 400000,
  _butler_bus = { agents = { butler = { kind = "claude" } } },
  _butler_telemetry_for = function() return { context_used = used } end,
  session = function() return { is_busy = busy } end,
  capture = function() return "mock screen" end,
}
dofile("packages/butler/main.lua")
remuda._butler_prompt_is_empty = function()
  return composer_empty and "EMPTY" or "NON-EMPTY"
end
local state, sends = {}, 0
local function tick(ctx, is_busy)
  used, busy = ctx, is_busy
  local should_send, reason, actual_ctx = remuda._butler_compaction_gate("butler", state)
  if should_send then sends = sends + 1 end
  return should_send, reason, actual_ctx
end

local send, reason, ctx = tick("399999", false)
assert(not send and reason == "skipped_small" and ctx == "399999" and sends == 0,
  "small context must not send /compact and must report skipped_small with ctx")

send, reason, ctx = tick("?", false)
assert(not send and reason == "skipped_unknown" and ctx == "?" and sends == 0,
  "unknown context must not send /compact and must report skipped_unknown with ctx")

send, reason = tick("500000", true)
assert(not send and reason == "skipped_busy", "busy tick must report skipped_busy")
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle" and sends == 0,
  "busy then idle for one tick must not send /compact")

state.idle_ticks = 0
composer_empty = false
send, reason, ctx = tick("500000", false)
assert(not send and reason == "skipped_composer" and ctx == "500000" and sends == 0,
  "nonempty composer must not send /compact and must report skipped_composer")
composer_empty = true
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle", "first idle tick must not send /compact")
send, reason, ctx = tick("500000", false)
assert(send and reason == "sent" and ctx == "500000" and sends == 1,
  "two consecutive idle ticks above threshold must send /compact once")
print("ok - Butler compaction context and two-tick idle gate")
