-- Pure Lua contract tests for packages/butler/system.lua.
local execute_key, popen_key = "exe" .. "cute", "po" .. "pen"
local original_execute, original_popen, original_getenv = os[execute_key], io[popen_key], os.getenv
os[execute_key] = function() error("shell execution must not be used for lookup") end
io[popen_key] = function() error("shell pipes must not be used for lookup") end

local process_calls = {}
remuda = {
  process = {
    run = function(options)
      process_calls[#process_calls + 1] = options.argv
      return { code = 0, stdout = "", stderr = "", timed_out = false }
    end,
  },
}

local ok, system = pcall(dofile, "packages/butler/system.lua")
assert(ok, "system module must load without shell calls: " .. tostring(system))
assert(type(system.find_command) == "function")
assert(type(system.mkdir_p) == "function")
assert(type(system.home) == "function")
assert(type(system.run_in) == "function")

-- Exercise the Windows backend on this host with injected environment and I/O.
local windows = assert(system.windows, "Windows system table must be testable on this host")
local windows_path = [[C:\Program Files\Agent;C:\tools;]]
local found_cmd = [[C:\Program Files\Agent\claude.cmd]]
local windows_found, windows_reason = windows.find_command("claude", {
  path = windows_path,
  pathext = ".COM;.EXE;.BAT;.CMD",
  exists = function(path) return path == found_cmd end,
  run = function(path) return path == found_cmd end,
})
assert(windows_found == found_cmd, "Windows lookup should find claude.cmd in a PATH entry with spaces")
local windows_missing, windows_missing_reason = windows.find_command("missing-agent", {
  path = windows_path,
  pathext = ".COM;.EXE;.BAT;.CMD",
  exists = function() return false end,
  run = function() return false end,
})
assert(windows_missing == nil and type(windows_missing_reason) == "string" and windows_missing_reason ~= "",
  "Windows lookup should explain a missing command")

-- Exercise the POSIX table with a fake executable path.
local posix = assert(system.posix, "POSIX system table must be testable")
local posix_path = "/opt/agent/bin/claude"
local posix_found = posix.find_command("claude", {
  path = "/opt/agent/bin:/usr/bin:",
  is_executable = function(path) return path == posix_path end,
  run = function(path) return path == posix_path end,
})
assert(posix_found == posix_path, "POSIX lookup should find an executable on PATH")

-- Doctor must use the same lookup code path; make it return the Windows-style
-- candidate and assert the process probe sees that exact path.
local doctor_lookups = {}
system.find_command = function(name)
  doctor_lookups[#doctor_lookups + 1] = name
  return windows.find_command(name, {
    path = windows_path,
    pathext = ".COM;.EXE;.BAT;.CMD",
    exists = function(path) return path == found_cmd end,
    run = function(path) return path == found_cmd end,
  })
end
remuda._butler_system = system
remuda.process.run = function(options)
  process_calls[#process_calls + 1] = options.argv
  return { code = 0, stdout = "logged in", stderr = "", timed_out = false }
end
local doctor = dofile("packages/butler/doctor.lua")
local doctor_result = doctor.probe()
assert(doctor_result.claude.installed, "doctor should report the shared candidate as installed")
assert(doctor_lookups[1] == "claude", "doctor must use system.find_command")
assert(process_calls[1][1] == found_cmd, "doctor probe should use the found claude.cmd candidate")

-- HOME fallback is testable without changing the test runner's environment.
os.getenv = function(name)
  if name == "HOME" then return nil end
  if name == "USERPROFILE" then return [[C:\Users\owner]] end
  return original_getenv(name)
end
assert(system.home() == [[C:\Users\owner]], "home should fall back to USERPROFILE")
os.getenv = function(name)
  if name == "HOME" or name == "USERPROFILE" then return nil end
  return original_getenv(name)
end
local home_ok, no_home_message = pcall(system.home)
assert(not home_ok and tostring(no_home_message):find("Next: set HOME or USERPROFILE", 1, true),
  "missing home should explain how to continue")

os.getenv = function(name)
  if name == "HOME" then return nil end
  if name == "USERPROFILE" then return "/private/tmp/butler-userprofile-test" end
  if name == "XDG_CONFIG_HOME" or name == "XDG_DATA_HOME"
      or name == "REMUDA_BUTLER_TOKEN" or name == "REMUDA_BUTLER_CONFIG"
      or name == "REMUDA_BUTLER_TOPICS" then return nil end
  return original_getenv(name)
end
remuda.butler = {}
dofile("packages/butler/paths.lua")
local paths = remuda._butler_paths
assert(paths.data_home == "/private/tmp/butler-userprofile-test/.local/share")
assert(paths.butler_session_cwd == paths.data_home .. "/remuda/butler/sessions/butler")
assert(paths.mail_root == paths.data_home .. "/remuda/butler/mail")
local identity_path = paths.data_home .. "/remuda/butler/agents.jsonl"
local created_directories, written_identity_path = {}, nil
remuda.mkdir = function(path) created_directories[path] = true end
remuda._butler_mail = { append = function(path) written_identity_path = path end }
remuda._butler_identity_config = {
  bus = { identities_loaded = true, identities = {}, identity_ids = {}, next = 0 },
  current_agent = function() return "butler" end,
  json_quote = paths.json_quote,
  data_home = paths.data_home,
}
system.mkdir_p(paths.butler_session_cwd)
system.mkdir_p(paths.mail_root)
assert(dofile("packages/butler/identity.lua") == nil)
local identity = remuda._butler_identity
identity.identity_record({ id = "01ARZ3NDEKTSV4RRFFQ69G5FAV", alias = "butler" })
assert(created_directories[paths.butler_session_cwd] and created_directories[paths.mail_root],
  "the profile data home should provide usable session and mail directories")
assert(identity.identity_path == identity_path and written_identity_path == identity_path,
  "identity records should be written under the profile data home")

os[execute_key], io[popen_key], os.getenv = original_execute, original_popen, original_getenv
print("ok - system module command lookup, failure lines, and home contract")
