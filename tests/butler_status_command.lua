-- Unit tests for packages/butler/status_command.lua. Run from the repository root:
--   luajit tests/butler_status_command.lua
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
