-- Butler identity comes from the caller's env, not the daemon's (#95).
-- Run from the repo root: luajit tests/caller_identity.lua
remuda = { _butler_test_mode = true,
  -- main.lua loads its modules with exec; resolve them the way the daemon does.
  exec = function(name) return dofile("packages/butler/" .. name:gsub("^butler/", "") .. ".lua") end,
}
-- init.lua is only the lifecycle entry since #17; the logic lives in main.lua.
dofile("packages/butler/system.lua")
dofile("packages/butler/main.lua")
local current_agent = remuda._butler_current_agent

assert(current_agent({ env = { REMUDA_BUTLER_AGENT_ID = "dev-lead" } }) == "dev-lead")
assert(current_agent({ env = { REMUDA_BUTLER_SESSION_NAME = "sess" } }) == "sess")
-- No caller means no identity, never the daemon's own env (caller_identity.sh).
assert(current_agent(nil) == nil)
-- The stub's exec reaches package modules (paths.lua needs no config).
remuda.exec("butler/paths")
assert(type(remuda._butler_paths) == "table")
print("ok")
