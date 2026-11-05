-- Run from the repository root: luajit tests/butler_delivery_status.lua
-- Read-only doctor rendering of the delivery journal: states, counts, ages,
-- recipient/message IDs and reasons only. Never bodies, paths or credentials.
remuda = {}
local module = dofile("packages/butler/delivery_status.lua")

local function render(status, now)
  local journal = { status = function() return status end }
  return module.lines(journal, now)
end

-- 1. Missing/unusable journal says so plainly and blocks.
local none = module.lines(nil, 1)
assert(#none == 1 and none[1]:find("unavailable", 1, true), "no journal is reported")
local broken = module.lines({ status = function() error("boom") end }, 1)
assert(broken[1]:find("status unavailable", 1, true), "a broken status call is reported")

-- 2. An idle usable journal is one line.
local idle = render({ usable = true, entries = 0, uncertain = 0, accepted_unread = 0,
  dispatching = 0, oldest_seconds = 0, items = {} }, 100)
assert(#idle == 1 and idle[1]:find("journal ok", 1, true), "idle journal is ok")
assert(idle[1]:find("no reserved or uncertain", 1, true), "idle journal says why")

-- 3. Counts, age and a bounded item list with IDs and reason; no body.
local items = {}
for index = 1, 8 do
  items[index] = { state = "uncertain", recipient_id = "lead-id",
    message_ids = { "m" .. index, "m" .. index .. "b" }, age_seconds = index * 60,
    reason = "submission is unconfirmed", body = "SECRET BODY " .. index }
end
local lines = render({ usable = true, entries = 8, uncertain = 8, accepted_unread = 0,
  dispatching = 0, oldest_seconds = 480, items = items }, 1000)
local text = table.concat(lines, "\n")
assert(text:find("8 uncertain", 1, true), "counts uncertain")
assert(text:find("8m", 1, true), "oldest age is human readable")
assert(text:find("lead-id", 1, true) and text:find("ids=m1,m1b", 1, true), "IDs are shown")
assert(text:find("submission is unconfirmed", 1, true), "reason is shown")
assert(not text:find("SECRET BODY", 1, true), "the frozen body never reaches doctor")
local item_count = 0
for _, line in ipairs(lines) do
  if line:match("^  uncertain") then item_count = item_count + 1 end
end
assert(item_count == 5, "the item list is bounded to five")

-- 4. Problem states are explicit and never claim delivery.
local corrupt = render({ usable = false, corrupt = "journal_corrupt: header", entries = 2,
  items = {} }, 1)[1]
assert(corrupt:find("CORRUPT", 1, true) and corrupt:find("blocked", 1, true),
  "corruption blocks and says so")
local blocked = render({ usable = false, blocked = "save_failed: disk full", entries = 1,
  items = {} }, 1)[1]
assert(blocked:find("blocked", 1, true), "a blocked journal is reported")
local full = render({ usable = false, full = true, entries = 128, items = {} }, 1)[1]
assert(full:find("full", 1, true) and full:find("capacity", 1, true),
  "a full journal is reported")
local unverified = render({ usable = false, digests_unverified = true, entries = 1,
  items = {} }, 1)[1]
assert(unverified:find("hash module", 1, true), "deferred digest verification is reported")

-- 5. A non-usable journal with no explicit flag still renders item state (no crash).
local odd = render({ usable = false, entries = 1, items = { { state = "dispatching",
  recipient_id = "x", message_ids = { "m1" }, age_seconds = 2, reason = "" } } }, 3)
assert(#odd >= 1, "an odd snapshot still renders")

print("ok - delivery status is read-only, bounded, explicit and secret-free")
