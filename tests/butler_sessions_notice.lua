-- Run from the repository root: luajit tests/butler_sessions_notice.lua
local bus = { agents = {
  butler = { kind = "claude" },
  lead = { kind = "codex", parent = "butler" },
}, notices = { lead = { count = 1, retry_at = 200 } } }
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
sessions = remuda._butler_sessions()
assert(sessions:find("lead\tcodex\tbutler\t-", 1, true), sessions)
print("ok - queued notices appear in sessions")
