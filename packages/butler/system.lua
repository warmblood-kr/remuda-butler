-- Operating-system words used by Butler. Keep platform checks and differences here.
local function missing_command(message)
  message = tostring(message or ""):lower()
  return message:find("os error 2", 1, true) ~= nil
    or message:find("no such file or directory", 1, true) ~= nil
    or message:find("cannot find the file specified", 1, true) ~= nil
    or message:find("cannot find the path specified", 1, true) ~= nil
end

local function process_runs(path, arguments)
  if not (remuda.process and type(remuda.process.run) == "function") then
    return false, "process.run is unavailable"
  end
  local argv = { path }
  for _, argument in ipairs(arguments or {}) do argv[#argv + 1] = argument end
  local ok, result = pcall(remuda.process.run, { argv = argv, timeout = 5 })
  if ok or not missing_command(result) then return true end
  return false, tostring(result)
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function split(value, delimiter)
  local parts = {}
  for part in (tostring(value or "") .. delimiter):gmatch("(.-)" .. delimiter) do
    if part ~= "" then parts[#parts + 1] = part end
  end
  return parts
end

local function windows_join(directory, name)
  if directory:sub(-1) == "\\" or directory:sub(-1) == "/" then return directory .. name end
  return directory .. "\\" .. name
end

local windows = {}
function windows.find_command(name, context)
  context = context or {}
  local path = context.path or ""
  local extensions = context.pathext or ".COM;.EXE;.BAT;.CMD"
  local names = { name }
  if not name:match("%.[^\\/]+$") then
    for _, extension in ipairs(split(extensions, ";")) do
      names[#names + 1] = name .. extension:lower()
    end
  end
  local explicit = name:find("[/\\\\]") ~= nil
  local directories = explicit and { false } or split(path, ";")
  local exists = context.exists or file_exists
  local run = context.run or process_runs
  for _, directory in ipairs(directories) do
    for _, candidate_name in ipairs(names) do
      local candidate = explicit and candidate_name or windows_join(directory, candidate_name)
      if exists(candidate) then
        local runnable, reason = run(candidate)
        if runnable then return candidate end
        if reason then path = reason end
      end
    end
  end
  return nil, tostring(path ~= "" and path or (name .. " not found in PATH"))
end

local posix = {}
function posix.find_command(name, context)
  context = context or {}
  local explicit = name:find("/", 1, true) ~= nil
  local directories = explicit and { false } or split(context.path or "", ":")
  local executable = context.is_executable
  local run = context.run or process_runs
  local last_reason
  for _, directory in ipairs(directories) do
    local candidate = explicit and name or (directory .. "/" .. name)
    if not executable or executable(candidate) then
      local runnable, reason = run(candidate)
      if runnable then return candidate end
      last_reason = reason or last_reason
    end
  end
  return nil, last_reason or (name .. " not found in PATH")
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function posix.run_in(directory, argv)
  local words = { "cd", shell_quote(directory), "&&" }
  for _, word in ipairs(argv or {}) do words[#words + 1] = shell_quote(word) end
  local ok, why, code = os.execute(table.concat(words, " "))
  if ok == true or ok == 0 then return true end
  return nil, "Butler topic command failed (" .. tostring(why) .. " " .. tostring(code) .. ")"
end

local windows_selected = package.config:sub(1, 1) == "\\"
local selected = windows_selected and windows or posix
local system = { windows = windows, posix = posix }
function system.platform() return windows_selected and "windows" or "posix" end
function system.is_absolute(path)
  if type(path) ~= "string" then return false end
  if windows_selected then return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil end
  return path:sub(1, 1) == "/"
end
function system.home()
  local home = os.getenv("HOME")
  if home and home ~= "" then return home end
  home = os.getenv("USERPROFILE")
  if home and home ~= "" then return home end
  error("HOME and USERPROFILE are not set.\nNext: set HOME or USERPROFILE, then restart Butler", 0)
end
function system.mkdir_p(path)
  assert(type(remuda.mkdir) == "function", "remuda.mkdir is unavailable")
  return remuda.mkdir(path)
end
function system.find_command(name)
  local core_system = remuda.system
  if type(core_system) == "table" and type(core_system.find_command) == "function" then
    return core_system.find_command(name)
  end
  local arguments = name == "claude" and { "auth", "status" }
    or (name == "codex" and { "login", "status" } or { "--version" })
  local function run(candidate) return process_runs(candidate, arguments) end
  return selected.find_command(name, {
    path = os.getenv("PATH"),
    pathext = os.getenv("PATHEXT"),
    exists = file_exists,
    is_executable = nil,
    run = run,
  })
end
function system.run_in(directory, argv)
  if windows_selected then
    return nil, "Butler topic templates cannot run commands with this core on Windows.\n"
      .. "Next: update Remuda after core process.run gains cwd support"
  end
  return posix.run_in(directory, argv)
end

remuda._butler_system = system
return system
