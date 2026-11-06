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
local alerts, spawns, pty_sends, timers = {}, {}, 0, {}
local timer_callbacks, random_calls = {}, 0
local ls_calls = 0
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
  random_bytes = function(n)
    random_calls = random_calls + 1
    return string.char(random_calls % 256) .. string.rep("\0", n - 1)
  end,
  _butler_notice_after = function(seconds, fn)
    timers[#timers + 1] = seconds
    timer_callbacks[#timer_callbacks + 1] = fn
    return { cancel = function() end }
  end,
  _butler_session_trace = _butler_session_trace,
  json = codec,
  ls = function() return rows end,
  capture = function() error("native delivery must not read the screen") end,
  send = function() pty_sends = pty_sends + 1; error("native delivery must never use the PTY") end,
}
dofile("tests/notice_journal_stub.lua")
dofile("packages/butler/native_dispatch.lua")
dofile("packages/butler/native_launch.lua")
dofile("packages/butler/send_policy.lua")
dofile("packages/butler/notice.lua")
remuda._butler_send = function(_, to, body)
  if to == "alice" then alerts[#alerts + 1] = body end
end
local N = remuda._butler_notice
assert(remuda.butler.send_policy.construct == nil and remuda.butler.send_policy.observe == nil,
  "the raw policy constructors stay private")
assert(remuda._butler_notice._policy_bound, "the live notice image bound the policy once")
assert(remuda.butler.native_dispatch.install == nil,
  "the policy consumed the transport factory before the first native send")

local on_begin, on_ls, on_retire
local function reset()
  now = 2000
  bus.agents = { lead = { id = "lead-id", kind = "opencode", parent = "root",
    instance_id = "instance-1", native = { mode = "native",
      path = "/data/remuda/butler/bindings/lead/" .. string.rep("a", 32) .. "/manifest.json",
      nonce = string.rep("a", 32), row_id = "ses_abc", instance = "instance-1" } } }
  bus.notices, bus.notice_stuck, bus.notice_recovery = {}, {}, nil
  bus.pending_tasks, bus.notice_seen = {}, {}
  bus.notice_native_alerts, bus.notice_native_dispatching = {}, {}
  rows = { { name = "lead", alive = true, attached = false, id = "ses_abc",
    instance_id = "instance-1" } }
  remuda.ls = function()
    ls_calls = ls_calls + 1
    if on_ls then local hook = on_ls; on_ls = nil; hook() end
    return rows
  end
  unread = { n1 = true, n2 = true }
  alerts, spawns, pty_sends, timers = {}, {}, 0, {}
  timer_callbacks, random_calls = {}, 0
  bus.notice_native_watchers = {}
  bus.notice_native_watcher_checks = {}
  ls_calls = 0
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
assert(sent.request_id:match("^msg_%x+$") and #sent.request_id == 36,
  "request id is a per-dispatch CSPRNG claim")
assert(bus.notices.lead == nil, "accepted delivery clears the queue")
assert(remuda._butler_delivery_journal.state_of("lead-id", "n1") == "accepted_unread",
  "native acceptance is accepted_unread until the canonical read")

-- 1b. Two attempts in the same clock second get distinct claims: the id is
-- frozen per attempt, never derived from the first mail id or the clock.
reset()
queue({ "n1" })
respond({ outcome = "accepted_queue" })
assert(N.deliver_notice("lead") == true, "first same-second attempt completes")
local first_claim = codec.decode(spawns[1].stdin).request_id
queue({ "n2" })
respond({ outcome = "accepted_queue" })
assert(N.deliver_notice("lead") == true, "second same-second attempt completes")
local second_claim = codec.decode(spawns[2].stdin).request_id
assert(first_claim ~= second_claim, "same-second attempts never share a claim")

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

-- 5e. A fresh launch may race publication: a proven missing manifest parks
-- without disable, attempt spend or timers, then flushes as soon as a later
-- attempt reaches the binding.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "missing manifest parks the attempt")
assert(bus.agents.lead.native.mode == "native", "startup pending never disables")
assert(bus.notices.lead ~= nil and bus.notices.lead.due_at == now + 1,
  "unreserved mail stays queued for the next immediate attempt")
assert(#timers == 0 and pty_sends == 0, "startup pending uses no timer and no PTY")
respond({ outcome = "accepted_queue" })
-- The explicit publication entrypoint, with no timer or poll tick fired.
assert(remuda._butler_notice.native_publication("lead") == true,
  "the publication hook flushes the queued mail")
assert(bus.notices.lead == nil and #spawns == 2, "publication flushes the queued mail")
assert(bus.agents.lead.native.awaiting_publication == nil,
  "the first accepted answer ends the startup window")

-- 5f. A published/adopted binding that disappears is dead, not startup. The
-- same typed reason must not become endless waiting.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = nil
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "a missing adopted manifest refuses")
assert(bus.agents.lead.native.mode == "disabled", "a vanished published binding disables")
assert(bus.notices.lead ~= nil and pty_sends == 0, "mail stays unread, never PTY")

-- 5h. Only the typed absence parks. A malformed/wrong OpenCode binding is
-- dead even during the fresh-launch window.
reset()
queue()
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
respond({ outcome = "definitely_not_written", reason = "invalid_binding" })
assert(N.deliver_notice("lead") == false, "a malformed binding refuses")
assert(bus.agents.lead.native.mode == "disabled",
  "a generic invalid binding is dead, never parked")

-- 5j. A fresh launch with no manifest is detected by a private-path stat, so
-- no helper is spawned on every tick; the same tick flushes once it exists.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "accepted_queue" })
now = now + 1
remuda._butler_deliver_notices()
assert(#spawns == 0 and bus.notices.lead ~= nil,
  "a missing manifest is metadata-checked without spawning the helper")
