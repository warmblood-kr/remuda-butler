local builders = assert(remuda._butler_agent_builders)
local startup = assert(remuda._butler_agent_startup)
local telemetry = assert(remuda._butler_telemetry_adapters)

local function bottom_lines(screen)
  local lines = {}
  for line in (tostring(screen or "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local start = math.max(1, #lines - 11)
  local out = {}
  for i = start, #lines do out[#out + 1] = lines[i] end
  return out
end

local function placeholder(line)
  line = line:gsub("^%s*[│|]?%s*", ""):gsub("^[❯›>]%s*", ""):gsub("%s+$", "")
  return line == "Ask anything, / for commands, @ for context..."
    or line == "Ask anything…" or line == "Ask anything..." or line == "Ask anything"
end

telemetry.opencode = {
  setup = function(spec) return { model = spec.model } end,
  read = function(state) return { model = state.model } end,
}

builders.opencode = function(spec)
  assert(type(spec.name) == "string", "OpenCode agent spec requires a string name")
  local argv = { "opencode", "--standalone" }
  if type(spec.cwd) == "string" and spec.cwd ~= "" then argv[#argv + 1] = spec.cwd end
  return argv
end

startup.opencode = {
  -- OpenCode's idle composer uses this placeholder in its TUI. Do not treat
  -- generic banner text or an authentication screen as a ready composer.
  ready = function(screen)
    for _, line in ipairs(bottom_lines(screen)) do if placeholder(line) then return true end end
    return false
  end,
  working = function(screen)
    return screen:find("esc to interrupt", 1, true) ~= nil
  end,
  placeholders = { "Ask anything, / for commands, @ for context...", "Ask anything…", "Ask anything...", "Ask anything" },
  empty = function(screen)
    for _, line in ipairs(bottom_lines(screen)) do
      if placeholder(line) then return "EMPTY", line:gsub("^%s*[│|]?%s*", "") end
    end
    return "UNPARSEABLE", ""
  end,
  login = { "Authentication required", "Not authenticated", "Please log in" },
}
