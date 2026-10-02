-- Unit tests for packages/butler/typed_lines.lua accept. Run from the repository root:
--   luajit tests/butler_typed_lines_accept.lua
local typed_lines = dofile("packages/butler/typed_lines.lua")

local owner = "@owner:example.org"
local now = 1800000000
local cfg = { allowed_senders = { [owner] = true, ["@agent-1:example.org"] = true },
  butler_senders = { ["@bot:example.org"] = true }, self_mxid = "@bot:example.org" }

local function event(body, overrides)
  local value = { event_id = "$e1", sender = owner, type = "m.room.message",
    origin_server_ts = now * 1000, content = { msgtype = "m.text", body = body } }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function check(name, ev, expected_reason, state)
  local ok, reason, body = typed_lines.accept(state or { processed = {} }, ev, now, cfg)
  if expected_reason then
    assert(ok == false and reason == expected_reason, name .. ": expected " .. expected_reason .. ", got " .. tostring(reason))
  else
    assert(ok == true and body == ev.content.body, name .. ": expected the body back, got " .. tostring(reason))
  end
end

check("any prefix is accepted", event("?status"), nil)
check("bang line is accepted too", event("!hello"), nil)
check("agent sender", event("?status", { sender = "@agent-1:example.org" }), "sender_not_allowed")
check("unlisted sender", event("?status", { sender = "@eve:example.org" }), "sender_not_allowed")
check("self sender", event("?status", { sender = "@bot:example.org" }), "sender_not_allowed")
check("too old", event("?status", { origin_server_ts = (now - 301) * 1000 }), "event_too_old")
check("too far in the future", event("?status", { origin_server_ts = (now + 61) * 1000 }), "event_too_old")
check("within skew", event("?status", { origin_server_ts = (now + 59) * 1000 }), nil)
check("no event id", event("?status", { event_id = "" }), "missing_event_id")
check("replayed", event("?status"), "event_replayed", { processed = { ["$e1"] = true } })
check("formatted", event("?status", { content = { msgtype = "m.text", body = "?status", format = "org.matrix.custom.html" } }), "unreadable_content")
check("edit", event("?status", { content = { msgtype = "m.text", body = "?status",
  ["m.relates_to"] = { rel_type = "m.replace", event_id = "$x" } } }), "unreadable_content")
check("two lines", event("?status\n?help"), "invalid_line")
check("control character", event("?sta\0tus"), "invalid_line")
check("bidi override", event("?status\226\128\174"), "invalid_line")
check("oversize", event("?" .. string.rep("a", 2000)), "invalid_line")
check("notice msgtype", event("?status", { content = { msgtype = "m.notice", body = "?status" } }), "unreadable_content")

local state = { processed = {} }
typed_lines.accept(state, event("?status"), now, cfg)
assert(next(state.processed) == nil, "accept must not mutate the replay state")

print("ok - typed_lines.accept")
