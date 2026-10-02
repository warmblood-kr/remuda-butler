-- Unit tests for prepared owner-approved text. Run from the repository root:
--   luajit tests/butler_approve_text.lua
local request_spec, request_handler
remuda = { butler = { approval = {
  handler = function(kind, callbacks) assert(kind == "approve_text"); request_handler = callbacks end,
  request = function(spec) request_spec = spec; spec.on_id("ABCD"); return "request-handle" end,
  reply = function() return true end,
  begin_delivery = function(rec) rec.delivery_started = true; return true end,
} } }
local approve_text = dofile("packages/butler/approve_text.lua")

local multiline = "first\nsecond\n"
local record = assert(approve_text.prepare("agent-1", multiline, "ABCD"))
assert(record.bytes == #multiline and record.registered_text == multiline,
  "registration must retain exact multiline bytes and byte count")
assert(record.display_fingerprint == "ABCD/" .. #multiline,
  "fingerprint must use the request id and byte count when SHA-256 is unavailable")
local at_limit = string.rep("a", 8190) .. "\n\n"
local boundary = assert(approve_text.prepare("agent-1", at_limit, "WXYZ"))
assert(boundary.bytes == 8192, "8 KiB text is accepted by byte length")
local too_long, too_long_error = approve_text.prepare("agent-1", at_limit .. "a", "WXYZ")
assert(too_long == nil and too_long_error == "text_too_long", "text over 8 KiB is refused")
local empty, empty_error = approve_text.prepare("agent-1", "", "WXYZ")
assert(empty == nil and empty_error == "empty_text", "empty text is refused")
local esc, esc_error = approve_text.prepare("agent-1", "safe\27[31m", "WXYZ")
assert(esc == nil and esc_error == "control_character", "ESC and other controls are refused before posting")
local crlf = assert(approve_text.prepare("agent-1", "one\r\ntwo\rthree", "WXYZ"))
assert(crlf.registered_text == "one\ntwo\nthree",
  "CR and CRLF normalize before storage and owner display")

local displayed, escaped = approve_text.display("one\ntwo\t\1")
assert(displayed:find("> one\n> two\\t\\x01", 1, true), "display preserves lines and escapes controls")
assert(escaped == true, "display says when controls were escaped")
local unicode_display = approve_text.display("x\226\128\168y\226\128\174z\194\133")
assert(unicode_display:find("\\u2028", 1, true) and unicode_display:find("\\u202E", 1, true)
  and unicode_display:find("\\u0085", 1, true), "display escapes separators, bidi controls and C1 controls")

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
remuda.ls = function() return { { name = "agent-1", alive = true, attached = false } } end
remuda.session = function() return { attached = false } end
remuda._butler_matrix_live_config = { approve_text = true }
remuda._butler_bus = { pending_tasks = {}, agents = {
  butler = { id = "butler", session_start_marker = "root-start" },
  agent1 = { id = "agent1", session_start_marker = "agent-start", session_name = "agent-1", parent = "butler" },
} }
local provenance = { owner = "@alice:example.org", event_id = "$approved", request_id = "ABCD" }
local ok, reason = approve_text.type_text("agent-1", multiline, provenance)
assert(ok == true and reason == nil, "safe delivery succeeds")
assert(#typed == 1 and typed[1].session == "agent-1" and typed[1].bytes == multiline,
  "typing seam receives exact registered bytes")
assert(#keys == 0, "type_text performs submission; delivery must not send a second Return")
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
  "an unsafe composer or dialog refuses without typing")
remuda._butler_notify_policy = function() return true end
remuda.ls = function() return { { name = "agent-1", alive = true, attached = true } } end
ok, reason = approve_text.type_text("agent-1", multiline, provenance)
assert(ok == false and reason == "human_attached" and #typed == 1,
  "an attached human pane refuses without typing")
remuda.ls = function() return { { name = "agent-1", alive = true, attached = false } } end

local returned_id = approve_text.request("agent-1", multiline, "agent-1")
assert(returned_id == "ABCD", "registration returns the short request id")
assert(request_spec.kind == "approve_text" and request_spec.data.session == "agent-1"
  and request_spec.data.registered_text == multiline and request_spec.data.bytes == #multiline
  and request_spec.data.session_id == "agent1" and request_spec.data.session_marker == "agent-start"
  and request_spec.data.session_binding_version == 2
  and request_spec.data.session_start == nil and request_spec.data.session_start_marker == nil,
  "request stores text once and binds to a non-secret session launch marker")
assert(request_spec.rate_limit_per_window == 10 and request_spec.rate_window_s == 600,
  "registration rate is bounded per agent")
local posted = request_spec.render({ id = "ABCD", data = request_spec.data,
  expires_at = os.time() * 1000 + 60000 })
