-- Unit tests for prepared owner-approved text. Run from the repository root:
--   luajit tests/butler_approve_text.lua
local request_spec, request_handler
remuda = { butler = { approval = {
  handler = function(kind, callbacks) assert(kind == "approve_text"); request_handler = callbacks end,
  request = function(spec) request_spec = spec; spec.on_id("ABCD"); return "request-handle" end,
  reply = function() return true end,
} } }
local approve_text = dofile("packages/butler/approve_text.lua")

local multiline = "first\nsecond\n"
local record = assert(approve_text.prepare("agent-1", multiline, "ABCD"))
assert(record.bytes == #multiline and record.registered_text == multiline,
  "registration must retain exact multiline bytes and byte count")
assert(record.display_fingerprint == "ABCD/" .. #multiline,
  "fingerprint must use the request id and byte count when SHA-256 is unavailable")
assert(approve_text.matches(record), "an unchanged registered copy must match")
record.registered_text = "changed"
assert(not approve_text.matches(record), "delivery must refuse text changed after posting")

local at_limit = string.rep("a", 8190) .. "\n\n"
local boundary = assert(approve_text.prepare("agent-1", at_limit, "WXYZ"))
assert(boundary.bytes == 8192, "8 KiB text is accepted by byte length")
local too_long, too_long_error = approve_text.prepare("agent-1", at_limit .. "a", "WXYZ")
assert(too_long == nil and too_long_error == "text_too_long", "text over 8 KiB is refused")
local empty, empty_error = approve_text.prepare("agent-1", "", "WXYZ")
assert(empty == nil and empty_error == "empty_text", "empty text is refused")

local displayed, escaped = approve_text.display("one\ntwo\t\1")
assert(displayed:find("> one\n> two\\t\\x01", 1, true), "display preserves lines and escapes controls")
assert(escaped == true, "display says when controls were escaped")

local typed, keys, traces = {}, {}, {}
remuda.type_text = function(session, bytes)
  typed[#typed + 1] = { session = session, bytes = bytes }
  return true
end
remuda.key = function(session, key)
  keys[#keys + 1] = { session = session, key = key }
  return true
end
remuda._butler_notify_policy = function() return true end
remuda._butler_session_trace = function(kind, detail) traces[#traces + 1] = { kind, detail } end
remuda._butler_bus = { pending_tasks = {} }
local provenance = { owner = "@alice:example.org", event_id = "$approved", request_id = "ABCD" }
local ok, reason = approve_text.type_text("agent-1", multiline, provenance)
assert(ok == true and reason == nil, "safe delivery succeeds")
assert(#typed == 1 and typed[1].session == "agent-1" and typed[1].bytes == multiline,
  "typing seam receives exact registered bytes")
assert(#keys == 1 and keys[1].key == "RET", "delivery submits the exact text")
assert(#traces == 1 and traces[1][2]:find("@alice:example.org", 1, true)
  and traces[1][2]:find("$approved", 1, true) and traces[1][2]:find("ABCD", 1, true),
  "trace records owner, approval event, and request id")

remuda._butler_bus.pending_tasks["agent-1"] = true
ok, reason = approve_text.type_text("agent-1", multiline, provenance)
assert(ok == false and reason == "pane_busy" and #typed == 1,
  "busy session refuses without typing")
remuda._butler_bus.pending_tasks["agent-1"] = nil
remuda._butler_notify_policy = function() return false end
ok, reason = approve_text.type_text("agent-1", multiline, provenance)
assert(ok == false and reason == "pane_busy" and #typed == 1,
  "unsafe composer, dialog, or attached human refuses without typing")

print("ok - prepared approved text cases")

local returned_id = approve_text.request("agent-1", multiline, "agent-1")
assert(returned_id == "ABCD", "registration returns the short request id")
assert(request_spec.kind == "approve_text" and request_spec.data.session == "agent-1"
  and request_spec.data.text == multiline and request_spec.data.posted_text == multiline,
  "request stores the exact bytes, session, and display copy")
assert(request_spec.rate_limit_per_window == 10 and request_spec.rate_window_s == 600,
  "registration rate is bounded per agent")
local posted = request_spec.render({ id = "ABCD", data = request_spec.data })
assert(posted:find("ABCD/" .. #multiline, 1, true) and posted:find("> first\n> second\n> ", 1, true),
  "posted request identifies its fingerprint and quotes every line")
local applied
remuda._butler_notify_policy = function() return true end
request_handler.approve({ id = "ABCD", data = request_spec.data,
  answered_by = "@alice:example.org", answer_event_id = "$owner-answer" },
  function(ok, why) applied = { ok, why } end)
assert(applied[1] == true, "approved request delivers the stored text")

local changed = { id = "ABCD", data = { session = "agent-1", bytes = #multiline,
  registered_text = "changed", posted_text = multiline, request_id = "ABCD" } }
request_handler.approve(changed, function(ok, why) applied = { ok, why } end)
assert(applied[1] == "retry" and applied[2] == "text_changed",
  "hash mismatch remains approved for retry without delivery")
