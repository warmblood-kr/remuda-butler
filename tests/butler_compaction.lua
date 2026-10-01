-- Run from the repo root: luajit tests/butler_compaction.lua
-- Exercise the scheduled tick's shared compaction gate without a daemon.
local used, used_pct, busy, composer_empty, session_failure, attached, queued, mail_lookup_error =
  "?", nil, false, true, false, false, false, false
local screen = "mock idle screen"
remuda = {
  _butler_test_mode = true,
  _butler_compaction_config = {
    watch = 400000, warn = 600000, critical = 800000, critical_pct = 90,
    capture_gap = 3, cooldown_ticks = 2,
  },
  _butler_bus = { agents = { butler = { id = "butler", kind = "claude" } } },
  _butler_telemetry_for = function() return { context_used = used, context_pct = used_pct } end,
  session = function()
    if session_failure then error("session is no longer alive") end
    return { is_busy = busy, attached = attached }
  end,
  ls = function() return { { name = "butler", alive = true, attached = attached } } end,
  _butler_mail = { unread = function()
    if mail_lookup_error then error("mail read failed") end
    return queued and 1 or 0
  end },
  capture = function() return screen end,
  -- main.lua loads its modules with exec; resolve them the way the daemon does.
  exec = function(name) return dofile("packages/butler/" .. name:gsub("^butler/", "") .. ".lua") end,
}
dofile("packages/butler/main.lua")
-- Test mode returns before the daemon loads compaction_run.lua, so load that
-- module with the same pure helper dependencies for its exported dialog tests.
local compaction_module = remuda._butler_compaction
remuda._butler_compaction_run_config = {
  _butler_trace = function() end,
  registered_agent_kind = function() end,
  registered_agent_working = function() end,
  compaction_config = compaction_module.compaction_config,
  compaction_mail_defers = compaction_module.compaction_mail_defers,
  compaction_mail_alert = compaction_module.compaction_mail_alert,
  bottom_screen_lines = compaction_module.bottom_screen_lines,
  unknown_dialog_signature = compaction_module.unknown_dialog_signature,
  read_claude_settings = compaction_module.read_claude_settings,
  statusline_model_matches = compaction_module.statusline_model_matches,
  clear_legacy_restore_state = compaction_module.clear_legacy_restore_state,
}
dofile("packages/butler/compaction_run.lua")
used = "500000"
assert(type(remuda.butler) == "table", "composable compaction API must be exported")
local level = remuda.butler.ctx_level("butler")
assert(level.level == "watch" and level.used == 500000,
  "ctx_level must classify threshold context and retain usage")
remuda._butler_prompt_is_empty = function() return "EMPTY" end
remuda._butler_bus.agents.butler.native_autocompact = true
local native_skip, native_reason = remuda.butler.compaction_policy("butler", {})
assert(not native_skip and native_reason == "skipped_idle",
  "native autocompact must remain a safety net while the scheduler stays primary")
remuda._butler_bus.agents.butler.native_autocompact = nil
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
composer_empty = false
preflight = remuda._butler_compaction_preflight("butler")
assert(preflight == "composer not empty", "direct compaction must not append to a draft")
composer_empty = true
preflight = remuda._butler_compaction_preflight("butler")
assert(preflight == nil, "empty composer should pass direct compaction preflight")

local cooldown_state = { failure_cooldown_until = 200 }
local active, expires_at = remuda._butler_compaction_failure_cooldown(cooldown_state, 199)
assert(active and expires_at == 200, "failure cooldown should use a wall-clock expiry")
active = remuda._butler_compaction_failure_cooldown(cooldown_state, 199, true)
assert(not active and cooldown_state.failure_cooldown_until == nil,
  "force should clear and bypass the failure cooldown")
cooldown_state.failure_cooldown_until = 200
active = remuda._butler_compaction_failure_cooldown(cooldown_state, 200)
assert(not active and cooldown_state.failure_cooldown_until == nil,
  "failure cooldown should expire without a scheduled tick")
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

-- Unread mail may defer compaction, but the bound and critical threshold must
-- keep unread or unreadable mail from preventing compaction forever.
local saved_compact, saved_butler_send = remuda.butler.compact, remuda._butler_send
local compacted, parent_alerts = 0, 0
remuda.butler.compact = function() compacted = compacted + 1; return "sent" end
remuda._butler_send = function(_, recipient, message)
  if recipient == "parent" and message:find("unread Butler mail", 1, true) then
    parent_alerts = parent_alerts + 1
  end