assert(posted:find("ABCD/" .. #multiline, 1, true) and posted:find("> first\n> second\n> ", 1, true)
  and posted:find("Expires ", 1, true) and posted:find("React ✅", 1, true),
  "posted request identifies its fingerprint, expiry, answer methods, and quoted lines")
local applied
remuda._butler_notify_policy = function() return true end
request_handler.approve({ id = "ABCD", data = request_spec.data,
  answered_by = "@alice:example.org", answer_event_id = "$owner-answer" },
  function(ok, why) applied = { ok, why } end)
assert(applied[1] == true, "approved request delivers the stored text")

local saved_marker = remuda._butler_bus.agents.agent1.session_start_marker
remuda._butler_bus.agents.agent1.session_start_marker = "new-start"
local relaunch_result
request_handler.approve({ id = "ABCD", data = request_spec.data },
  function(ok, why) relaunch_result = { ok, why } end)
assert(relaunch_result[1] == "retry" and relaunch_result[2] == "session_changed" and #typed == 2,
  "a relaunch under the same name cannot receive a registered request")
remuda._butler_bus.agents.agent1.session_start_marker = saved_marker

local changed = { id = "ABCD", data = { session = "agent-1", bytes = #multiline - 1,
  registered_text = string.rep("x", #multiline), request_id = "ABCD" } }
request_handler.approve(changed, function(ok, why) applied = { ok, why } end)
assert(applied[1] == false and applied[2] == "text_changed",
  "text mismatch fails closed without delivery")

local cli_result = approve_text.cli({ "request", "agent-1", "-" }, "agent-1", multiline)
assert(cli_result == "Registered prepared text request ABCD",
  "CLI registers stdin bytes for a Butler session and returns the short id")
local invalid_target, invalid_error = approve_text.cli({ "request", "outside", "-" }, "agent-1", multiline)
local invalid_message = type(invalid_target) == "table" and invalid_target.error or invalid_error
assert(invalid_message and invalid_message:find("Unknown Butler session", 1, true),
  "registration cannot target a session outside the Butler tree")
remuda._butler_matrix_live_config.approve_text = false
local prior_spec = request_spec
local disabled, disabled_error = approve_text.cli({ "request", "agent-1", "-" }, "agent-1", multiline)
local disabled_message = type(disabled) == "table" and disabled.error or disabled_error
assert(disabled_message and disabled_message:find("Prepared text approvals are off", 1, true)
  and request_spec == prior_spec, "switch-off registration is refused before posting")
remuda._butler_matrix_live_config.approve_text = true

assert(approve_text.reply_verdict("yes") == "approve")
local verdict, reply_id = approve_text.reply_verdict("승인 abcd")
assert(verdict == "approve" and reply_id == "ABCD", "Korean reply supports the optional request id")
assert(approve_text.reply_verdict("승인") == "approve" and approve_text.reply_verdict("거부") == "deny"
  and approve_text.reply_verdict("거부 ABCD") == "deny" and approve_text.reply_verdict("maybe") == nil,
  "deny words are exact and other replies are not approvals")
local owner_cfg = { home_room = "!home:example.org", self_mxid = "@bot:example.org",
  allowed_senders = { ["@alice:example.org"] = true, ["@agent-runner:example.org"] = true },
  butler_senders = {} }
local owner_event = { type = "m.room.message", event_id = "$owner", sender = "@alice:example.org", origin_server_ts = 1000100 }
local owner_record = { created_ms = 1000000 }
assert(approve_text.owner_event_allowed(owner_event, owner_record, owner_cfg, true, owner_cfg.home_room),
  "allowlisted owner answer from live HOME sync is accepted")
assert(not approve_text.owner_event_allowed(owner_event, owner_record, owner_cfg, false, owner_cfg.home_room),
  "backfill and mail events cannot approve")
local agent_event = { type = "m.room.message", event_id = "$agent", sender = "@agent-runner:example.org", origin_server_ts = 1000100 }
assert(not approve_text.owner_event_allowed(agent_event, owner_record, owner_cfg, true, owner_cfg.home_room),
  "an agent MXID cannot approve")
local stranger_event = { type = "m.room.message", event_id = "$stranger",
  sender = "@mallory:example.org", origin_server_ts = 1000100 }
assert(not approve_text.owner_event_allowed(stranger_event, owner_record, owner_cfg, true, owner_cfg.home_room),
  "a non-allowlisted sender cannot approve")
assert(not approve_text.owner_event_allowed(owner_event, owner_record, owner_cfg, true, "!other:example.org"),
  "answers outside HOME cannot approve")
local edited = { type = "m.room.message", event_id = "$edited", sender = owner_event.sender,
  origin_server_ts = owner_event.origin_server_ts, content = { ["m.new_content"] = { body = "yes" } } }
assert(not approve_text.owner_event_allowed(edited, owner_record, owner_cfg, true, owner_cfg.home_room),
  "edited Matrix events cannot approve")
remuda._butler_matrix_live_config.use_messages = true
local prior_spec = request_spec
local message_mode_id, message_mode_error = approve_text.request("agent-1", multiline, "agent-1")
assert(message_mode_id == nil and message_mode_error:find("require live Matrix sync", 1, true)
  and request_spec == prior_spec,
  "registration is refused when messages fallback cannot deliver live approvals")
remuda._butler_matrix_live_config.use_messages = false
print("ok - prepared approved text cases")
