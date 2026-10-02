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
  if rec.key == "text-approved-deny" then done("retry", "pane_busy"); return end
  if rec.key == "text-crash" then
    assert(approval.begin_delivery(rec), "crash case must persist delivery marker")
    done(false, "type_text failed after partial write")
    return
  end
  attempts = attempts + 1
  if attempts == 1 then
    done("retry", "pane_busy")
  else
    assert(approval.begin_delivery(rec), "delivery marker must persist before text can be typed")
    done(false, "type_text failed after partial write")
  end
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
  and state.approvals[requested_id].status == "failed" and attempts == 2,
  "a partial write is terminally failed after the persisted one-shot marker")
local duplicate_ok = approval.answer("$approval", "approve", "@alice:example.org", "$answer-3")
assert(not duplicate_ok and attempts == 2 and state.approvals[requested_id].status == "failed",
  "a request that may have written is never retried")

local approved_id
approval.request({ kind = "approve_text", key = "text-approved-deny", asker = "agent-1",
  summary = "approved but waiting", data = {}, on_id = function(id) approved_id = id end }, function() end)
post_callback({ event_id = "$approval-deny" })
assert(approval.answer("$approval-deny", "approve", "@alice:example.org", "$yes"))
local prepared_rows = approval.cli({ "approvals" })
assert(prepared_rows:find("deny ID cancels prepared text", 1, true),
  "approval listing tells the operator how to cancel prepared text")
local terminal_approve_ok, terminal_approve_error = approval.answer("$approval-deny", "approve", "operator (terminal)")
assert(not terminal_approve_ok and terminal_approve_error:find("live Matrix thread", 1, true),
  "the local operator cannot approve prepared text")
local terminal_deny = approval.cli({ "deny", approved_id })
assert(terminal_deny:find("Denied request " .. approved_id, 1, true)
  and state.approvals[approved_id].status == "denied",
  "the local operator can cancel approved-but-undelivered prepared text")

local crash_id
approval.request({ kind = "approve_text", key = "text-crash", asker = "agent-1",
  summary = "crash recovery", data = { session_binding_version = 2 },
  on_id = function(id) crash_id = id end }, function() end)
post_callback({ event_id = "$approval-crash" })
assert(approval.answer("$approval-crash", "approve", "@alice:example.org", "$crash"))
assert(state.approvals[crash_id].status == "failed", "the partial write record is already failed")
state.approvals[crash_id].status = "approved"
state.approvals[crash_id].delivery_started = true
local recovery_posts, recovery_mails = {}, {}
remuda._butler_send = function(from, to, text)
  recovery_mails[#recovery_mails + 1] = { from = from, to = to, text = text }
  return true
end
approval.attach(state, function() saved = saved + 1; return true end,
  function(text, relation, callback)
    recovery_posts[#recovery_posts + 1] = { text = text, relation = relation }
    callback({ event_id = "$recovery-notice" })
    return true
  end)
assert(state.approvals[crash_id].status == "failed",
  "a restart fails closed when a persisted delivery marker has unknown outcome")
assert(#recovery_posts == 1 and recovery_posts[1].text:find("may not have been typed", 1, true)
  and recovery_posts[1].text:find("register it again", 1, true)
  and recovery_posts[1].relation.event_id == "$approval-crash",
  "restart recovery explains the uncertain outcome in the owner's request thread")
assert(#recovery_mails == 1 and recovery_mails[1].to == "agent-1"
  and recovery_mails[1].text:find("Register the text again", 1, true),
  "restart recovery sends one re-registration notice to the requesting agent")

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

local cap_state = { approvals = { approved_text = { id = "APPV", kind = "approve_text",
  status = "approved", asker = "agent-text" } } }
approval.attach(cap_state, function() return true end,
  function(text, _, callback) posted, post_callback = text, callback; return true end)
approval.handler("ordinary", { approve = function(_, done) done(true) end })
local function file_ordinary(key)
  local id
  approval.request({ kind = "ordinary", key = key, asker = "agent-ordinary-" .. key, summary = key,
    on_id = function(value) id = value end }, function() end)
  if id then post_callback({ event_id = "$" .. key }) end
  return id
end
for i = 1, 4 do assert(file_ordinary("cap-" .. i), "four pending requests fit beside approved text") end
assert(file_ordinary("cap-5"),
  "approved-but-undelivered prepared text does not count toward the five pending global cap")
print("ok - retryable approval storage cases")
