-- Run from the repository root: luajit tests/butler_notice_native.lua
-- Native OpenCode notice dispatch: canonical text, one helper call, typed
-- outcomes, sticky disabled and no PTY fallback. Injected runner/JSON/journal.
local now = 2000
local trace = {}
_butler_session_trace = function(event, detail) trace[#trace + 1] = { event = event, detail = detail } end
local function literal(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = literal(item) end
    local keys = {}
    for key in pairs(value) do if type(key) ~= "number" then keys[#keys + 1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("[%q]=%s", key, literal(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end
local codec = {
  encode = literal,
  decode = function(text) return assert(loadstring("return " .. text))() end,
  array = function(value) return value end,
  object = function(value) return value end,
}

local bus = { agents = {}, notices = {}, pending_tasks = {}, messages = {}, objects = {},
  mail_delivered = {}, codex_update_relaunches = {}, codex_update_state = {},
  notice_timers = {}, notice_seen = {}, unread_seeded = {}, notice_retry_reasons = {},
  notice_fallbacks = {}, notice_failure_alerts = {}, notice_uncertain_alerts = {},
  notice_sent_at = {}, notice_reminder_at = {}, notice_stuck = {},
  notice_journal_alerts = {}, notice_journal_failure_alerts = {}, notice_native_alerts = {} }
local unread = { n1 = true, n2 = true }
local mail = {
  mailbox = function() return {} end,
  is_unread = function(_, id) return unread[id] == true end,
  unread = function() return 1 end,
  find_message = function(id) return { id = id, from = { alias = "alice", id = "alice-id" } } end,
}
local alerts, spawns, pty_sends = {}, {}, 0
local rows = { { name = "lead", alive = true, attached = false, id = "ses_abc",
  instance_id = "instance-1" } }
remuda = {
  _butler_notice_config = { bus = bus, resolve = function(name) return name end,
    mail_address = function(name) return { alias = name, id = name } end,
    mail_id = function(name) return name, { alias = name, id = name, kind = "opencode" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = { opencode = { placeholders = {} } },
  _butler_notice_clock = function() return now end,
  _butler_session_trace = _butler_session_trace,
  json = codec,
  ls = function() return rows end,
  capture = function() error("native delivery must not read the screen") end,
  send = function() pty_sends = pty_sends + 1; error("native delivery must never use the PTY") end,
}
dofile("tests/notice_journal_stub.lua")
dofile("packages/butler/native_dispatch.lua")
dofile("packages/butler/native_launch.lua")
dofile("packages/butler/notice.lua")
remuda._butler_send = function(_, to, body)
  if to == "alice" then alerts[#alerts + 1] = body end
end
local N = remuda._butler_notice

local on_begin, on_ls, on_retire
local function reset()
  now = 2000
  bus.agents = { lead = { id = "lead-id", kind = "opencode", parent = "root",
    instance_id = "instance-1", native = { mode = "native",
      path = "/data/remuda/butler/bindings/lead/" .. string.rep("a", 32) .. "/manifest.json",
      nonce = string.rep("a", 32), row_id = "ses_abc", instance = "instance-1" } } }
  bus.notices, bus.notice_stuck, bus.notice_recovery = {}, {}, nil
  bus.notice_native_alerts = {}
  rows = { { name = "lead", alive = true, attached = false, id = "ses_abc",
    instance_id = "instance-1" } }
  remuda.ls = function()
    if on_ls then local hook = on_ls; on_ls = nil; hook() end
    return rows
  end
  unread = { n1 = true, n2 = true }
  alerts, spawns, pty_sends = {}, {}, 0
  on_ls, on_retire = nil, nil
  local files = remuda._butler_notice_test_journal.files
  for key in pairs(files) do files[key] = nil end
  local journal = remuda._butler_notice_test_journal.new()
  local begin = journal.begin
  journal.begin = function(record)
    local entry, err = begin(record)
    if on_begin then local hook = on_begin; on_begin = nil; hook() end
    return entry, err
  end
  local retire = journal.retire
  journal.retire = function(...)
    local result, err = retire(...)
    if on_retire then local hook = on_retire; on_retire = nil; hook() end
    return result, err
  end
  remuda._butler_delivery_journal = journal
end
local function queue(ids)
  ids = ids or { "n1" }
  local order, notices = {}, {}
  for _, id in ipairs(ids) do order[#order + 1] = id; notices[id] = "notice " .. id end
  bus.notices.lead = { count = #ids, message_order = order, message_ids = notices,
    text = notices[order[#order]], kind = "opencode", due_at = now }
end
local function respond(value, timeout)
  remuda.process = { run = function(spec)
    spawns[#spawns + 1] = spec
    if timeout then return { code = 0, timed_out = true, stdout = "" } end
    return { code = 0, stdout = codec.encode(value), stderr = "" }
  end }
end

-- 1. Accepted: one exact helper call with canonical text and stdin JSON.
reset()
queue()
respond({ outcome = "accepted_queue" })
assert(N.deliver_notice("lead") == true, "accepted native delivery completes")
assert(#spawns == 1, "one helper invocation")
local spec = spawns[1]
assert(spec.argv[1] == "remuda" and spec.argv[2] == "_agent_notice" and #spec.argv == 2,
  "exact helper argv")
assert(spec.timeout == 15, "modest helper timeout")
local sent = codec.decode(spec.stdin)
assert(sent.text == "Butler message n1 arrived. Read it: MCP butler_inbox (or remuda butler inbox)",
  "canonical single pointer text")
assert(sent.session == "ses_abc" and sent.instance == "instance-1"
  and sent.binding == bus.agents.lead.native.path and sent.nonce == bus.agents.lead.native.nonce,
  "request carries the bound target")
assert(sent.request_id:match("^msg_n1_%d+$"), "request id is frozen per dispatch")
assert(bus.notices.lead == nil, "accepted delivery clears the queue")
assert(remuda._butler_delivery_journal.state_of("lead-id", "n1") == "accepted_unread",
  "native acceptance is accepted_unread until the canonical read")

-- 2. Multi-ID: one request, canonical count text.
reset()
queue({ "n1", "n2" })
respond({ outcome = "accepted_queue" })
assert(N.deliver_notice("lead") == true, "multi-id native delivery completes")
assert(#spawns == 1, "one request for the whole batch")
local multi = codec.decode(spawns[1].stdin)
assert(multi.text == "2 new Butler messages arrived. Read them: MCP butler_inbox (or remuda butler inbox)",
  "canonical multi text")
assert(#multi.message_ids == 2, "both ids in one request")

-- 3. Dead binding: disabled sticky, alert once, no PTY, queue kept.
reset()
queue()
respond({ outcome = "definitely_not_written", reason = "server_identity" })
assert(N.deliver_notice("lead") == false, "dead binding defers")
assert(bus.agents.lead.native.mode == "disabled", "dead binding disables the session")
assert(#alerts == 1 and alerts[1]:find("No PTY fallback", 1, true), "explicit disabled alert")
assert(bus.notices.lead ~= nil, "mail stays queued")
local before = #spawns
assert(N.deliver_notice("lead") == false and #spawns == before,
  "a disabled session spawns no further helper")
assert(#alerts == 1, "the disabled alert is not repeated")

-- 3a. A disappeared target row is dead, not the generic "session not live"
-- retry: sticky disabled and no helper call.
reset()
queue()
respond({ outcome = "accepted_queue" })
rows = {}
assert(N.deliver_notice("lead") == false, "a missing target row defers")
assert(#spawns == 0 and pty_sends == 0, "no helper and no PTY for a missing target")
assert(bus.agents.lead.native.mode == "disabled", "a missing target disables the binding")
assert(#alerts == 1 and alerts[1]:find("No PTY fallback", 1, true),
  "the missing target is reported explicitly")

-- 3b. A dead result must not disable a replacement agent that appeared while
-- the reservation release yielded.
reset()
queue()
respond({ outcome = "definitely_not_written", reason = "server_identity" })
on_retire = function()
  bus.agents.lead = { id = "lead-id", kind = "opencode", parent = "root",
    instance_id = "instance-1", native = { mode = "native",
      path = "/data/remuda/butler/bindings/lead/" .. string.rep("c", 32) .. "/manifest.json",
      nonce = string.rep("c", 32), row_id = "ses_abc", instance = "instance-1" } }
end
assert(N.deliver_notice("lead") == false, "a dead binding defers")
assert(bus.agents.lead.native.mode == "native",
  "a replacement agent keeps its own native binding")
assert(#spawns == 1 and pty_sends == 0, "no replay and no PTY")
assert(#alerts == 0, "no false disabled alert for a replacement agent")

-- 4. Uncertain outcome: journal uncertain, no retry, no PTY.
reset()
queue()
respond({ outcome = "uncertain", reason = "transport" })
assert(N.deliver_notice("lead") == false, "uncertain native outcome stops")
assert(remuda._butler_delivery_journal.state_of("lead-id", "n1") == "uncertain",
  "the attempt is durably uncertain")
assert(#spawns == 1 and bus.notices.lead == nil, "no retry now")
assert(bus.agents.lead.native.mode == "native", "uncertainty does not disable the binding")

-- 5. A proven pre-write refusal on a LIVE binding releases the reservation
-- and uses the bounded retry schedule; it never disables or falls back to PTY.
reset()
queue()
respond({ outcome = "definitely_not_written", reason = "invalid_args" })
assert(N.deliver_notice("lead") == false, "invalid request fails")
assert(bus.agents.lead.native.mode == "native", "invalid request does not disable")
assert(bus.notices.lead and bus.notices.lead.delivery_attempts == 1
  and bus.notices.lead.last_delivery_error:find("native_not_written", 1, true),
  "the proven refusal is reported through the bounded retry path")
assert(remuda._butler_delivery_journal.state_of("lead-id", "n1") == nil,
  "the released attempt leaves no reservation")
assert(unread.n1 == true, "the mail stays unread")
assert(#spawns == 1, "no immediate replay inside the retry delay")

-- 5b. A malformed binding target disables the session without a helper call.
reset()
queue()
bus.agents.lead.native.nonce = "not-hex"
assert(N.deliver_notice("lead") == false, "a malformed binding defers")
assert(#spawns == 0, "the helper is never called for a malformed binding")
assert(bus.agents.lead.native.mode == "disabled", "the malformed binding disables")
assert(#alerts == 1 and alerts[1]:find("No PTY fallback", 1, true),
  "the disabled state is reported explicitly")

-- 5c. A listing failure proves nothing about the binding: bounded retry,
-- no disable and no helper call.
reset()
queue()
respond({ outcome = "accepted_queue" })
remuda.ls = function() error("listing failed") end
assert(N.deliver_notice("lead") == false, "an unverifiable row defers")
assert(#spawns == 0, "no helper call without a verified row")
assert(bus.agents.lead.native.mode == "native", "a listing failure does not disable")
assert(bus.notices.lead and bus.notices.lead.delivery_attempts == 1,
  "the unverified row uses the bounded retry path")
remuda.ls = function() return rows end

-- 6. Disabled mode never invokes the helper at all.
reset()
bus.agents.lead.native.mode = "disabled"
bus.agents.lead.native.reason = "server_gone"
queue()
assert(N.deliver_notice("lead") == false, "disabled mode defers")
assert(#spawns == 0, "disabled mode never invokes the helper")

-- 6b. The very first ls in the snapshot must not change the decision under
-- already-chosen native text: toggle to disabled => zero helper, zero PTY.
reset()
queue()
respond({ outcome = "accepted_queue" })
on_ls = function()
  bus.agents.lead.native.mode = "disabled"
  bus.agents.lead.native.reason = "server_gone"
end
assert(N.deliver_notice("lead") == false, "a list-time disable defers")
assert(#spawns == 0 and pty_sends == 0, "no helper and no PTY after a list-time disable")

-- 6c. A PTY snapshot that becomes bound during the first ls is stale too: no
-- PTY write with PTY text and no native dispatch under the old decision.
reset()
bus.agents.lead.native = nil
queue()
respond({ outcome = "accepted_queue" })
on_ls = function()
  bus.agents.lead.native = { mode = "native", path = "/data/remuda/butler/bindings/lead/"
    .. string.rep("a", 32), nonce = string.rep("a", 32), row_id = "ses_abc",
    instance = "instance-1" }
end
assert(N.deliver_notice("lead") == false, "a list-time bind defers")
assert(pty_sends == 0 and #spawns == 0, "no PTY and no helper after a list-time bind")

-- 6d. A PTY attempt that becomes bound during the journal write is stale: no
-- PTY write under the old text and no native dispatch under the new decision.
reset()
bus.agents.lead.native = nil
queue()
respond({ outcome = "accepted_queue" })
on_begin = function()
  bus.agents.lead.native = { mode = "native", path = "/data/remuda/butler/bindings/lead/"
    .. string.rep("a", 32), nonce = string.rep("a", 32), row_id = "ses_abc",
    instance = "instance-1" }
end
assert(N.deliver_notice("lead") == false, "a write-time bind defers")
assert(pty_sends == 0 and #spawns == 0, "no PTY and no helper after a write-time bind")

-- 7. A binding replaced during the journal write is a stale generation: no
-- dispatch, no PTY, and the reservation is conservatively uncertain.
reset()
queue()
respond({ outcome = "accepted_queue" })
on_begin = function()
  bus.agents.lead.native = { mode = "native", path = "/other/binding",
    nonce = string.rep("b", 32), row_id = "ses_abc", instance = "instance-1" }
end
assert(N.deliver_notice("lead") == false, "a replaced binding defers")
assert(#spawns == 0, "the replaced binding is never used")
assert(remuda._butler_delivery_journal.state_of("lead-id", "n1") == "uncertain",
  "the stale attempt is durably uncertain")
assert(bus.notices.lead ~= nil, "the notice stays queued")

-- 8. A toggle to disabled during the journal write is also stale: zero PTY,
-- and the next tick reports disabled once without invoking the helper.
reset()
queue()
respond({ outcome = "accepted_queue" })
on_begin = function()
  bus.agents.lead.native.mode = "disabled"
  bus.agents.lead.native.reason = "server_gone"
end
assert(N.deliver_notice("lead") == false, "a mid-write disable defers")
assert(#spawns == 0, "a mid-write disable never uses the helper")
-- The stale attempt is conservatively uncertain, so the reservation blocks a
-- replay; a later tick must still never fall back to PTY.
assert(N.deliver_notice("lead") == true and #spawns == 0,
  "the disabled session still never falls back to PTY")
assert(remuda._butler_delivery_journal.state_of("lead-id", "n1") == "uncertain",
  "the stale attempt stays durably uncertain")

print("ok - native notices use one canonical helper request and stay sticky")
