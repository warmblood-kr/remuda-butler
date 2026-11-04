-- The declarative (init.lua) and legacy fallback (agents_launch.lua) member
-- guidance must stay identical, and the root template must share the STICC and
-- prepared-text sections. Run from the repository root:
--   luajit tests/butler_guidance_parity.lua
local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function agents_md(source, marker)
  local at = assert(source:find(marker, 1, true), "missing marker: " .. marker)
  local start = assert(source:find("return [[", at, true), "missing agents_md after: " .. marker)
  start = start + #"return [["
  local finish = assert(source:find("]]", start, true), "unterminated agents_md after: " .. marker)
  return source:sub(start, finish - 1)
end

local function between(source, from, to)
  local start = assert(source:find(from, 1, true), "missing: " .. from)
  start = start + #from
  local finish = assert(source:find(to, start, true), "missing after " .. from .. ": " .. to)
  return source:sub(start, finish - 1)
end

local function from(source, marker)
  local start = assert(source:find(marker, 1, true), "missing: " .. marker)
  return source:sub(start + #marker)
end

local function trimmed(text) return (text:gsub("%s+$", "")) end

local init = read("packages/butler/init.lua")
local fallback = read("packages/butler/agents_launch.lua")
local main = read("packages/butler/main.lua")

local sections = {
  schedule = {
    init = '{ id = "schedule", order = 22,',
    fallback = '"butler.guidance", "schedule", { order = 22,',
  },
  delegation = {
    init = '{ id = "delegation", order = 40,',
    fallback = '"butler.guidance", "delegation", { order = 40,',
  },
  ["prepared-text"] = {
    init = '{ id = "prepared-text", order = 60,',
    fallback = '"butler.guidance", "prepared-text", { order = 60,',
  },
}

local text = {}
for id, where in pairs(sections) do
  text[id] = { init = agents_md(init, where.init), fallback = agents_md(fallback, where.fallback) }
  assert(text[id].init == text[id].fallback,
    id .. " guidance differs between init.lua and agents_launch.lua")
end

local root = between(main, "local BUTLER_GUIDANCE = [[", "\n]]")
local sticc = "## Delegation: STICC\n"
assert(trimmed(from(text.delegation.init, sticc)) == trimmed(between(root, sticc, "\n## Scheduled reminders")),
  "root and member STICC sections differ")
local prepared = "## Prepared text for owner approval\n"
assert(trimmed(from(text["prepared-text"].init, prepared)) == trimmed(from(root, prepared)),
  "root and member prepared-text sections differ")

print("ok - guidance parity (3 shared sections, root STICC and prepared-text)")
