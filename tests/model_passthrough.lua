-- A member's model reaches its agent's argv.
-- Run from the repo root: luajit tests/model_passthrough.lua
remuda = {
  _butler_agent_builders = {},
  _butler_agent_startup = {},
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
assert(tail(build.claude({ name = "c", system_prompt = "p" }), 2) == "--model sonnet",
  "Claude launch without an assigned model must use Butler's explicit default")

-- Native autocompact is opt-in to the installed Claude CLI capability. The
-- probe is argv-only, cached, and does not affect Codex launches.
local probes = 0
remuda._butler_compaction_config = { claude_autocompact = "400k" }
remuda._butler_claude_autocompact_supported = nil
remuda.process = { run = function(spec)
  probes = probes + 1
  assert(spec.argv[1] == "claude" and spec.argv[2] == "--help")
  assert(spec.timeout == 5)
  return { stdout = "--autocompact <auto|100k-1M>" }
end }
local claude_argv = build.claude({ name = "c", system_prompt = "p" })
local function contains_pair(argv, a, b)
  for i = 1, #argv - 1 do if argv[i] == a and argv[i + 1] == b then return true end end
  return false
end
assert(contains_pair(claude_argv, "--autocompact", "400k"),
  "supported Claude launch should receive configured native autocompact")
local unsupported_argv = build.claude({ name = "c", system_prompt = "p" })
assert(probes == 1 and contains_pair(unsupported_argv, "--autocompact", "400k"),
  "Claude capability probe should be cached")
local codex_argv = build.codex({ telemetry = telemetry })
assert(not contains_pair(codex_argv, "--autocompact", "400k"),
  "Codex launch must never receive Claude autocompact")
remuda._butler_compaction_config = { claude_autocompact = "400k" }
remuda._butler_claude_autocompact_supported = nil
remuda.process = { run = function() probes = probes + 1; return { stdout = "help" } end }
assert(not contains_pair(build.claude({ name = "c", system_prompt = "p" }), "--autocompact", "400k"),
  "unsupported Claude CLI should omit native autocompact")
print("ok")
