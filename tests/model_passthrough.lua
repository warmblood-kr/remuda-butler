-- A member's model reaches its agent's argv.
-- Run from the repo root: luajit tests/model_passthrough.lua
remuda = {
  _butler_agent_builders = {},
  _butler_telemetry_adapters = {},
  _butler_agent_support = { mcp_config_path = function() return "mcp.json" end },
}
dofile("packages/butler/agents/codex.lua")
dofile("packages/butler/agents/claudecode.lua")
local build = remuda._butler_agent_builders

local function tail(argv, n)
  return table.concat({ unpack(argv, #argv - n + 1) }, " ")
end
local telemetry = { status_path = "S" }
assert(table.concat(build.codex({ telemetry = telemetry }), " ") == "remuda _codex_tui --status S")
assert(tail(build.codex({ telemetry = telemetry, model = "gpt-5.5" }), 2) == "--model gpt-5.5")
assert(tail(build.claude({ name = "c", system_prompt = "p" }), 1) == "p")
assert(tail(build.claude({ name = "c", system_prompt = "p", model = "opus" }), 2) == "--model opus")
print("ok")
