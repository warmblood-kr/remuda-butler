-- Run from the repo root: luajit tests/butler_compaction.lua
-- Exercise the scheduled tick's shared compaction gate without a daemon.
local used, used_pct, busy, composer_empty, session_failure, attached, queued = "?", nil, false, true, false, false, false
local screen = "mock idle screen"
remuda = {
  _butler_test_mode = true,
  _butler_compaction_config = {
    watch = 400000, warn = 600000, critical = 800000, critical_pct = 90,
    capture_gap = 3, cooldown_ticks = 2,
  },
  _butler_bus = { agents = { butler = { kind = "claude" } } },
  _butler_telemetry_for = function() return { context_used = used, context_pct = used_pct } end,
  session = function()
    if session_failure then error("session is no longer alive") end
    return { is_busy = busy, attached = attached }
  end,
  ls = function() return { { name = "butler", alive = true, attached = attached } } end,
  _butler_compaction_has_queued_mail = function() return queued end,
  capture = function() return screen end,
}
dofile("packages/butler/main.lua")
used = "500000"
assert(type(remuda.butler) == "table", "composable compaction API must be exported")
local level = remuda.butler.ctx_level("butler")
assert(level.level == "watch" and level.used == 500000,
  "ctx_level must classify threshold context and retain usage")
assert(type(remuda.butler.is_idle) == "function" and type(remuda.butler.compact) == "function"
  and type(remuda.butler.compaction_policy) == "function",
  "compaction must expose idle, per-agent action and composite policy units")
for _, case in ipairs({ {"399999", "ok"}, {"400000", "watch"},
    {"600000", "warn"}, {"800000", "critical"} }) do
  used = case[1]
  assert(remuda.butler.ctx_level("butler").level == case[2],
    "unexpected context level at " .. case[1])
end
used, used_pct = "100000", 91
assert(remuda.butler.ctx_level("butler").level == "critical",
  "critical percentage must override a low absolute usage count")
remuda._butler_prompt_is_empty = function() return "EMPTY" end
local urgent, urgent_reason = remuda.butler.compaction_policy("butler", {})
assert(urgent and urgent_reason == "sent",
  "critical percentage must trigger policy even when absolute usage is low")
local dry_state = { idle_ticks = 3, cooldown_ticks = 2, last_idle_capture_at = 50 }
used, used_pct = "600000", nil
local _, dry_reason = remuda.butler.compaction_policy("butler", dry_state, true)
assert(dry_reason == "skipped_cooldown" and dry_state.idle_ticks == 3
  and dry_state.cooldown_ticks == 2 and dry_state.last_idle_capture_at == 50,
  "dry-run policy must not mutate its input state")
used_pct = nil
remuda.contributions = function(point)
  if point == "butler.agent" then
    local contribution_state = {}
    local function bind_working(fn)
      return function(...) return fn(contribution_state, ...) end
    end
    local working = bind_working(function(_, value)
      return value:find("esc to interrupt", 1, true) ~= nil
    end)
    return {
      { id = "claude", entry = { working = working } },
      { id = "codex", entry = { working = working } },
    }
  end
  return {}
end
remuda._butler_prompt_is_empty = function()
  return composer_empty and "EMPTY" or "NON-EMPTY"
end
local idle, idle_reason = remuda.butler.is_idle("butler")
assert(idle and idle_reason == "idle", "is_idle should accept idle session with empty composer")
local preflight = remuda._butler_compaction_preflight("butler")
assert(preflight == nil,
  "preflight should call the registered bound working predicate with the screen")
local state, sends, fake_now = {}, 0, 100
remuda._butler_compaction_now = function() return fake_now end
local function tick(ctx, is_busy)
  fake_now = fake_now + 3
  used, busy = ctx, is_busy
  local should_send, reason, actual_ctx = remuda.butler.compaction_policy("butler", state)
  if should_send then sends = sends + 1 end
  return should_send, reason, tostring(actual_ctx)
end

local send, reason, ctx = tick("399999", false)
assert(not send and reason == "skipped_small" and ctx == "399999" and sends == 0,
  "small context must not send /compact and must report skipped_small with ctx")

send, reason, ctx = tick("?", false)
assert(not send and reason == "skipped_small" and ctx == "?" and sends == 0,
  "unknown context must classify as ok and not send /compact")
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
assert(send and reason == "sent" and sends == 3,
  "watch level compacts after two idle captures even without a busy transition")

state = {}
send, reason = tick("500000", false)
assert(not send and reason == "skipped_idle", "normal threshold idle capture one must wait")
send, reason = tick("500000", false)
assert(send and reason == "sent" and sends == 4,
  "watch level compacts on the second idle capture")

