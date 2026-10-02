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
  if type(fs) ~= "table" or type(fs.realpath) ~= "function" then return false end
  return fs.realpath(path) ~= nil
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

remuda._butler_system = system
return system