remuda.fs.realpath = function() return "/private/binding/manifest.json", nil end
remuda._butler_deliver_notices()
assert(#spawns == 1 and bus.notices.lead == nil,
  "the first tick after publication flushes the queued mail")
remuda.fs = nil

-- 5k. Presence suppression is bounded: after the startup window expires with
-- the manifest still absent, the helper runs once and the binding disables
-- through the existing typed path; mail stays unread and no PTY is used.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now - 121
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
remuda._butler_deliver_notices()
assert(#spawns == 1, "an expired window still attempts the helper once")
assert(bus.agents.lead.native.mode == "disabled",
  "an expired missing manifest disables through the existing path")
assert(bus.notices.lead ~= nil and pty_sends == 0, "mail is preserved, never PTY")
remuda.fs = nil

-- 5m. A symlink at the manifest path is not definite absence: the helper, not
-- the metadata precheck, classifies it. No io.open/FIFO path is used.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda._butler_paths = { file_exists = function() error("must not open the manifest") end }
remuda.fs = {
  is_symlink = function() return true, nil end,
  realpath = function() error("the precheck must not resolve a link") end,
}
respond({ outcome = "definitely_not_written", reason = "invalid_binding" })
now = now + 1
remuda._butler_deliver_notices()
assert(#spawns == 1 and bus.agents.lead.native.mode == "disabled",
  "a symlink is handed to the strict helper and classified, not parked")
assert(pty_sends == 0, "a corrupt manifest never falls back to PTY")
remuda.fs, remuda._butler_paths = nil, nil

-- 5n. A metadata error is not definite absence either: the helper decides.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "permission_denied" end }
respond({ outcome = "definitely_not_written", reason = "invalid_binding" })
now = now + 1
remuda._butler_deliver_notices()
assert(#spawns == 1, "a metadata error lets the helper classify the binding")

-- 5o. A link-check error is also helper-decides, not definite absence.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = {
  is_symlink = function() return nil, "permission_denied" end,
  realpath = function() return nil, "not_found" end,
}
respond({ outcome = "definitely_not_written", reason = "invalid_binding" })
now = now + 1
remuda._butler_deliver_notices()
assert(#spawns == 1, "a link-check error lets the helper classify the binding")
remuda.fs = nil

-- 5l. The same bounded expiry applies to the longer Claude window.
reset()
queue()
bus.agents.lead.native.kind = "claude"
bus.agents.lead.native.session_token = "ses_abc"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now - 1801
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
remuda._butler_deliver_notices()
assert(#spawns == 1 and bus.agents.lead.native.mode == "disabled",
  "the Claude startup window also expires into the dead path")
assert(bus.notices.lead ~= nil and pty_sends == 0, "Claude mail stays unread, never PTY")
remuda.fs = nil

-- 5p. The lead-approved 50ms presence watcher: armed only after a typed
-- binding_missing on a known initializing launch; fires once the private
-- manifest appears and flushes the queued mail.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "binding_missing parks the attempt")
assert(timers[#timers] == 0.05 and #timer_callbacks >= 1,
  "a 50ms presence watcher is armed")
remuda.fs.realpath = function() return "/private/binding/manifest.json", nil end
respond({ outcome = "accepted_queue" })
timer_callbacks[#timer_callbacks]()
assert(#spawns == 2 and bus.notices.lead == nil,
  "the watcher flushes the queued mail when the manifest appears")
assert(bus.notice_native_watchers.lead == nil, "the watcher clears after the flush")
remuda.fs = nil

-- 5q. A replaced binding is fenced: the old watcher never flushes a new one.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "binding_missing parks the attempt")
bus.agents.lead.native.nonce = string.rep("b", 32)
respond({ outcome = "accepted_queue" })
timer_callbacks[#timer_callbacks]()
assert(#spawns == 1, "a replaced binding is not flushed by the old watcher")
remuda.fs = nil

-- 5r. Agent replacement and module replacement both stop the old watcher.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "park before replacement")
local stale_agent = bus.agents.lead
bus.agents.lead = { kind = "codex", id = stale_agent.id, instance_id = stale_agent.instance_id,
  native = stale_agent.native }
remuda.fs.realpath = function() return "/private/binding/manifest.json", nil end
respond({ outcome = "accepted_queue" })
timer_callbacks[#timer_callbacks]()
assert(#spawns == 1 and bus.notice_native_watchers.lead == nil,
  "agent replacement stops the old watcher without a helper")

reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "park before module replacement")
local live_module = remuda._butler_notice
remuda._butler_notice = {}
remuda.fs.realpath = function() return "/private/binding/manifest.json", nil end
respond({ outcome = "accepted_queue" })
timer_callbacks[#timer_callbacks]()
assert(#spawns == 1 and bus.notice_native_watchers.lead == nil,
  "module replacement stops the old watcher without a helper")
remuda._butler_notice = live_module
remuda.fs = nil

-- 5s. A dead live row stops the watcher before any helper call.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "park before the row dies")
rows[1].alive = false
remuda.fs.realpath = function() return "/private/binding/manifest.json", nil end
respond({ outcome = "accepted_queue" })
timer_callbacks[#timer_callbacks]()
assert(#spawns == 1 and bus.notice_native_watchers.lead == nil,
  "a dead live row stops the watcher without a helper")
remuda.fs = nil

-- 5t. The row-liveness sample survives rearms: the counter cannot be a
-- closure local, or every re-armed tick would look like the first one and
-- enumerate the roster every 50ms. 39 absent ticks must sample twice.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "park before the cadence check")
local base_ls = ls_calls
for _ = 1, 39 do
  timer_callbacks[#timer_callbacks]()
end
assert(ls_calls - base_ls == 2,
  "39 absent ticks sample the row on tick 1 and tick 20 only, got "
    .. tostring(ls_calls - base_ls))
assert(bus.notice_native_watchers.lead ~= nil, "the watcher keeps re-arming")
remuda.fs = nil
N.complete_notice_recovery("lead", { message_ids = {} })
assert(bus.notice_native_watcher_checks.lead == nil,
  "a terminal outcome clears the sampling counter")

-- 5u. A stopped generation never lends its sample counter to the next one:
-- expiry, a binding/agent/module change or a published manifest leaves no
-- count behind, so the next watcher still samples on its own first tick.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
remuda.fs = { is_symlink = function() return false, nil end,
  realpath = function() return nil, "not_found" end }
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "park before the expiry stop")
timer_callbacks[#timer_callbacks]()
assert(bus.notice_native_watcher_checks.lead == 1, "the first tick samples and rearms")
bus.agents.lead.native.awaiting_since = now - 121
timer_callbacks[#timer_callbacks]()
assert(bus.notice_native_watchers.lead == nil
  and bus.notice_native_watcher_checks.lead == nil,
  "a genuinely expired window stops and clears its counter")
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "park the new generation")
local before = ls_calls
timer_callbacks[#timer_callbacks]()
assert(ls_calls == before + 1, "the new generation samples on its first tick")
remuda.fs = nil
N.complete_notice_recovery("lead", { message_ids = {} })

-- 5g. The startup window is bounded per protocol; an expired fresh launch is
-- treated as dead rather than parked forever.
reset()
queue()
bus.agents.lead.native.kind = "codex"
bus.agents.lead.native.awaiting_publication = true
bus.agents.lead.native.awaiting_since = now - 121
respond({ outcome = "definitely_not_written", reason = "binding_missing" })
assert(N.deliver_notice("lead") == false, "an expired startup window refuses")
assert(bus.agents.lead.native.mode == "disabled", "no indefinite startup waiting")

-- 5i. Claude uses its own verb and the same canonical row-id session, and
-- possible emission is final uncertain: no retry, no disable, no PTY.
reset()
queue()
bus.agents.lead.native.kind = "claude"
bus.agents.lead.native.session_token = "ses_abc"
respond({ outcome = "uncertain", reason = "channel_emitted_unconfirmed" })
assert(N.deliver_notice("lead") == false, "possible Claude emission is uncertain")
assert(spawns[1].argv[2] == "_claude_notice", "Claude uses only _claude_notice")
local claude_sent = codec.decode(spawns[1].stdin)
assert(claude_sent.session == "ses_abc" and claude_sent.session ~= "lead",
  "Claude request carries the canonical row id, not the alias")
assert(bus.agents.lead.native.mode == "native", "uncertainty never disables Claude")
assert(pty_sends == 0, "Claude uncertainty never falls back to PTY")
assert(remuda._butler_delivery_journal.state_of("lead-id", "n1") == "uncertain",
  "the Claude attempt is durably uncertain")

-- 5w. An old Lua projection omits row.id; the dispatch proves the canonical
-- id through the grounded lookup and still sends the stored session.
reset()
queue()
rows[1].id = nil
bus.agents.lead.native.kind = "opencode"
bus.agents.lead.native.row_id = "core-id-lead"
bus.agents.lead.native.session_token = "core-id-lead"
assert(rawget(remuda, "_butler_native_identity") == nil,
  "the dispatch must not read a private identity alias")
remuda.butler = remuda.butler or {}
remuda.butler.native_identity = { resolve = function(row, options)
  assert(type(options.rows) == "table" and type(options.list) == "function",
    "the proof gets the pre fleet and a post re-list")
  return "core-id-lead"
end }
respond({ outcome = "accepted_queue" })
assert(N.deliver_notice("lead") == true, "the old projection still dispatches")
local old_projection = codec.decode(spawns[#spawns].stdin)
assert(old_projection.session == "core-id-lead",
  "Request1 session is the resolved canonical id")

-- 5x. A native decision replaced during the lookup yield never authorizes the
-- stale binding: no helper call and a retryable deferral.
reset()
queue()
rows[1].id = nil
bus.agents.lead.native.kind = "opencode"
bus.agents.lead.native.row_id = "core-id-lead"
bus.agents.lead.native.session_token = "core-id-lead"
remuda.butler.native_identity = { resolve = function()
  bus.agents.lead.native = { mode = "native", kind = "opencode",
    path = "/fresh/manifest.json", nonce = string.rep("b", 32),
    row_id = "fresh-id", instance = "instance-1" }
  return "core-id-lead"
end }
respond({ outcome = "accepted_queue" })
assert(N.deliver_notice("lead") == false, "a replaced decision is not dispatched")
assert(#spawns == 0, "no helper call for the stale decision")
assert(bus.agents.lead.native.row_id == "fresh-id", "the fresh decision is preserved")
remuda.butler.native_identity = nil

-- 5y. With no public identity module an old projection cannot prove its id:
-- the dispatch fails closed with no helper call and no PTY fallback.
reset()
queue()
rows[1].id = nil
bus.agents.lead.native.kind = "opencode"
bus.agents.lead.native.row_id = "core-id-lead"
bus.agents.lead.native.session_token = "core-id-lead"
respond({ outcome = "accepted_queue" })
assert(N.deliver_notice("lead") == false, "a missing public module fails closed")
assert(#spawns == 0, "no helper call without the canonical proof")
assert(pty_sends == 0, "no PTY fallback without the canonical proof")

-- 6a. A native arrival is dispatched in the notify call itself: no quiet or
-- cap timer, no PTY, and a pending first task or attached pane does not hold
-- it back.
reset()
unread.imm1 = true
rows[1].attached, rows[1].human_idle = true, false
bus.pending_tasks.lead = { marker = "first-task" }
respond({ outcome = "accepted_queue" })
assert(remuda._butler_notify("lead", "Butler message imm1 arrived. Read it: remuda butler inbox",
  "imm1") == true, "the native notice is dispatched immediately")
assert(#spawns == 1 and #timers == 0 and pty_sends == 0,
  "native uses no timer, no PTY and one helper call")
assert(bus.notices.lead == nil, "an accepted native notice clears the queue")
assert(bus.pending_tasks.lead ~= nil, "the pending task is not consumed by the notice")

-- 6b. A native re-show is equally immediate even while a task owns the pane.
reset()
unread.imm2 = true
bus.pending_tasks.lead = { marker = "first-task" }
respond({ outcome = "accepted_queue" })
assert(remuda._butler_notify("lead", "Butler message imm2 arrived. Read it: remuda butler inbox",
  "imm2", true) == true, "the native re-show is dispatched immediately")
assert(#spawns == 1 and #timers == 0 and pty_sends == 0,
  "a native re-show uses no timer, no PTY and one helper call")

-- 6c. The same notify for an unbound PTY session still coalesces.
reset()
bus.agents.lead.native = nil
unread.pty1 = true
assert(remuda._butler_notify("lead", "Butler message pty1 arrived. Read it: remuda butler inbox",
  "pty1") == false, "the PTY notice is queued, not sent")
assert(#spawns == 0 and #timers == 2 and timers[1] == 10 and timers[2] == 2,
  "the PTY path keeps its cap and quiet timers")

-- 6d. The very first ls in the snapshot must not change the decision under
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
