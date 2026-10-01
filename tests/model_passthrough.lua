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
assert(tail(build.claude({ name = "c", system_prompt = "p" }), 2) == "--model opus")
assert(tail(build.claude({ name = "c", system_prompt = "p", model = "opus" }), 2) == "--model opus")
assert(tail(build.claude({ name = "c", system_prompt = "p" }), 2) == "--model opus",
  "Claude launch without an assigned model must use Butler's explicit default")

-- Native autocompact is opt-in to the installed Claude CLI capability. The
-- probe is argv-only, cached, and does not affect Codex launches.
local probes = 0
remuda._butler_compaction_config = { claude_autocompact = "600k" }
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
assert(contains_pair(claude_argv, "--autocompact", "600k"),
  "supported Claude launch should receive configured native autocompact")
local unsupported_argv = build.claude({ name = "c", system_prompt = "p" })
assert(probes == 1 and contains_pair(unsupported_argv, "--autocompact", "600k"),
  "Claude capability probe should be cached")
local codex_argv = build.codex({ telemetry = telemetry })
assert(not contains_pair(codex_argv, "--autocompact", "600k"),
  "Codex launch must never receive Claude autocompact")
remuda._butler_compaction_config = { claude_autocompact = "600k" }
remuda._butler_claude_autocompact_supported = nil
remuda.process = { run = function() probes = probes + 1; return { stdout = "help" } end }
assert(not contains_pair(build.claude({ name = "c", system_prompt = "p" }), "--autocompact", "600k"),
  "unsupported Claude CLI should omit native autocompact")
-- #201: a Codex member gets the remuda MCP server only when it has a token
-- and the installed core forwards `-c KEY=VALUE`. The probe is argv-only and
-- cached; without both, the argv is exactly the old one.
local codex_probes, codex_help = 0, "usage: remuda _codex_tui --status PATH [--model M] [-c KEY=VALUE]..."
remuda._butler_agent_support.mcp_flags = function(token)
  return { "-c", 'mcp_servers.remuda.command="remuda"', "-c", "mcp_servers.remuda.env={T=" .. token .. "}" }
end
remuda._butler_codex_config_supported = nil
remuda.process = { run = function(spec)
  codex_probes = codex_probes + 1
  assert(table.concat(spec.argv, " ") == "remuda _codex_tui --help" and spec.timeout == 5)
  return { stdout = "", stderr = codex_help }
end }
assert(table.concat(build.codex({ telemetry = telemetry }), " ") == "remuda _codex_tui --status S"
  and codex_probes == 0, "Codex launch without a token must be unchanged and must not probe")
local mcp_tail = ' -c mcp_servers.remuda.command="remuda" -c mcp_servers.remuda.env={T=tok}'
assert(table.concat(build.codex({ telemetry = telemetry, token = "tok" }), " ")
  == "remuda _codex_tui --status S" .. mcp_tail, "supported core should receive the MCP flags")
assert(table.concat(build.codex({ telemetry = telemetry, token = "tok", model = "gpt-5.5" }), " ")
  == "remuda _codex_tui --status S --model gpt-5.5" .. mcp_tail, "MCP flags follow the model")
assert(codex_probes == 1, "Codex capability probe should be cached")
remuda._butler_codex_config_supported = nil
codex_help = "remuda: Codex TUI needs --status PATH"
assert(table.concat(build.codex({ telemetry = telemetry, token = "tok" }), " ")
  == "remuda _codex_tui --status S", "an old core must get the old argv")
local warned
remuda._butler_codex_config_supported = nil
remuda.log = function(level, text) warned = level .. " " .. text end
remuda.process = { run = function() error("spawn failed") end }
assert(table.concat(build.codex({ telemetry = telemetry, token = "tok" }), " ")
  == "remuda _codex_tui --status S", "a failed probe must get the old argv")
assert(warned and warned:find("^warn ") and not warned:find("tok", 1, true), "a failed probe is logged without the token")
print("ok")
