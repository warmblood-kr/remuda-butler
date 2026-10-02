local builders = assert(remuda._butler_agent_builders)
local startup = assert(remuda._butler_agent_startup)

builders.monocle = function(spec)
  assert(type(spec.name) == "string", "Monocle agent spec requires a string name")
  assert(spec.name:sub(1, 1) ~= "-", "Monocle agent name must not start with a dash")
  assert(not (type(spec.cwd) == "string" and spec.cwd:sub(1, 1) == "-"), "Monocle agent cwd must not start with a dash")
  assert(spec.model == nil or spec.model == "" or (type(spec.model) == "string" and spec.model:find("^[%w_:/][%w._:/-]*$")
    and not spec.model:find("..", 1, true) and not ("/" .. spec.model .. "/"):find("/%.%/")),
    "Monocle agent model must be a plain token")
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
