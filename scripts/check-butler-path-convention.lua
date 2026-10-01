-- Check that the installer, Butler package, and optional core share paths.
-- Run inside an isolated daemon with:
--   remuda -s CHECKER -e 'if not dofile(".../check-butler-path-convention.lua") then error("path check failed", 0) end'

local root = os.getenv("REMUDA_BUTLER_REPO_ROOT")
if not root then
  local debug_api = rawget(_G, "debug")
  local source = debug_api and debug_api.getinfo(1, "S").source
  root = source and source:match("^@(.+)/scripts/[^/]+$")
end
assert(root, "set REMUDA_BUTLER_REPO_ROOT or run this file by absolute path")
local installer_path = root .. "/install/install-butler.sh"
local main_path = root .. "/packages/butler/paths.lua"
local system_path = root .. "/packages/butler/system.lua"
local core_root = os.getenv("REMUDA_CORE_ROOT")
local daemon_path = core_root and (core_root:gsub("^~/", (os.getenv("HOME") or "") .. "/") .. "/native/src/daemon.rs")

local function read(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function unique_matches(text, pattern)
  local found = {}
  for value in text:gmatch(pattern) do found[value] = true end
  return found
end

local function sorted(set)
  local values = {}
  for value in pairs(set) do values[#values + 1] = value end
  table.sort(values)
  return values
end

local function show(values)
  local quoted = {}
  for i, value in ipairs(values) do quoted[i] = "'" .. value .. "'" end
  return "[" .. table.concat(quoted, ", ") .. "]"
end

local function fail(lines, heading)
  io.stderr:write(heading, "\n")
  for _, line in ipairs(lines) do io.stderr:write("  - ", line, "\n") end
end

local standalone = arg and arg[0] and arg[0]:match("check%-butler%-path%-convention%.lua$") ~= nil
local function failed()
  if standalone then os.exit(1) end
  return false
end

local installer, main, system_source = read(installer_path), read(main_path), read(system_path)
for _, item in ipairs({ { installer_path, installer }, { main_path, main }, { system_path, system_source } }) do
  if not item[2] then
    io.stderr:write("missing ", item[1]:sub(#root + 2), "\n")
    return false
  end
end

local sh_start = installer:find('config_home="${XDG_CONFIG_HOME:-$HOME', 1, true)
local sh_fallback
if sh_start then
  local value_start = sh_start + #'config_home="${XDG_CONFIG_HOME:-$HOME'
  local value_end = installer:find("}", value_start, true)
  if value_end then sh_fallback = installer:sub(value_start, value_end - 1) end
end
local sh_segments = unique_matches(installer, '%$config_home(/remuda/butler/[%w_]+)')
local lua_fallback = main:match('local home = system%.home%(%).-return home%s*%.%.%s*"([^"]*)"')
local lua_join = main:match('config_home%s*%.%.%s*"(/remuda/butler/)"%s*%.%.%s*filename')
local lua_filenames = {}
for filename in main:gmatch('resolve_path%("REMUDA_BUTLER_[%w_]+",%s*"(%w+)"') do
  lua_filenames[filename] = true
end

local problems = {}
if not sh_fallback then
  problems[#problems + 1] = 'install-butler.sh: could not find the XDG_CONFIG_HOME:-$HOME fallback -- parser or convention changed'
end
if not next(sh_segments) then
  problems[#problems + 1] = 'install-butler.sh: found no $config_home/remuda/butler/<name> segment -- parser or convention changed'
end
if not lua_fallback then
  problems[#problems + 1] = "paths.lua: could not find default_config_home()'s system.home() fallback -- parser or convention changed"
end
if not system_source:find('os.getenv("HOME")', 1, true)
    or not system_source:find('os.getenv("USERPROFILE")', 1, true) then
  problems[#problems + 1] = "system.lua: system.home() must resolve HOME and USERPROFILE"
end
if not lua_join then
  problems[#problems + 1] = 'paths.lua: could not find resolve_path()\'s config_home .. "/remuda/butler/" .. filename join -- parser or convention changed'
end
if not next(lua_filenames) then
  problems[#problems + 1] = 'paths.lua: found no resolve_path(...) call site naming a filename -- parser or convention changed'
end
if #problems > 0 then
  fail(problems, "could not extract the path convention from one or both sides:")
  return failed()
end

local lua_segments = {}
for filename in pairs(lua_filenames) do lua_segments[lua_join .. filename] = true end
if sh_fallback ~= lua_fallback then
  problems[#problems + 1] = "config-home suffix diverged: install-butler.sh uses $HOME" .. sh_fallback .. ", paths.lua's default_config_home() uses system.home()" .. lua_fallback
end
local sh_list, lua_list = sorted(sh_segments), sorted(lua_segments)
if table.concat(sh_list, "\0") ~= table.concat(lua_list, "\0") then
  problems[#problems + 1] = "remuda/butler path segments diverged: install-butler.sh has " .. show(sh_list) .. ", paths.lua has " .. show(lua_list)
end
if #problems > 0 then
  fail(problems, "install-butler.sh and paths.lua no longer agree on the Butler path convention:")
  io.stderr:write("\npaths.lua's default lookup and install-butler.sh's canonical-copy target must resolve to the same path below their home directory, or the daemon will never find what the installer wrote there -- fix whichever side changed.\n")
  return failed()
end
io.stdout:write("ok — install-butler.sh and paths.lua agree: system.home()", sh_fallback, " fallback, segments ", show(sh_list), "\n")

if not daemon_path or not read(daemon_path) then
  io.stdout:write("ok — core daemon loader check skipped; set REMUDA_CORE_ROOT to a Remuda checkout to enable it\n")
  return true
end
local daemon = read(daemon_path)
local sh_init_target = installer:match('init_lua="%$config_home(/remuda/init%.lua)"')
local rust_fallback = daemon:match('var_os%("HOME"%)%?%)%.join%("([^"]*)"%)')
local rust_segments = {}
for first, second in daemon:gmatch('config_home%.join%("(%w+)"%)%.join%("([%w%.]+)"%)') do
  rust_segments[#rust_segments + 1] = first .. "/" .. second
end
local problems2 = {}
if not sh_init_target then problems2[#problems2 + 1] = 'install-butler.sh: could not find the init_lua="$config_home/remuda/init.lua" write target -- parser or convention changed' end
if not rust_fallback then problems2[#problems2 + 1] = 'daemon.rs: could not find user_config_path()\'s HOME fallback -- parser or convention changed' end
if #rust_segments == 0 then problems2[#problems2 + 1] = 'daemon.rs: could not find user_config_path()\'s config_home.join("remuda").join("init.lua") -- parser or convention changed' end
if #problems2 > 0 then
  fail(problems2, "could not extract the init.lua path convention from one or both sides:")
  return failed()
end
local rust_init_target = "/" .. rust_segments[1]
local rust_home = "/" .. rust_fallback
if sh_fallback ~= rust_home then
  problems2[#problems2 + 1] = "HOME fallback diverged: install-butler.sh uses $HOME" .. sh_fallback .. ", daemon.rs's user_config_path() uses $HOME" .. rust_home
end
if sh_init_target ~= rust_init_target then
  problems2[#problems2 + 1] = "init.lua path diverged: install-butler.sh writes $config_home" .. sh_init_target .. ", daemon.rs reads $config_home" .. rust_init_target
end
if #problems2 > 0 then
  fail(problems2, "install-butler.sh and daemon.rs no longer agree on the init.lua path convention:")
  io.stderr:write("\ndaemon.rs's user_config_path() and install-butler.sh's write target must resolve to the same path, or a fresh daemon will never read what the installer wrote there -- fix whichever side changed.\n")
  return false
end
io.stdout:write("ok — install-butler.sh and daemon.rs agree: $HOME", rust_home, " fallback, init.lua at $config_home", rust_init_target, "\n")
return true