end
remuda._butler_bus.agents.butler.parent = "parent"
queued, mail_lookup_error, used, used_pct, busy, attached, composer_empty =
  true, true, "600000", nil, false, false, true
fake_now = 1000
local mail_state = {}
local function run_mail_policy()
  local should_compact, event = remuda.butler.compaction_policy("butler", mail_state)
  if should_compact then remuda.butler.compact("butler") end
  return should_compact, event
end
local first_mail_should_compact, first_mail_event = run_mail_policy()
assert(not first_mail_should_compact and first_mail_event == "skipped_queued" and compacted == 0,
  "mail lookup errors should initially defer compaction")
assert(parent_alerts == 0, "mail deferral should not alert before compaction is allowed")
fake_now = fake_now + 601
local expired_mail_should_compact, expired_mail_event = run_mail_policy()
assert(expired_mail_should_compact and expired_mail_event == "sent" and compacted == 1 and parent_alerts == 1,
  "mail lookup errors must not defer beyond the bound; compact and alert parent once")
fake_now = fake_now + 3
run_mail_policy()
assert(parent_alerts == 1, "an expired mail deferral should alert the parent only once")

compacted, parent_alerts = 0, 0
mail_state = {}
mail_lookup_error, used, used_pct = false, "800000", nil
local critical_mail_should_compact, critical_mail_event = run_mail_policy()
assert(critical_mail_should_compact and critical_mail_event == "sent" and compacted == 1 and parent_alerts == 1,
  "critical context must compact despite unread mail and alert the parent once")
queued, mail_lookup_error = false, false
remuda._butler_bus.agents.butler.parent = nil
remuda.butler.compact, remuda._butler_send = saved_compact, saved_butler_send

local function read_fixture(name)
  local file = assert(io.open("tests/fixtures/" .. name, "r"))
  local contents = file:read("*a")
  file:close()
  return contents
end
assert(remuda._butler_model_confirm_signature(read_fixture("claude-model-confirm-dialog.txt")) ~= nil,
  "model confirmation signature should recognize the dialog fixture")
assert(remuda._butler_model_confirm_signature(read_fixture("claude-model-confirm-dialog-with-status.txt")) ~= nil,
  "model confirmation signature should recognize the dialog with status fixture")
assert(remuda._butler_model_confirm_signature(read_fixture("claude-model-confirm-dialog-changing-status.txt")) ~= nil,
  "model confirmation signature should recognize the dialog with changing status fixture")
assert(remuda._butler_model_confirm_signature(read_fixture("claude-model-confirm-wrong-title.txt")) == nil,
  "model confirmation signature should reject a wrong title")
assert(remuda._butler_model_confirm_signature(read_fixture("claude-stale-model-confirm-with-permission.txt")) == nil,
  "model confirmation signature should reject a stale model confirmation")
assert(remuda._butler_model_confirm_signature(
  read_fixture("claude-model-confirm-composer-one-row-status.txt")) ~= nil,
  "model confirmation signature should recognize the composer dialog with one status row")
assert(remuda._butler_model_confirm_signature(
  read_fixture("claude-model-confirm-composer-two-row-status.txt")) ~= nil,
  "model confirmation signature should recognize the composer dialog with two status rows")
assert(remuda._butler_model_confirm_signature(
  read_fixture("claude-model-confirm-multiline-draft.txt")) == nil,
  "model confirmation signature should reject a multiline composer draft")
local transcript_copy = read_fixture("claude-model-confirm-transcript-copy.txt")
assert(remuda._butler_model_confirm_signature(transcript_copy) == nil
  and not remuda._butler_model_confirm_options_visible(transcript_copy),
  "model confirmation helpers should reject a transcript copy above the composer")
local model_dialog_fixture = read_fixture("claude-model-confirm-composer-two-row-status.txt")
assert(remuda._butler_model_dialog_waiting(model_dialog_fixture),
  "model dialog waiting helper should detect a Switch model dialog")
local dialog_timeout_reason = remuda._butler_model_timeout_reason(
  "model-restored", "s1", model_dialog_fixture)
assert(dialog_timeout_reason:find("appears to be waiting in s1", 1, true)
  and dialog_timeout_reason:find("Next:", 1, true),
  "model timeout reason should explain that the dialog is waiting and how to handle it")
local plain_screen = "ordinary assistant response"
assert(not remuda._butler_model_dialog_waiting(plain_screen)
  and remuda._butler_model_timeout_reason("model-restored", "s1", plain_screen)
    == "timed out waiting for model-restored",
  "model timeout reason should preserve the ordinary timeout without a dialog")