state = {}
send, reason = tick("600000", false)
assert(send and reason == "sent" and sends == 5,
  "warn level compacts on the first idle capture")

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
assert(remuda._butler_compaction_yes_option(
  "Switch model?\n1. No\n❯ 2. Yes, switch to Sonnet") == "2",
  "the local option parser must retain the number from a highlighted Unicode option")
answer, phase = remuda._butler_compaction_visible_answer(
  "claude", "Switch model?\n1. No\n2. Keep current model", "sonnet")
assert(answer == nil and phase == "unknown", "dialog without a yes/switch label must be unknown")
answer, phase = remuda._butler_compaction_visible_answer(
  "claude", "MODEL:Sonnet-4.5 CTX:500000\n❯", "sonnet")
assert(answer == nil and phase == "ready", "already-switched statusline must advance without a stray key")
answer, phase = remuda._butler_compaction_visible_answer(
  "claude", "Mystery chooser\n1. Continue\n❯", "sonnet")
assert(answer == nil and phase == "unknown", "unrecognized dialog must be reported, never answered blindly")
assert(remuda._butler_compaction_is_unknown_dialog("Mystery chooser\n1. Continue\n❯"),
  "numbered option immediately above the prompt should be an active unknown dialog")
assert(remuda._butler_compaction_is_unknown_dialog("Mystery chooser\n❯ 1. Continue\n2. Cancel"),
  "a highlighted numbered option should identify an active modal")
assert(not remuda._butler_compaction_is_unknown_dialog(
  "Switch model?\n❯ 1. Yes, switch to Sonnet\n2. No"),
  "the known model switch dialog must remain in the switch handler")
assert(not remuda._butler_compaction_is_unknown_dialog("Earlier the dialog said press 1 to continue"),
  "transcript prose must not be mistaken for an active dialog")
assert(not remuda._butler_compaction_is_unknown_dialog(
  "1. Fix the modal dialog detection in the last 8 lines"),
  "dialog words in transcript text must not be mistaken for a modal")

local claude_sequence = remuda._butler_compaction_sequence("claude", "opus", "sonnet")
assert(table.concat(claude_sequence, "|") == "/model sonnet|/compact|/model opus",
  "Claude sequence must queue low model, compact, then restore prior model")
local codex_sequence = remuda._butler_compaction_sequence("codex", "gpt-5.6-terra", "sonnet")
assert(table.concat(codex_sequence, "|") == "/compact",
  "Codex sequence must submit compact exactly once without switching models")

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

-- Drive the lifecycle-owned schedule callback without arguments, as the core
-- scheduler does. The tick stub uses the real policy and records the Codex
-- compact command so this covers state closure, warn-level policy, and action.
local saved_bus, saved_telemetry = remuda._butler_bus, remuda._butler_telemetry_for
local saved_schedule, saved_cancel, saved_exec, saved_emit =
  remuda.schedule, remuda.cancel, remuda.exec, remuda.emit
local registered = {}
remuda.schedule = function(spec)
  registered[#registered + 1] = spec
  return spec
end
remuda.cancel = function() end
remuda.exec = function() end
remuda.emit = function() end
remuda._butler_bus = { agents = { codex_member = { kind = "codex" } }, pending_tasks = {}, notices = {} }
remuda._butler_telemetry_for = function()
  return { context_used = "600000" }
end
local scheduled_commands = {}
remuda.send = function(name, command)
  scheduled_commands[#scheduled_commands + 1] = { name = name, command = command }
end
remuda._butler_compaction_tick = function()
  local member_state = {}
  local should_send = remuda.butler.compaction_policy("codex_member", member_state)
  if should_send then remuda.send("codex_member", "/compact") end
end
local prior_mt = getmetatable(_G)
setmetatable(_G, { __index = { remuda = remuda } })
local lifecycle = dofile("packages/butler/init.lua")
setmetatable(_G, prior_mt)
local schedule_state = { compaction_enabled = true }
lifecycle.start(schedule_state)
local compaction_schedule
for _, spec in ipairs(lifecycle.schedules) do
  if spec.name == "butler-compaction" then compaction_schedule = spec end
end
assert(compaction_schedule, "init.lua must declare the compaction schedule")
compaction_schedule.run()
assert(#scheduled_commands == 1 and scheduled_commands[1].name == "codex_member"
  and scheduled_commands[1].command == "/compact",
  "one enabled lifecycle tick must compact an idle Codex member at warn level")
remuda._butler_bus, remuda._butler_telemetry_for = saved_bus, saved_telemetry
remuda.schedule, remuda.cancel, remuda.exec, remuda.emit =
  saved_schedule, saved_cancel, saved_exec, saved_emit
print("ok - Butler compaction context, idle gate, and lifecycle schedule")
