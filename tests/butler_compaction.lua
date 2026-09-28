-- Run from the repo root: luajit tests/butler_compaction.lua
-- Exercise the scheduled tick's shared compaction gate without a daemon.
local used, busy, composer_empty, session_failure = "?", false, true, false
local screen = "mock idle screen"
remuda = {
  _butler_test_mode = true,
  _butler_compaction_threshold = 400000,
  _butler_bus = { agents = { butler = { kind = "claude" } } },
  _butler_telemetry_for = function() return { context_used = used } end,
  session = function()
    if session_failure then error("session is no longer alive") end
    return { is_busy = busy }
  end,
  capture = function() return screen end,
}
dofile("packages/butler/main.lua")
remuda._butler_agent_startup = {
  claude = { working = function(value) return value:find("esc to interrupt", 1, true) ~= nil end },
}
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
session_failure = true
send, reason, ctx = tick("500000", false)
assert(not send and reason == "skipped_unknown" and ctx == "500000" and sends == 0,
  "missing session must fail closed as skipped_unknown")
session_failure = false

screen = "Working (3s · esc to interrupt)"
send, reason, ctx = tick("500000", false)
assert(not send and reason == "skipped_busy" and ctx == "500000" and sends == 0,
  "streaming screen must be skipped_busy even when session.is_busy is false")
screen = "mock idle screen"

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

local function submit(decision, text)
  if remuda._butler_compaction_submit_matches(decision, text) then
    sends = sends + 1
    return true
  end
  return false
end
assert(not submit("NON-EMPTY", "/compact and human text") and sends == 1,
  "submit must skip if a human adds text after /compact")
assert(not submit("EMPTY", "") and sends == 1,
  "submit must skip if the composer changed before the delayed Enter")
assert(submit("NON-EMPTY", "/compact") and sends == 2,
  "submit may confirm only the exact /compact composer text")
print("ok - Butler compaction context and two-tick idle gate")
