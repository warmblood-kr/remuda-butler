-- Operating-system words used by Butler. Keep platform checks and differences here.
local function file_exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  local ok, contents, reason = pcall(file.read, file, 1)
  file:close()
  if not ok then return false end
  return contents ~= nil or reason == nil
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
local function windows_absolute(directory)
  return directory:match("^%a:[/\\]") ~= nil or directory:match("^[/\\][/\\]") ~= nil
end
function windows.find_command(name, context)
  context = context or {}
  local path = context.path or ""
  -- Same rule as cmd.exe and core's lookup: an unset or empty PATHEXT means the
  -- default list, and a name is tried as given only when it already ends in one
  -- of those extensions. An npm install puts an extensionless sh script next to
  -- NAME.cmd; Windows cannot start that file.
  local extensions = {}
  for _, extension in ipairs(split(context.pathext or "", ";")) do
    if extension:sub(1, 1) == "." and #extension > 1 then extensions[#extensions + 1] = extension end
  end
  if #extensions == 0 then extensions = split(".COM;.EXE;.BAT;.CMD", ";") end
  local names = {}
  local lower = name:lower()
  for _, extension in ipairs(extensions) do
    if lower:sub(-#extension) == extension:lower() then names = { name }; break end
  end
  if #names == 0 then
    for _, extension in ipairs(extensions) do names[#names + 1] = name .. extension:lower() end
  end
  local explicit = name:find("[/\\\\]") ~= nil
  if explicit then
    if windows_absolute(name) and (context.exists or file_exists)(name) then return name end
    return nil, name .. " not found in PATH"
  end
  local directories = {}
  for _, directory in ipairs(split(path, ";")) do
    directory = directory:match('^"(.*)"$') or directory
    if windows_absolute(directory) then directories[#directories + 1] = directory end
  end
  local exists = context.exists or file_exists
  for _, directory in ipairs(directories) do
    for _, candidate_name in ipairs(names) do
      local candidate = windows_join(directory, candidate_name)
      if exists(candidate) then return candidate end
    end
  end
  return nil, name .. " not found in PATH"
end

local posix = {}
local function posix_absolute(directory)
  return directory:sub(1, 1) == "/"
end
function posix.find_command(name, context)
  context = context or {}
  local explicit = name:find("/", 1, true) ~= nil
  local exists = context.exists or file_exists
  if explicit then
    if posix_absolute(name) and exists(name) then return name end
    return nil, name .. " not found in PATH"
  end
  local directories = {}
  for _, directory in ipairs(split(context.path or "", ":")) do
    if posix_absolute(directory) then directories[#directories + 1] = directory end
  end
  for _, directory in ipairs(directories) do
    local candidate = directory .. "/" .. name
    if exists(candidate) then return candidate end
  end
  return nil, name .. " not found in PATH"
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
-- Trace details can contain paths copied from the environment. Keep one record
-- to one line and bound the bytes written even when a path is unusually long.
function system.trace_detail(value)
  value = tostring(value or "")
  local parts, size = {}, 0
  for index = 1, #value do
    local byte = value:byte(index)
    local part = (byte < 32 or byte == 127) and string.format("\\x%02X", byte) or value:sub(index, index)
    if size + #part > 509 then
      parts[#parts + 1] = "..."
      break
    end
    parts[#parts + 1] = part
    size = size + #part
  end
  return table.concat(parts)
end
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
  return selected.find_command(name, {
    path = os.getenv("PATH"),
    pathext = os.getenv("PATHEXT"),
    exists = file_exists,
  })
end
-- The OS secure store (core's remuda.system.credential): put, delete and a probe.
-- There is no word here that reads a secret back, and there must not be one.
local function credential_store()
  local core_system = remuda.system
  local store = type(core_system) == "table" and core_system.credential
  if type(store) ~= "table" or type(store.backend) ~= "function" then return nil end
  local ok, backend = pcall(store.backend)
  if not ok or type(backend) ~= "string" or backend == "" then return nil end
  return store, backend
end
local function credential_call(word, ...)
  local store, backend = credential_store()
  if not store or type(store[word]) ~= "function" then return nil, "no store" end
  local ok, done, reason = pcall(store[word], ...)
  if not ok then return nil, "unavailable: the OS secure store raised an error" end
  if done ~= true then return nil, type(reason) == "string" and reason or "unavailable" end
  return true, backend
end
-- The store's name ("keychain", "wincred"), or nil when the caller must use a file.
function system.credential_backend()
  local _, backend = credential_store()
  return backend
end
-- true, backend | nil, reason ("no store", or core's not_found / unavailable: / denied:).
function system.credential_put(name, secret) return credential_call("put", name, secret) end
function system.credential_delete(name) return credential_call("delete", name) end
-- Core's per-user directory for `kind`, "<base>/remuda" (remuda.storage.dir),
-- or nil on a core without the word or when it cannot say.
function system.storage_dir(kind)
  local storage = remuda.storage
  if type(storage) ~= "table" or type(storage.dir) ~= "function" then return nil end
  local ok, dir = pcall(storage.dir, kind)
  return ok and type(dir) == "string" and dir ~= "" and dir or nil
end
-- A directory test that works on Windows too; every core with storage.dir has fs.realpath.
local function path_exists(path)
  local fs = remuda.fs
  -- Without a way to check, preserve the old location rather than risk hiding
  -- data. realpath's nil reason distinguishes a missing path from other errors.
  if type(fs) ~= "table" or type(fs.realpath) ~= "function" then return true end
  local resolved, reason = fs.realpath(path)
  if resolved ~= nil then return true end
  return type(reason) ~= "string" or reason:sub(1, 9) ~= "not_found"
end
-- The directory that holds remuda/: core's where it has one, else `legacy_home`
-- (Butler's own XDG/HOME rule). Data made under the old rule is kept until it is
-- moved: then the second value is a note naming both places.
function system.data_home(legacy_home, exists)
  local core = system.storage_dir("data")
  local base = core and core:match("^(.+)[/\\]remuda[/\\]?$")
  if not base or base == legacy_home then return legacy_home end
  exists = exists or path_exists
  if not legacy_home then return base end
  -- A check that raises must not stop Butler loading: the old home is used.
  local ok, keep = pcall(function()
    return exists(legacy_home .. "/remuda/butler") and not exists(base .. "/remuda/butler")
  end)
  if not ok then return legacy_home end
  if keep then return legacy_home, "kept " .. legacy_home .. "/remuda/butler; core's data directory is " .. core end
  return base
end
function system.run_in(directory, argv)
  if windows_selected then
    return nil, "Butler topic templates cannot run commands with this core on Windows.\n"
      .. "Next: update Remuda after core process.run gains cwd support"
  end
  return posix.run_in(directory, argv)
end

local function read_all(path)
  local ok, file = pcall(io.open, path, "rb")
  if not ok or not file then return nil end
  local read_ok, contents = pcall(file.read, file, 8192)
  pcall(file.close, file)
  return read_ok and type(contents) == "string" and contents:sub(1, 8192) or nil
end

local function command_output(run, argv)
  if type(run) ~= "function" then return nil end
  local ok, result = pcall(run, { argv = argv, timeout = 2 })
  if not ok or type(result) ~= "table" or result.code ~= 0 then return nil end
  return type(result.stdout) == "string" and result.stdout:sub(1, 8192) or nil
end

local function load_value(text)
  local value = type(text) == "string" and text:match("^[%s{]*(%d+%.?%d*)")
  value = tonumber(value)
  if not value or value ~= value or value < 0 or value > 1000 then
    return nil
  end
  return string.format("%.2f", value)
end

local function percent(used, total)
  used, total = tonumber(used), tonumber(total)
  if not used or not total or used < 0 or total <= 0
      or used ~= used or total ~= total
      or used == math.huge or total == math.huge then
    return nil
  end
  local ratio = used / total
  if ratio ~= ratio or ratio == math.huge then return nil end
  local value = math.floor(ratio * 100 + 0.5)
  if value < 0 or value > 100 then return nil end
  return string.format("%d%%", value)
end

local function linux_memory(text)
  if type(text) ~= "string" then return nil end
  local values = {}
  for name, amount in text:gmatch("([%w_]+):%s*(%d+)%s*kB") do
    values[name] = tonumber(amount)
  end
  if not values.MemTotal or not values.MemAvailable
      or values.MemAvailable > values.MemTotal then
    return nil
  end
  return percent(values.MemTotal - values.MemAvailable, values.MemTotal)
end

local function darwin_memory(vm, total)
  if type(vm) ~= "string" then return nil end
  local free = tonumber(vm:match("Pages free:%s*(%d+)"))
  local inactive = tonumber(vm:match("Pages inactive:%s*(%d+)"))
  local speculative = tonumber(vm:match("Pages speculative:%s*(%d+)"))
  total = tonumber(total)
  if not free or not inactive or not speculative or not total or total <= 0
      or total == math.huge then return nil end
  local page_size = tonumber(vm:match("page size of (%d+) bytes")) or 4096
  local available = (free + inactive + speculative) * page_size
  if available > total then return nil end
  return percent(total - available, total)
end

local function disk_used(text)
  if type(text) ~= "string" then return nil end
  local first = true
  for line in text:gmatch("[^\r\n]+") do
    if first then
      first = false
    else
      local fields = {}
      for field in line:gmatch("%S+") do fields[#fields + 1] = field end
      local capacity = fields[5] and fields[5]:match("^(%d+)%%$")
      if capacity and tonumber(capacity) <= 100 then return capacity .. "%" end
    end
  end
  return nil
end

-- Read only bounded OS counters. Optional readers make the parsers testable;
-- failures are isolated so a missing source affects only its own value.
function system.status_metrics(readers)
  readers = type(readers) == "table" and readers or {}
  local read_file = readers.read_file or read_all
  local run = readers.run
  if type(run) ~= "function" then
    local process = type(remuda) == "table" and remuda.process or nil
    run = type(process) == "table" and process.run or nil
  end
  local function read(path)
    local ok, result = pcall(read_file, path)
    return ok and type(result) == "string" and result or nil
  end
  local find = readers.find_command or system.find_command
  local function run_command(argv)
    local ok, path = pcall(find, argv[1])
    if not ok or type(path) ~= "string" or path == "" then return nil end
    argv[1] = path
    return command_output(run, argv)
  end

  local load = load_value(read("/proc/loadavg"))
  if not load then
    load = load_value(run_command({ "sysctl", "-n", "vm.loadavg" }))
  end

  local mem = linux_memory(read("/proc/meminfo"))
  if not mem then
    local vm = run_command({ "vm_stat" })
    local total = run_command({ "sysctl", "-n", "hw.memsize" })
    mem = darwin_memory(vm, total)
  end

  local disk = disk_used(run_command({ "df", "-kP", "/" }))
  return { cpu = load or "n/a", mem = mem or "n/a", disk = disk or "n/a" }
end

remuda._butler_system = system
return system
