-- The runtime directory, server name and token go into JSON and TOML strings
-- for the agents' MCP config. A Windows path has backslashes; a quote is legal.
-- main.lua stops early in test mode, so this checks the helper and that the
-- three builders use it for every value. Run: luajit tests/agent_mcp_escape.lua
remuda = { _butler_test_mode = true }
dofile("packages/butler/system.lua")
dofile("packages/butler/paths.lua")
local json_quote = remuda._butler_paths.json_quote
assert(json_quote([[C:\Users\name "x"\remuda]]) == [["C:\\Users\\name \"x\"\\remuda"]],
  "backslash and quote are escaped (valid for a JSON string and a TOML basic string)")

local source = assert(io.open("packages/butler/main.lua")):read("*a")
local first = assert(source:find("local function agent_mcp_json", 1, true))
local last = assert(source:find("remuda._butler_agent_builders = ", first, true))
local builders = source:sub(first, last)
for _, value in ipairs({ "runtime_dir", "server", "token" }) do
  local raw = builders:find([['"' .. ]] .. value .. " .. '", 1, true)
    or builders:find([["' .. ]] .. value .. " .. '", 1, true)
  assert(not raw, value .. " is concatenated between quotes without json_quote")
  assert(builders:find("json_quote(" .. value .. ")", 1, true), value .. " must go through json_quote")
end
print("ok - agent MCP values are escaped for JSON and TOML")
