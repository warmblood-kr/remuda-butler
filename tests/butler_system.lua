-- Pure Lua contract tests for packages/butler/system.lua.
local execute_key, popen_key = "exe" .. "cute", "po" .. "pen"
local original_execute, original_popen, original_getenv, original_io_open = os[execute_key], io[popen_key], os.getenv, io.open
os[execute_key] = function() error("shell execution must not be used for lookup") end
io[popen_key] = function() error("shell pipes must not be used for lookup") end

local process_calls = 0
remuda = {
  process = {
    run = function()
      process_calls = process_calls + 1
      error("command lookup must not run candidate processes")
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
})
assert(windows_found == found_cmd, "Windows lookup should find claude.cmd in a PATH entry with spaces")
local windows_missing, windows_missing_reason = windows.find_command("missing-agent", {
  path = windows_path,
  pathext = ".COM;.EXE;.BAT;.CMD",
  exists = function() return false end,
})
assert(windows_missing == nil and type(windows_missing_reason) == "string" and windows_missing_reason ~= "",
  "Windows lookup should explain a missing command")

-- Exercise the POSIX table with a fake executable path.
local posix = assert(system.posix, "POSIX system table must be testable")
local posix_path = "/opt/agent/bin/claude"
local posix_found = posix.find_command("claude", {
  path = "/opt/agent/bin:/usr/bin:",
  exists = function(path) return path == posix_path end,
})
assert(posix_found == posix_path, "POSIX lookup should find a file on PATH")

local windows_candidates = {}
local absolute_windows = [[C:\agent-bin\claude]]
local relative_windows_found = windows.find_command("claude", {
  path = [[.;bin;C:\agent-bin]], pathext = "",
  exists = function(path) windows_candidates[#windows_candidates + 1] = path; return true end,
})
assert(relative_windows_found == absolute_windows,
  "Windows lookup should skip dot and relative PATH entries")
assert(#windows_candidates == 1 and windows_candidates[1] == absolute_windows,
  "Windows lookup should only inspect absolute PATH entries")

local posix_candidates = {}
local absolute_posix = "/opt/agent-bin/claude"
local relative_posix_found = posix.find_command("claude", {
  path = ".:bin:/opt/agent-bin",
  exists = function(path) posix_candidates[#posix_candidates + 1] = path; return true end,
})
assert(relative_posix_found == absolute_posix, "POSIX lookup should skip dot and relative PATH entries")
assert(#posix_candidates == 1 and posix_candidates[1] == absolute_posix,
  "POSIX lookup should only inspect absolute PATH entries")

-- file_exists must reject a directory even when io.open succeeds on it.
local original_test_open = io.open
io.open = function(path)
  if path == [[C:\agent-bin\claude.cmd]] then
    return { read = function() return nil, "Is a directory" end, close = function() end }
  end
  return nil, "not found"
end
local directory_candidate = windows.find_command("claude", {
  path = [[C:\agent-bin]], pathext = ".CMD",
})
io.open = original_test_open
assert(directory_candidate == nil, "a directory named like a command must not be found")

-- The selected system lookup must also be existence-only, without invoking a CLI.
os.getenv = function(name)
  if name == "PATH" then return "/lookup-only" end
  if name == "PATHEXT" then return ".CMD" end
  return original_getenv(name)
end
io.open = function(path)
  if path == "/lookup-only/claude" then
    return { read = function() return "x" end, close = function() end }
  end
  return nil, "not found"
end
local selected_found = system.find_command("claude")
io.open, os.getenv = original_io_open, original_getenv
assert(selected_found == "/lookup-only/claude", "system.find_command should return the existing candidate")
assert(process_calls == 0, "finding a command must make zero process.run calls")

-- Doctor must use the same lookup code path; make it return the Windows-style
-- candidate and assert the process probe sees that exact path.
local doctor_lookups = {}
system.find_command = function(name)
  doctor_lookups[#doctor_lookups + 1] = name
  if name ~= "claude" then return nil, "not found" end
  return windows.find_command(name, {
    path = windows_path,
    pathext = ".COM;.EXE;.BAT;.CMD",
    exists = function(path) return path == found_cmd end,
  })
end
remuda._butler_system = system
local probes_by_command = {}
remuda.process.run = function(options)
  process_calls = process_calls + 1
  local executable = options.argv[1]
  probes_by_command[executable] = (probes_by_command[executable] or 0) + 1
  if executable == "codex" then error("No such file or directory") end
  return { code = 0, stdout = "logged in", stderr = "", timed_out = false }
end
local doctor = dofile("packages/butler/doctor.lua")
local windows_doctor_names = doctor.candidate_names("claude", "windows")
assert(windows_doctor_names[1] == "claude" and windows_doctor_names[2] == "claude.cmd",
  "doctor should keep the Windows .cmd probe candidate")
local one_probe = doctor.probe_command({ "claude", "auth", "status" }, "posix")
assert(one_probe.installed and process_calls == 1,
  "doctor should make exactly one process probe for a found candidate")
process_calls, probes_by_command = 0, {}
local doctor_result = doctor.probe()
assert(doctor_result.claude.installed, "doctor should report the shared candidate as installed")
assert(not doctor_result.codex.installed, "doctor should keep a missing Codex command missing")
assert(doctor_lookups[1] == "claude", "doctor must use system.find_command")
assert(doctor_lookups[2] == "claude" and doctor_lookups[3] == "codex",
  "doctor should check both CLIs through system.find_command")
assert(process_calls == 2 and probes_by_command[found_cmd] == 1 and probes_by_command.codex == 1,
  "doctor should probe each found candidate once and use its Windows-name fallback only when lookup misses")

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
  if name == "HOME" or name == "USERPROFILE" or name == "XDG_CONFIG_HOME" or name == "XDG_DATA_HOME"
      or name == "REMUDA_BUTLER_TOKEN" or name == "REMUDA_BUTLER_CONFIG"
      or name == "REMUDA_BUTLER_TOPICS" or name == "REMUDA_BUTLER_PROJECT_HOME" then return nil end
  return original_getenv(name)
end
local no_home_paths_ok = pcall(dofile, "packages/butler/paths.lua")
assert(no_home_paths_ok, "missing HOME must not prevent Butler paths or doctor from loading")
assert(remuda._butler_paths.data_home == nil and remuda._butler_paths.topic_config.project_home == nil,
  "paths without a home should stay unresolved until a command needs them")
local no_home_doctor_ok = pcall(dofile, "packages/butler/doctor.lua")
assert(no_home_doctor_ok, "doctor must remain loadable when HOME and USERPROFILE are unset")

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

os[execute_key], io[popen_key], os.getenv, io.open = original_execute, original_popen, original_getenv, original_io_open
print("ok - system module command lookup, failure lines, and home contract")
