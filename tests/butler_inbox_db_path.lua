-- inbox_db_path: mirror core's remuda.db root without touching the filesystem.
local M = assert(loadfile("packages/butler/inbox_db_path.lua"))()

local function eq(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function missing(platform, env, mod, name, needle)
  local path, why = M.database_file(platform, env, mod, name)
  assert(path == nil, "expected no path for " .. needle)
  assert(type(why) == "string" and why:find(needle, 1, true),
    "reason should mention " .. needle .. ": " .. tostring(why))
end

eq(M.database_file("posix", { XDG_STATE_HOME = "/state", HOME = "/home/u" },
  "butler", "inbox"), "/state/remuda/db/butler/inbox.db", "XDG_STATE_HOME wins")
eq(M.database_file("posix", { HOME = "/home/u" },
  "butler", "inbox"), "/home/u/.local/state/remuda/db/butler/inbox.db", "HOME fallback")
eq(M.database_file("posix", { XDG_STATE_HOME = "", HOME = "/home/u" },
  "butler", "inbox"), "/home/u/.local/state/remuda/db/butler/inbox.db", "empty XDG falls back")
eq(M.database_file("posix", { XDG_STATE_HOME = "/state/" },
  "butler", "inbox"), "/state/remuda/db/butler/inbox.db", "trailing separator")
missing("posix", {}, "butler", "inbox", "HOME")

eq(M.database_file("windows", { LOCALAPPDATA = "C:\\state", HOME = "/ignored" },
  "butler", "inbox"), "C:\\state\\remuda\\db\\butler\\inbox.db", "LOCALAPPDATA wins")
eq(M.database_file("windows", { USERPROFILE = "C:\\Users\\u" },
  "butler", "inbox"),
  "C:\\Users\\u\\AppData\\Local\\remuda\\db\\butler\\inbox.db", "USERPROFILE fallback")
missing("windows", {}, "butler", "inbox", "LOCALAPPDATA")

missing("plan9", { HOME = "/home/u" }, "butler", "inbox", "unknown platform")
missing("posix", { HOME = "/home/u" }, "../butler", "inbox", "plain path components")
missing("posix", { HOME = "/home/u" }, "butler", "in/box", "plain path components")

-- path_state: metadata first; a nil answer is "cannot tell", not "absent".
local file = { close = function() end }
eq(M.path_state({ realpath = function() return "/resolved" end }, "/x", nil),
  "present", "realpath present")
eq(M.path_state({ realpath = function() return nil, "not_found" end }, "/x", nil),
  "absent", "realpath not_found")
local state, why = M.path_state({ realpath = function() return nil, "denied: nope" end }, "/x")
assert(state == nil and why == "denied: nope", "denied must not look absent")
state, why = M.path_state({ realpath = function() error("raised") end }, "/x")
assert(state == nil and why:find("raised", 1, true), "a raise must not look absent")
eq(M.path_state(nil, "/x", function() return file end), "present", "fallback present")
eq(M.path_state(nil, "/x", function() return nil end), "absent", "fallback absent")
state, why = M.path_state(nil, "/x", function() error("nope") end)
assert(state == nil and why:find("nope", 1, true), "fallback raise must not look absent")

print("ok - inbox database path")
