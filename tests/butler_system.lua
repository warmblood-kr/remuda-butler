-- Pure Lua contract tests for packages/butler/system.lua.
local original_execute, original_popen, original_getenv = os.execute, io.popen, os.getenv
os.execute = function() error("os.execute must not be used for lookup") end
io.popen = function() error("io.popen must not be used for lookup") end

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
assert(type(system.launch_failure_lines) == "function")

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

local lines = system.launch_failure_lines({
  { kind = "claude", reason = "not_found", detail = "claude missing" },
  { kind = "codex", reason = "spawn_error", detail = "failed to start" },
})
assert(type(lines) == "table" and #lines >= 3, "failure renderer should return per-agent lines and a Next line")
assert(lines[1]:find("claude", 1, true) and lines[1]:find("not_found", 1, true))
assert(lines[2]:find("codex", 1, true) and lines[2]:find("spawn_error", 1, true))
assert(lines[#lines]:find("Next:", 1, true), "failure renderer must end with a Next line")

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
assert(system.home() == nil, "home should be nil when HOME and USERPROFILE are unset")

os.execute, io.popen, os.getenv = original_execute, original_popen, original_getenv
print("ok - system module command lookup, failure lines, and home contract")
