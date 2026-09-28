-- Run from the repo root: luajit tests/butler_compaction.lua
-- Exercise the scheduled tick's shared compaction gate without a daemon.
local used, busy, composer_empty, session_failure, attached, queued = "?", false, true, false, false, false
local screen = "mock idle screen"
remuda = {
  _butler_test_mode = true,
  _butler_compaction_threshold = 400000,
  _butler_compaction_critical_threshold = 600000,
  _butler_compaction_capture_gap = 3,
  _butler_compaction_cooldown = 2,
  _butler_bus = { agents = { butler = { kind = "claude" } } },
  _butler_telemetry_for = function() return { context_used = used } end,
  session = function()
    if session_failure then error("session is no longer alive") end
    return { is_busy = busy, attached = attached }
  end,
  ls = function() return { { name = "butler", alive = true, attached = attached } } end,
  _butler_compaction_has_queued_mail = function() return queued end,
  capture = function() return screen end,
}
dofile("packages/butler/main.lua")
remuda._butler_agent_startup = {
  claude = { working = function(value) return value:find("esc to interrupt", 1, true) ~= nil end },
}
remuda._butler_prompt_is_empty = function()
  return composer_empty and "EMPTY" or "NON-EMPTY"
end
local state, sends, fake_now = {}, 0, 100
remuda._butler_compaction_now = function() return fake_now end
local function tick(ctx, is_busy)
  fake_now = fake_now + 3
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
state.idle_ticks = 0
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle" and sends == 0,
  "400k threshold must wait for a busy-to-idle transition even after two idle captures")
send, reason = tick("500000", true)
assert(not send and reason == "skipped_busy", "busy observation must arm the normal threshold transition")
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle", "first capture after busy-to-idle only starts confirmation")
send, reason = tick("500000", false)
assert(send and reason == "sent" and sends == 1,
  "normal threshold compacts on the second capture after busy-to-idle")

for _ = 1, 2 do
  send, reason, ctx = tick("500000", false)
  assert(not send and reason == "skipped_cooldown" and ctx == "500000" and sends == 1,
    "post-send cooldown ticks must not send /compact")
end
send, reason = tick("399999", false)
assert(not send and reason == "skipped_small", "context dropping below threshold must clear cooldown")
send, reason = tick("500000", true)
assert(not send and reason == "skipped_busy", "normal threshold requires a fresh work-loop transition")
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle", "first eligible tick after cooldown release must count")
send, reason, ctx = tick("500000", false)
assert(send and reason == "sent" and ctx == "500000" and sends == 2,
  "compaction may send again after context dropped below threshold")
for _ = 1, 2 do
  send, reason = tick("500000", false)
  assert(not send and reason == "skipped_cooldown", "cooldown must block repeated sends")
end
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle", "idle counting resumes after cooldown ticks pass")
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle" and sends == 2,
  "normal threshold remains gated until a fresh busy-to-idle transition")
send, reason = tick("500000", true)
assert(not send and reason == "skipped_busy", "busy work-loop end arms the next normal compaction")
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle", "first idle capture after work completion waits")
send, reason = tick("500000", false)
assert(send and reason == "sent" and sends == 3,
  "compaction may send again after the configured cooldown expires")

state = {}
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle", "normal threshold idle capture one must wait")
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle" and sends == 3,
  "normal threshold must not compact during an idle that did not follow busy")

state = {}
send, reason = tick("600000", false)
assert(not send and reason == "skipped_idle", "critical threshold still needs the first idle capture")
send, reason = tick("600000", false)
assert(send and reason == "sent" and sends == 4,
  "critical threshold may compact during already-established idle after two captures")

state = {}
attached = true
send, reason = tick("600000", false)
assert(not send and reason == "skipped_attached", "an attached human must prevent compaction")
attached = false
queued = true
send, reason = tick("600000", false)
assert(not send and reason == "skipped_queued", "queued mail must prevent compaction")
queued = false

local answer, phase = remuda._butler_compaction_visible_answer(
  "claude", "Switch model?\n2. No, keep current model\n3. Yes, switch to Sonnet", "sonnet")
assert(answer == "3" and phase == "dialog", "dialog answer must be parsed from the yes/switch option label")
answer, phase = remuda._butler_compaction_visible_answer(
  "claude", "Switch model?\n1. Yes, switch to Sonnet\n2. No", "sonnet")
assert(answer == "1" and phase == "dialog", "dialog option order may vary")
answer, phase = remuda._butler_compaction_visible_answer(
  "claude", "Switch model?\n1. No\n2. Keep current model", "sonnet")
assert(answer == nil and phase == "unknown", "dialog without a yes/switch label must be unknown")
answer, phase = remuda._butler_compaction_visible_answer(
  "claude", "MODEL:Sonnet-4.5 CTX:500000\n❯", "sonnet")
assert(answer == nil and phase == "ready", "already-switched statusline must advance without a stray key")
answer, phase = remuda._butler_compaction_visible_answer(
  "claude", "Unknown modal\nPress 1 to continue", "sonnet")
assert(answer == nil and phase == "unknown", "unrecognized dialog must be reported, never answered blindly")

local claude_sequence = remuda._butler_compaction_sequence("claude", "opus", "sonnet")
assert(table.concat(claude_sequence, "|") == "/model sonnet|/compact|/model opus",
  "Claude sequence must queue low model, compact, then restore prior model")
local codex_sequence = remuda._butler_compaction_sequence("codex", "gpt-5.6-terra", "sonnet")
assert(table.concat(codex_sequence, "|") == "/compact|ENTER",
  "Codex sequence must compact and include its extra Enter without switching models")

local submit_count = 0
local function submit(decision, text)
  if remuda._butler_compaction_submit_matches(decision, text) then
    submit_count = submit_count + 1
    return true
  end
  return false
end
assert(not submit("NON-EMPTY", "/compact and human text") and submit_count == 0,
  "submit must skip if a human adds text after /compact")
assert(not submit("EMPTY", "") and submit_count == 0,
  "submit must skip if the composer changed before the delayed Enter")
assert(submit("NON-EMPTY", "/compact") and submit_count == 1,
  "submit may confirm only the exact /compact composer text")
print("ok - Butler compaction context and two-tick idle gate")
