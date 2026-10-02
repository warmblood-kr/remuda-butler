local builders = assert(remuda._butler_agent_builders)
local startup = assert(remuda._butler_agent_startup)

builders.monocle = function(spec)
  local argv = { "monocle", "agent" }
  if type(spec.cwd) == "string" and spec.cwd ~= "" then
    argv[#argv + 1] = "--workdir"
    argv[#argv + 1] = spec.cwd
  end
  argv[#argv + 1] = "--session"
  argv[#argv + 1] = spec.name
  argv[#argv + 1] = "--auto-approve"
  if spec.model and spec.model ~= "" then
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = spec.model
  end
  return argv
end

local function last_non_empty_line(screen)
  local last
  for line in tostring(screen or ""):gmatch("[^\r\n]+") do
    if line:find("%S") then last = line end
  end
  return last
end

local function ready(screen)
  local last = last_non_empty_line(screen)
  return last ~= nil and last:sub(1, #"❯") == "❯"
end

startup.monocle = {
  ready = ready,
  working = function(screen) return not ready(screen) end,
  login = { "monocle login" },
}
