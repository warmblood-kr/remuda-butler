-- Unit tests for packages/butler/status_command.lua. Run from the repository root:
--   luajit tests/butler_status_command.lua
remuda = { butler = {} }
dofile("packages/butler/typed_lines.lua")
local status = dofile("packages/butler/status_command.lua")

local function lines_of(text)
  local count = 0
  for _ in (text .. "\n"):gmatch("([^\n]*)\n") do count = count + 1 end
  return count
end

local now = 1800000000
local function lines(text)
  local out = {}
  for line in text:gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end

-- no sessions, no quota
local empty = status.status_format({ sessions = {}, now = now })
assert(empty:find("butler status · 0 sessions", 1, true), "header counts zero sessions")
assert(empty:find("quota    claude n/a  codex n/a", 1, true), "absent quota shows n/a for both")
assert(empty:find("load     cpu n/a · mem n/a · disk n/a", 1, true), "load is n/a")
assert(empty:find("?help", 1, true), "footer points at ?help")

-- several sessions
local text = status.status_format({
  now = now,
  sessions = {
    { name = "butler", kind = "claude", context_percent = 41, busy = false },
    { name = "dev-1", kind = "codex", context_percent = 78.4, busy = true, unread = 2 },
    { name = "qa", kind = "claude", busy = false, unread = 0 },
  },
  quota = { at = now - 30, limits = {
    { name = "5-hour limit", used = 62, resets_at = now + 3600 },
    { name = "Weekly limit", used = 91, resets_at = now + 86400 },
  } },
})
assert(text:find("butler status · 3 sessions", 1, true))
assert(text:find("butler   claude ctx 41%  idle", 1, true), text)
assert(text:find("dev-1    codex  ctx 78%  task  ✉2", 1, true), text)
assert(text:find("qa       claude ctx n/a  idle", 1, true), text)
assert(not text:find("qa       claude ctx n/a  idle  ✉", 1, true), "zero unread shows no mail mark")
assert(text:find("quota    claude 5h 62% · 7d 91%  codex n/a", 1, true), text)
assert(not text:find("as of", 1, true), "a fresh reading carries no age")

-- stale reading, partial reading
local stale = status.status_format({ now = now, sessions = {},
  quota = { at = now - 1500, limits = { { name = "Weekly limit", used = 7, resets_at = now + 5 } } } })
assert(stale:find("quota    claude 7d 7% (as of 25m ago)  codex n/a", 1, true), stale)

-- names are reduced to safe characters
local dirty = status.status_format({ now = now, sessions = {
  { name = "ev\27[31mil\226\128\174evil\n@x", kind = "cl\0aude" },
} })
assert(not dirty:find("[%z\1-\9\11-\31\127]"), "no control bytes in the reply")
assert(not dirty:find("\226\128\174", 1, true), "no bidi override in the reply")
assert(dirty:find("evmilevil", 1, true) == nil and dirty:find("ev31milevilx", 1, true), dirty)

