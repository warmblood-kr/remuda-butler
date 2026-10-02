-- Focused approval storage tests. Run from the repository root:
--   luajit tests/butler_approval_retry.lua
local random_call = 0
remuda = { json = { null = {}, object = function(value) return value end },
  butler = { matrix = { sanitize_directory_text = function(value) return value end } },
  random_bytes = function(n) random_call = random_call + 1; return string.rep(string.char(96 + random_call), n) end }
local approval = dofile("packages/butler/approval.lua")
local state, saved, posted, post_callback = { approvals = {} }, 0
local posts = {}
approval.attach(state, function() saved = saved + 1; return true end,
  function(text, _, callback) posted, post_callback = text, callback; return true end)
local attempts = 0
approval.handler("approve_text", { approve = function(rec, done)
  attempts = attempts + 1
  if attempts == 1 then done("retry", "pane_busy") else done(true) end
end })
local requested_id
local handle = approval.request({ kind = "approve_text", key = "text-1", asker = "agent-1",
  summary = "prepared text", data = { text = "exact" }, ttl_s = 100,
  on_id = function(id) requested_id = id end,
  rate_limit_per_window = 10, rate_window_s = 600,
  render = function(rec) return "posted " .. rec.id end,
}, function(id) assert(id == requested_id) end)
assert(requested_id and handle, "request exposes its short id before the async post completes")
assert(posted == "posted " .. requested_id, "request renderer receives its generated id")
post_callback({ event_id = "$approval" })
assert(state.approvals[requested_id].event_id == "$approval" and saved > 0,
  "posted approval is persisted with its event")
local terminal_ok, terminal_why = approval.answer(requested_id, "approve", "operator (terminal)")
assert(not terminal_ok and terminal_why:find("live Matrix thread", 1, true),
  "terminal verbs cannot approve prepared text")
local answered = approval.answer("$approval", "approve", "@alice:example.org", "$answer-1")
assert(answered and state.approvals[requested_id].status == "approved"
  and state.approvals[requested_id].answer_event_id == "$answer-1",
  "retryable delivery remains approved and records owner event provenance")
assert(approval.reapply_approved() == 0 and attempts == 1,
  "restart recovery never triggers prepared text delivery")
assert(approval.answer("$approval", "approve", "@alice:example.org", "$answer-2")
  and state.approvals[requested_id].status == "applied" and attempts == 2,
  "a later owner approval event retries approved-but-undelivered text")
local duplicate_ok = approval.answer("$approval", "approve", "@alice:example.org", "$answer-3")
assert(not duplicate_ok and attempts == 2 and state.approvals[requested_id].status == "applied",
  "a delivered request is one-shot")

local second_id
approval.request({ kind = "approve_text", key = "text-2", asker = "agent-1",
  summary = "second", data = {}, rate_limit_per_window = 10, rate_window_s = 600,
  on_id = function(id) second_id = id end }, function() end)
post_callback({ event_id = "$approval-2" })
assert(second_id and state.approvals[second_id], "request registration remains persistent")
local rate_error
approval.request({ kind = "approve_text", key = "text-3", asker = "agent-1",
  summary = "third", data = {}, rate_limit_per_window = 2, rate_window_s = 600,
  on_id = function() error("rate-limited request must not get an id") end },
  function(id, why) assert(id == nil); rate_error = why end)
assert(rate_error and rate_error:find("Too many prepared text registrations", 1, true),
  "registration limit counts recent requests per agent")
print("ok - retryable approval storage cases")
