-- Run from the repository root: luajit tests/butler_native_adoption.lua
-- Same-instance reload adoption of a fixed native binding: the roster keeps
-- only path+nonce, adoption takes the fresh row id, and journal-suppressed
-- dispatching/uncertain/accepted IDs are never replayed. A fresh ID uses the
-- same fixed target; nothing invents a new target and nothing falls back to PTY.
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

local traced = {}
_butler_session_trace = function(event, detail) traced[#traced + 1] = { event, detail } end
local bus = { agents = {}, tokens = {}, identity_ids = {}, notices = {}, pending_tasks = {},
  messages = {}, objects = {}, mail_delivered = {}, codex_update_relaunches = {},
  codex_update_state = {}, notice_timers = {}, notice_seen = {}, unread_seeded = {},
  notice_retry_reasons = {}, notice_fallbacks = {}, notice_failure_alerts = {},
  notice_uncertain_alerts = {}, notice_sent_at = {}, notice_reminder_at = {},
  notice_stuck = {}, notice_journal_alerts = {}, notice_journal_failure_alerts = {},
  notice_native_alerts = {} }
local unread = {}
local mail = {
  mailbox = function() return {} end,
  is_unread = function(_, id) return unread[id] == true end,
  unread = function() return 1 end,
  find_message = function(id) return { id = id, from = { alias = "alice", id = "alice-id" } } end,
}
local saved_roster
local function readonly_once(path, text, options)
  assert(options.private == true, "the roster is private")
  saved_roster = text
  return true
end

remuda = {
  _butler_roster_config = { data_home = "/data", bus = bus,
    new_ulid = function() return "01MARKER" end,
    next_token = function() return "token" end },
  _butler_notice_config = { bus = bus, resolve = function(name) return name end,
    mail_address = function(name) return { alias = name, id = name } end,
    mail_id = function(name) return name, { alias = name, id = name, kind = "opencode" } end,
    mail = mail, take_delivery_notice_result = function() end,
    notify_mail_delivery = function() end, deliver_message = function() end },
  _butler_chooser = { known_startup_modal = function() return false end },
  _butler_agent_startup = { opencode = { placeholders = {} } },
  _butler_notice_clock = function() return 2000 end,
  random_bytes = function(n) return string.rep("\7", n) end,
  _butler_session_trace = function(event, detail) traced[#traced + 1] = { event, detail } end,
  json = codec,
  mkdir = function() return true end,
  fs = { write_atomic = readonly_once },
  ls = function() return {} end,
  capture = function() error("native delivery must not read the screen") end,
  send = function() error("native delivery must never use the PTY") end,
}
dofile("packages/butler/roster.lua")
local roster = assert(remuda._butler_roster)
local binding = "/data/remuda/butler/bindings/lead/" .. string.rep("ab", 16) .. "/manifest.json"
local nonce = string.rep("ab", 16)

-- 1. A bound launch saves path+nonce only.
bus.agents.lead = { id = "lead-id", alias = "lead", session_name = "lead", kind = "opencode",
  instance_id = "instance-1", instance_binding = 1,
  native = { mode = "native", path = binding, nonce = nonce,
    row_id = "ses_old", instance = "instance-1" } }
assert(roster.save() == true and saved_roster, "the roster saves the binding")
local saved_row = codec.decode(saved_roster).rows[1]
assert(saved_row.native.path == binding and saved_row.native.nonce == nonce,
  "the binding persists")
assert(saved_row.native.session == "ses_old" and saved_row.native.kind == nil,
  "the bound session and kind persist without an endpoint")
assert(saved_row.native.socket == nil and saved_row.native.thread == nil
  and saved_row.native.mode == nil, "no endpoint, thread or diagnostic mode persists")

-- 2. Same-instance adoption keeps that exact fixed binding and the fresh row.
bus.agents, bus.tokens = {}, {}
bus.identity_ids["lead-id"] = { state = "running", alias = "lead" }
roster.load = function() return { saved_row } end
assert(#roster.adopt({ { name = "lead", alive = true, instance_id = "instance-1",
  id = "ses_live" } }) == 1, "the same instance adopts")
local agent = assert(bus.agents.lead)
assert(agent.native.mode == "native" and agent.native.path == binding
  and agent.native.nonce == nonce and agent.native.instance == "instance-1"
  and agent.native.row_id == "ses_live", "adoption keeps the target, refreshes row.id")
assert(roster.rows()[1].native.path == binding, "a later save keeps the same target")

-- 3. Journal-suppressed IDs never replay; a fresh ID uses the same target.
remuda.ls = function() return { { name = "lead", alive = true, attached = false,
  id = "ses_live", instance_id = "instance-1" } } end
dofile("tests/notice_journal_stub.lua")
dofile("packages/butler/native_dispatch.lua")
dofile("packages/butler/native_launch.lua")
dofile("packages/butler/notice.lua")
local alerts, spawns = {}, {}
remuda._butler_send = function(_, to, body)
  if to == "alice" then alerts[#alerts + 1] = body end
end
local journal = assert(remuda._butler_delivery_journal)
local function reserve(id, state)
  local entry = assert(journal.begin({ recipient_id = "lead-id", message_ids = { id },
    protocol = "native", instance = "instance-1", row_id = "ses_live",
    body = "notice " .. id }))
  if state ~= "dispatching" then assert(journal.mark(entry, state, "test")) end
  return id
end
reserve("u1", "uncertain")
reserve("d1", "dispatching")
reserve("a1", "accepted_unread")
for _, id in ipairs({ "u1", "d1", "a1", "n1" }) do unread[id] = true end
bus.notices.lead = { count = 4, message_order = { "u1", "d1", "a1", "n1" },
  message_ids = { u1 = "notice u1", d1 = "notice d1", a1 = "notice a1", n1 = "notice n1" },
  text = "notice n1", kind = "opencode", due_at = 2000 }
remuda.process = { run = function(spec)
  spawns[#spawns + 1] = spec
  return { code = 0, stdout = codec.encode({ outcome = "accepted_queue" }), stderr = "" }
end }
assert(remuda._butler_notice.deliver_notice("lead") == true, "the fresh ID is delivered")
assert(#spawns == 1, "one helper call, none for suppressed IDs")
local request = codec.decode(spawns[1].stdin)
assert(request.binding == binding and request.nonce == nonce
  and request.session == "ses_live" and request.instance == "instance-1",
  "the fresh ID uses the same fixed target")
assert(#request.message_ids == 1 and request.message_ids[1] == "n1",
  "suppressed IDs are not replayed")
assert(journal.state_of("lead-id", "u1") == "uncertain"
  and journal.state_of("lead-id", "d1") == "dispatching"
  and journal.state_of("lead-id", "a1") == "accepted_unread",
  "durable suppression states are unchanged")
assert(bus.agents.lead.native.mode == "native", "delivery keeps the native target")
assert(#alerts == 0, "no alert for a healthy same-target delivery")

print("ok - same-instance adoption keeps the fixed target and never replays suppressed IDs")