-- bounds: 14 lines, 1500 bytes
local many = {}
for i = 1, 40 do many[i] = { name = "session-" .. i, kind = "claude", context_percent = i } end
local bounded = status.status_format({ now = now, sessions = many })
assert(lines_of(bounded) <= 14, "at most 14 lines, got " .. lines_of(bounded))
assert(#bounded <= 1500, "at most 1500 bytes")
assert(bounded:find("+%d+ more"), "hidden sessions are counted")
assert(bounded:find("?help", 1, true) and bounded:find("load ", 1, true), "footer survives truncation")
local fat = {}
for i = 1, 10 do fat[i] = { name = string.rep("n", 24) .. i, kind = string.rep("k", 24), context_percent = 5, unread = 99999 } end
local fat_text = status.status_format({ now = now, sessions = fat })
assert(#fat_text <= 1500 and lines_of(fat_text) <= 14, "byte bound holds for long rows")

-- help
local help = status.help_text()
assert(help:find("?status", 1, true) and help:find("?help", 1, true))
assert(lines_of(help) <= 14 and #help <= 1500)
print("ok - status_format and help_text")

-- parse: whole line, case-sensitive, known words only
assert(status.parse("?status") == "status" and status.parse("?help") == "help")
for _, body in ipairs({ "?Status", "?status ", " ?status", "? status", "?statu", "?status now", "!status",
  "status", "?", "?load", "??status", "?status\n" }) do
  assert(status.parse(body) == nil, "must not match " .. string.format("%q", body))
end

-- rate: one per 10 s per sender
local last = {}
assert(status.rate_allow(last, "@a:x", now) == true)
assert(status.rate_allow(last, "@a:x", now + 9) == false)
assert(status.rate_allow(last, "@b:x", now + 9) == true, "other senders have their own window")
assert(status.rate_allow(last, "@a:x", now + 10) == true)

-- handle: gate, scope, parse, rate, in that order
local owner = "@owner:example.org"
local cfg = { allowed_senders = { [owner] = true, ["@agent-1:example.org"] = true },
  butler_senders = {}, self_mxid = "@bot:example.org", status_commands = true }
local function event(body, overrides)
  local value = { event_id = "$e1", sender = owner, type = "m.room.message",
    origin_server_ts = now * 1000, content = { msgtype = "m.text", body = body } }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end
local function scope(overrides)
  local value = { live = true, room_allowed = true, rate = {} }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end
local function handle(ev, c, s, st) return status.handle(st or { processed = {} }, ev, now, c or cfg, s or scope()) end

remuda._butler_bus = { agents = {
  butler = { id = "01A", kind = "claude", cwd = "/secret/cwd", model = "SECRET-MODEL" },
  ["dev-1"] = { id = "01B", kind = "codex" },
}, pending_tasks = { ["dev-1"] = "SECRET-PROMPT" }, inboxes = { butler = { { body = "SECRET-MAIL-BODY" } } } }
remuda._butler_telemetry_for = function(agent)
  return { context_percent = agent.kind == "claude" and 41 or "?", model = "SECRET-MODEL", screen = "SECRET-SCREEN" }
end
remuda._butler_mail = { unread = function(id) return id == "01B" and 2 or 0 end }
remuda._butler_quota = { claude_reading = function()
  return { at = now, limits = { { name = "5-hour limit", used = 62, resets_at = now + 1 } } }
end }

local matched, reply = handle(event("?status"))
assert(matched == true and reply, "an allowlisted human gets a status reply")
assert(reply:find("butler status · 2 sessions", 1, true), reply)
assert(reply:find("butler   claude ctx 41%  idle", 1, true), reply)
assert(reply:find("dev-1    codex  ctx n/a  task  ✉2", 1, true), reply)
assert(reply:find("claude 5h 62%", 1, true), reply)
for _, secret in ipairs({ "SECRET-MAIL-BODY", "SECRET-PROMPT", "SECRET-MODEL", "SECRET-SCREEN", "/secret/cwd", "01A" }) do
  assert(not reply:find(secret, 1, true), "reply leaks " .. secret)
end
local _, help_reply = handle(event("?help"))
assert(help_reply == status.help_text())

local function silent(name, ev, c, s, st)
  local got, text = handle(ev, c, s, st)
  assert(not got and text == nil, name .. " must not be handled")
end
local off = { allowed_senders = cfg.allowed_senders, butler_senders = {}, self_mxid = cfg.self_mxid, status_commands = false }
silent("switch off", event("?status"), off)
silent("not live", event("?status"), nil, scope({ live = false }))
silent("room not allowed", event("?status"), nil, scope({ room_allowed = false }))
silent("agent sender", event("?status", { sender = "@agent-1:example.org" }))
silent("unlisted sender", event("?status", { sender = "@eve:example.org" }))
silent("replayed event", event("?status"), nil, nil, { processed = { ["$e1"] = true } })
silent("old event", event("?status", { origin_server_ts = (now - 400) * 1000 }))
silent("unknown command", event("?load"))
silent("typed-line form", event("!status"))

local s = scope()
assert(handle(event("?status", { event_id = "$a" }), nil, s) == true)
local again, text = handle(event("?status", { event_id = "$b" }), nil, s)
assert(again == true and text == nil, "a request inside the window is consumed without a reply")

-- a failing source blanks only its own part
remuda._butler_telemetry_for = function() error("boom") end
remuda._butler_quota = nil
local degraded = select(2, handle(event("?status")))
assert(degraded:find("butler   claude ctx n/a  idle", 1, true) and degraded:find("claude n/a", 1, true), degraded)

print("ok - parse, rate, handle")

-- malformed quota, telemetry and mail shapes never raise
local function fmt(quota) return status.status_format({ now = now, sessions = {}, quota = quota }) end
for _, quota in ipairs({
  { at = 1, limits = { 5 } }, { at = now, limits = { {} } }, { at = "x", limits = { { name = "Weekly limit", used = 1 } } },
  { limits = { { name = "5-hour limit", used = 1e308 } } }, { at = 1e308, limits = { { name = "5-hour limit", used = 5 } } },
  { at = -1e308, limits = { { name = "5-hour limit", used = 5 } } },
  { limits = "x" }, { limits = { false, "s", { name = 7, used = {} } } }, 5, "q",
}) do
  local out = fmt(quota)
  assert(out:find("quota    claude", 1, true), "malformed quota still formats")
end
assert(not fmt({ at = 1, limits = { 5 } }):find("5h", 1, true))
remuda._butler_bus = { agents = { a = { id = "01A", kind = "claude" } }, pending_tasks = {} }
remuda._butler_telemetry_for = function() error("boom") end
remuda._butler_mail = { unread = function() error("boom") end }
remuda._butler_quota = { claude_reading = function() return { at = 1, limits = { 5 } } end }
local survived = select(2, handle(event("?status", { event_id = "$m1" })))
assert(survived and survived:find("butler status · 1 sessions", 1, true), tostring(survived))

-- an internal error still consumes the event with a bare reply
local real_format = status.status_format
status.status_format = function() error("boom") end
local m, bare = handle(event("?status", { event_id = "$m2" }))
status.status_format = real_format
assert(m == true and bare == "status unavailable", tostring(m) .. tostring(bare))
print("ok - malformed data is contained")
