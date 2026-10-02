-- Run from the repository root: luajit tests/butler_sessions_notice.lua
local bus = { agents = {
  butler = { kind = "claude" },
  lead = { kind = "codex", parent = "butler" },
}, notices = { lead = { count = 1, retry_at = 200 } }, pending_tasks = {}, task_poke_failures = {},
  notice_delivery_failures = {} }
remuda = {
  _butler_sessions_config = { bus = bus, mail = {}, json_field = function() end },
  _butler_attempts = {},
}
dofile("packages/butler/sessions.lua")
local sessions = remuda._butler_sessions()
assert(sessions:find("SESSION\tAGENT\tLEADER\tNOTICE", 1, true), sessions)
assert(sessions:find("butler\tclaude\t-\t-", 1, true), sessions)
assert(sessions:find("lead\tcodex\tbutler\tqueued", 1, true), sessions)
bus.notices.lead = nil
bus.notice_delivery_failures.lead = { message_ids = { "m1" }, reason = "submit" }
sessions = remuda._butler_sessions()
assert(sessions:find("lead\tcodex\tbutler\tnotice failed", 1, true), sessions)
bus.notice_delivery_failures.lead = nil
bus.pending_tasks.lead = "task text"
sessions = remuda._butler_sessions()
assert(sessions:find("lead\tcodex\tbutler\ttask queued", 1, true), sessions)
bus.pending_tasks.lead = nil
bus.task_poke_failures.lead = { reason = "submit" }
sessions = remuda._butler_sessions()
assert(sessions:find("lead\tcodex\tbutler\ttask failed", 1, true), sessions)
bus.task_poke_failures.lead = nil
sessions = remuda._butler_sessions()
assert(sessions:find("lead\tcodex\tbutler\t-", 1, true), sessions)
print("ok - queued notices appear in sessions")
