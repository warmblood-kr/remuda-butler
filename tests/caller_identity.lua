-- Butler identity comes from the caller's env, not the daemon's (#95).
-- Run from the repo root: luajit tests/caller_identity.lua
remuda = { _butler_test_mode = true }
dofile("packages/butler/init.lua")
local current_agent = remuda._butler_current_agent

assert(current_agent({ env = { REMUDA_BUTLER_AGENT_ID = "dev-lead" } }) == "dev-lead")
assert(current_agent({ env = { REMUDA_BUTLER_SESSION_NAME = "sess" } }) == "sess")
-- An older core sends no caller: fall back to the daemon's own env.
assert(current_agent(nil) == (os.getenv("REMUDA_BUTLER_AGENT_ID") or os.getenv("REMUDA_BUTLER_SESSION_NAME")))
print("ok")