local untitled_model_confirm = "❯ 1. Yes, switch to Opus 5.5\n  2. No, go back"
assert(remuda._butler_model_confirm_signature(untitled_model_confirm) == nil
  and remuda._butler_model_confirm_options_visible(untitled_model_confirm),
  "model confirmation options should remain visible while the title is half-painted")

assert(remuda._butler_compaction_is_unknown_dialog("Mystery chooser\n1. Continue\n❯"),
  "numbered option immediately above the prompt should be an active unknown dialog")
assert(remuda._butler_compaction_is_unknown_dialog("Mystery chooser\n❯ 1. Continue\n2. Cancel"),
  "a highlighted numbered option should identify an active modal")
assert(not remuda._butler_compaction_is_unknown_dialog("Earlier the dialog said press 1 to continue"),
  "transcript prose must not be mistaken for an active dialog")
assert(not remuda._butler_compaction_is_unknown_dialog(
  "1. Fix the modal dialog detection in the last 8 lines"),
  "dialog words in transcript text must not be mistaken for a modal")

local claude_sequence = remuda._butler_compaction_sequence()
assert(remuda._butler_compaction_valid_model("opus"), "opus is an allowed model")
assert(remuda._butler_compaction_valid_model("claude-opus-4-7[1m]"), "Claude model ids with the 1m suffix are allowed")
assert(not remuda._butler_compaction_valid_model("opus; /compact"), "model strings must not permit command injection")
assert(not remuda._butler_compaction_valid_model("claude-opus-4-7[1m]x"), "only the optional 1m suffix is accepted")
assert(remuda._butler_compaction_statusline_model_matches("Opus", "claude-opus-4-7"),
  "statusline matching should find the model family anywhere in the expected id")
assert(table.concat(remuda._butler_compaction_sequence("opus"), "|")
  == "/model sonnet|/compact|/model opus",
  "Claude compaction should use sonnet, compact, then restore the prior model")
local settings_after_model = { model = "sonnet", theme = "dark" }
local matches_model, actual_model, verify_status = remuda._butler_compaction_verify_settings_model(settings_after_model, "opus")
assert(matches_model == false and actual_model == "sonnet" and verify_status == nil
  and settings_after_model.model == "sonnet" and settings_after_model.theme == "dark",
  "settings.json verification reports a mismatch without changing the decoded settings")
local missing_model_match, missing_model_actual, missing_model_status =
  remuda._butler_compaction_verify_settings_model({ theme = "dark" }, "opus")
assert(missing_model_match == nil and missing_model_actual == nil and missing_model_status == "model_missing",
  "a missing settings.json model key is unverified rather than a mismatch")
local unavailable_match, unavailable_actual, unavailable_status =
  remuda._butler_compaction_verify_settings_model(nil, "opus")
assert(unavailable_match == nil and unavailable_actual == nil and unavailable_status == "unavailable",
  "missing or invalid settings.json is unverified rather than a mismatch")
local codex_sequence = remuda._butler_compaction_sequence()
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
remuda._butler_bus = { agents = {
  codex_member = { kind = "codex" },
  claude_member = { kind = "claude", native_autocompact = true },
}, pending_tasks = {}, notices = {} }
remuda._butler_telemetry_for = function()
  return { context_used = "600000" }
end
local scheduled_commands = {}
remuda.send = function(name, command)
  scheduled_commands[#scheduled_commands + 1] = { name = name, command = command }
end
remuda._butler_compaction_tick = function()
  for _, name in ipairs({ "claude_member", "codex_member" }) do
    local member_state = {}
    local should_send = remuda.butler.compaction_policy(name, member_state)
    if should_send then remuda.send(name, "/compact") end
  end
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
assert(#scheduled_commands == 2 and scheduled_commands[1].name == "claude_member"
  and scheduled_commands[1].command == "/compact"
  and scheduled_commands[2].name == "codex_member"
  and scheduled_commands[2].command == "/compact",
  "one enabled lifecycle tick must keep scheduled compaction primary for Claude and Codex")
remuda._butler_bus, remuda._butler_telemetry_for = saved_bus, saved_telemetry
remuda.schedule, remuda.cancel, remuda.exec, remuda.emit =
  saved_schedule, saved_cancel, saved_exec, saved_emit
print("ok - Butler compaction context, idle gate, and lifecycle schedule")
