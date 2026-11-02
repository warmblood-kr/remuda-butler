-- Outgoing @mentions become matrix.to pills + m.mentions (#530).
-- Run from the repository root: luajit tests/butler_matrix_mention_send.lua
local sent
local known = { ["@butler-b:example.org"] = true }
local relay = { resolve_mention = function(_, l, s)
  local mxid = "@" .. l .. ":" .. (s or "example.org")
  return known[mxid] and mxid or nil
end }
local matrix = {
  once = function(cb) return cb end,
  path_component = function(v) return v end,
  sanitize_directory_text = function(v) return tostring(v or "") end,
  encode_json = function(t) return t end,
  relay = { instance = relay }, take_post_slot = function() return true end,
  request_json = function(args, cb) sent = args.body; cb({ json = { event_id = "$e" } }) end,
}
_G.remuda = { butler = { matrix = matrix, approval = { handler = function() end } },
  random_bytes = function(n) return string.rep("r", n) end }
dofile("packages/butler/md2html.lua")
dofile("packages/butler/matrix_write.lua")
dofile("packages/butler/matrix_mentions.lua")

local function send(text)
  sent = nil
  matrix.send({ room = "!r:example.org", text = text }, function(r) assert(not r.error, r.error) end)
  return sent
end

local c = send("hi @butler-b, please look. Also @nobody and `@butler-b` code")
local a = '<a href="https://matrix.to/#/@butler-b:example.org">@butler-b</a>'
assert(c.body:find("hi @butler-b, please", 1, true), c.body)
assert(c.formatted_body:find(a .. ", please", 1, true), c.formatted_body)
assert(not c.formatted_body:find("@nobody</a>", 1, true), "unknown stays plain")
assert(not c.formatted_body:find("<code>" .. a, 1, true), "code span stays plain")
assert(#c["m.mentions"].user_ids == 1 and c["m.mentions"].user_ids[1] == "@butler-b:example.org")
local body, ids = matrix.mention_normalization.normalize(send("hi @butler-b, please look"))
assert(ids[1] == "@butler-b:example.org" and body:find("@butler-b", 1, true), "receiver must accept it")

c = send("ping @butler-b:example.org now")
assert(c.formatted_body:find('#/@butler-b:example.org">@butler-b:example.org</a> now', 1, true), c.formatted_body)
assert(c["m.mentions"].user_ids[1] == "@butler-b:example.org")

c = send("no mention @nobody here")
assert(c["m.mentions"] == nil and not c.formatted_body:find("matrix.to", 1, true), "fallback is plain")
print("ok - outgoing Matrix mention pills")
