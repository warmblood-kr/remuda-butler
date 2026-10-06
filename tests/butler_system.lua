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
local trace_detail = system.trace_detail("path\nwith\tcontrols\0")
assert(trace_detail == "path\\x0Awith\\x09controls\\x00", "trace details must escape control bytes: " .. trace_detail)
local long_trace_detail = system.trace_detail(string.rep("x", 600))
assert(#long_trace_detail == 512 and long_trace_detail:sub(-3) == "...",
  "trace details must be capped at 512 bytes")

local linux_calls = {}
local linux_metrics = system.status_metrics({
  read_file = function(path)
    if path == "/proc/loadavg" then return "1.25 0.90 0.50 2/100 42\n" end
    if path == "/proc/meminfo" then
      return "MemTotal:       1000000 kB\nMemAvailable:    375000 kB\n"
    end
  end,
  run = function(options)
    linux_calls[#linux_calls + 1] = options
    assert(options.timeout == 2, "system metrics use a short process timeout")
    assert(options.argv[1] == "df" and options.argv[2] == "-kP"
      and options.argv[3] == "/",
      "disk usage uses df with read-only arguments")
    return { code = 0, stdout = table.concat({
      "Filesystem 1024-blocks Used Available Capacity Mounted on",
      "/dev/root 100 58 42 58% /",
    }, "\n") .. "\n" }
  end,
})
assert(linux_metrics.cpu == "1.25" and linux_metrics.mem == "63%"
  and linux_metrics.disk == "58%",
  "Linux proc readers and df should produce bounded metric values")
assert(#linux_calls == 1, "Linux proc counters avoid extra commands")

local darwin_commands = {}
local darwin_metrics = system.status_metrics({
  read_file = function() error("unavailable proc reader") end,
  run = function(options)
    local argv = options.argv
    darwin_commands[#darwin_commands + 1] = table.concat(argv, " ")
    if argv[1] == "sysctl" and argv[3] == "vm.loadavg" then
      return { code = 0, stdout = "{ 0.45 0.30 0.20 }\n" }
    end
    if argv[1] == "vm_stat" then
      local output = "Mach Virtual Memory Statistics: "
        .. "(page size of 4096 bytes)\n"
        .. "Pages free: 100000.\nPages inactive: 200000.\n"
        .. "Pages speculative: 10000.\n"
      return { code = 0, stdout = output }
    end
    if argv[1] == "sysctl" and argv[3] == "hw.memsize" then
      return { code = 0, stdout = "4096000000\n" }
    end
    if argv[1] == "df" then
      local output = "Filesystem 1024-blocks Used Available Capacity "
        .. "Mounted on\n"
        .. "/dev/disk1 100 75 25 75% /\n"
      return { code = 0, stdout = output }
    end
    error("unexpected read-only command: " .. table.concat(argv, " "))
  end,
})
assert(darwin_metrics.cpu == "0.45" and darwin_metrics.mem == "69%"
  and darwin_metrics.disk == "75%",
  "Darwin sysctl, vm_stat and df readers should produce metric values")
local expected_commands = table.concat({
  "sysctl -n vm.loadavg", "vm_stat", "sysctl -n hw.memsize", "df -kP /",
}, "|")
assert(table.concat(darwin_commands, "|") == expected_commands,
  "Darwin reads use only the expected read-only commands")
local unavailable = system.status_metrics({
  read_file = function() error("no proc") end,
  run = function() error("no process API") end,
})
assert(unavailable.cpu == "n/a" and unavailable.mem == "n/a"
  and unavailable.disk == "n/a",
  "all failed readers fall back independently without raising")

local garbage = system.status_metrics({
  read_file = function(path)
    if path == "/proc/loadavg" then return "no load value" end
    if path == "/proc/meminfo" then
      return "MemTotal: 1000 kB\nMemAvailable: 2000 kB\n"
    end
  end,
  run = function(options)
    local argv = options.argv
    if argv[1] == "sysctl" and argv[3] == "vm.loadavg" then
      return { code = 0, stdout = "not a load value" }
    end
    if argv[1] == "vm_stat" then
      return { code = 0, stdout = "Pages free: 10.\nPages inactive: 20.\n" }
    end
    if argv[1] == "sysctl" and argv[3] == "hw.memsize" then
      return { code = 0, stdout = "4096000000\n" }
    end
    if argv[1] == "df" then
      local output = "Filesystem blocks Used Avail Capacity Mounted\n"
        .. "/dev/root 100 99 1 150% /\n"
      return { code = 0, stdout = output }
    end
  end,
})
assert(garbage.cpu == "n/a" and garbage.mem == "n/a" and garbage.disk == "n/a",
  "malformed counters, memory over total, and disk over 100% fall back")

for _, result in ipairs({
  { code = 1, stdout = "0.2" }, "not a process result",
}) do
  local failed = system.status_metrics({
    read_file = function() error("proc unavailable") end,
    run = function() return result end,
  })
  assert(failed.cpu == "n/a" and failed.mem == "n/a" and failed.disk == "n/a",
    "nonzero and non-table process results fall back")
end

local saved_run = remuda.process.run
local fallback_calls = {}
remuda.process.run = function(options)
  local argv = options.argv
  fallback_calls[#fallback_calls + 1] = table.concat(argv, " ")
  if argv[1] == "vm_stat" then
    return { code = 0, stdout = "Mach Virtual Memory Statistics: "
      .. "(page size of 4096 bytes)\nPages free: 100000.\n"
      .. "Pages inactive: 200000.\nPages speculative: 10000.\n" }
  end
  if argv[1] == "sysctl" and argv[3] == "hw.memsize" then
    return { code = 0, stdout = "4096000000\n" }
  end
  if argv[1] == "df" then
    local output = "Filesystem blocks Used Avail Capacity Mounted\n"
      .. "/dev/root 100 40 60 40% /\n"
    return { code = 0, stdout = output }
  end
  error("unexpected process command: " .. table.concat(argv, " "))
end
local linux_fallback = system.status_metrics({
  read_file = function(path)
    if path == "/proc/loadavg" then return "0.12 0.10 0.08 1/50 12\n" end
    return nil
  end,
})
remuda.process.run = saved_run
assert(linux_fallback.cpu == "0.12" and linux_fallback.mem == "69%"
  and linux_fallback.disk == "40%",
  "Linux memory falls back to vm_stat when proc/meminfo is unreadable")
local expected_fallback = "vm_stat|sysctl -n hw.memsize|df -kP /"
assert(table.concat(fallback_calls, "|") == expected_fallback,
  "the default reader uses remuda.process.run when no test runner is supplied")

local saved_open = io.open
local read_sizes = {}
local load_data = string.rep("x", 9000)
local memory_data = string.rep("x", 9000)
io.open = function(path)
  return {
    read = function(_, size)
      read_sizes[path] = size
      return path == "/proc/loadavg" and load_data or memory_data
    end,
    close = function() end,
  }
end
local read_ok, read_metrics = pcall(system.status_metrics, {
  run = function() error("no process API") end,
})
assert(read_ok and read_metrics.cpu == "n/a",
  "bounded file reads survive unreadable data")
assert(read_sizes["/proc/loadavg"] == 8192
  and read_sizes["/proc/meminfo"] == 8192,
  "system files are read with an 8192-byte limit")

local function file_metrics(load_text, memory_text)
  load_data, memory_data = load_text, memory_text
  local ok, metrics = pcall(system.status_metrics, {
    run = function() error("no process API") end,
  })
  assert(ok, "oversized mocked files must not raise")
  return metrics
end
local memory_header = "MemTotal: 1000 kB\nMemAvailable: 500 kB\n"
local edge_under = string.rep(" ", 8187) .. "1.25"
local edge_at = string.rep(" ", 8188) .. "1.25"
assert(#edge_under == 8191 and #edge_at == 8192,
  "load fixtures pin the read-size boundary")
local edge_metrics = file_metrics(edge_under, memory_header)
local exact_metrics = file_metrics(edge_at, memory_header)
assert(edge_metrics.cpu == "1.25" and exact_metrics.cpu == "1.25",
  "load boundary values: " .. tostring(edge_metrics.cpu) .. "/"
    .. tostring(exact_metrics.cpu))
local oversized_load = string.rep(" ", 8192) .. "1.25"
local oversized_memory = memory_header .. string.rep(" ", 8192 - #memory_header)
  .. "MemAvailable: 0 kB\n"
local truncated_files = file_metrics(oversized_load, oversized_memory)
assert(truncated_files.cpu == "n/a" and truncated_files.mem == "50%",
  "file data returned beyond byte 8192 is discarded for load and memory")
io.open = saved_open

local capped_stdout = system.status_metrics({
  read_file = function() error("proc unavailable") end,
  run = function(options)
    local argv = options.argv
    local stdout
    if argv[1] == "sysctl" and argv[3] == "vm.loadavg" then
      stdout = string.rep(" ", 8192) .. "1.25"
    elseif argv[1] == "vm_stat" then
      stdout = string.rep("x", 8192)
        .. "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n"
        .. "Pages free: 100000.\nPages inactive: 200000.\n"
        .. "Pages speculative: 10000.\n"
    elseif argv[1] == "sysctl" and argv[3] == "hw.memsize" then
      stdout = "4096000000\n"
    elseif argv[1] == "df" then
      stdout = "Filesystem blocks Used Avail Capacity Mounted\n"
        .. string.rep("x", 8192) .. "\n/dev/root 100 40 60 40% /\n"
    end
    return { code = 0, stdout = stdout }
  end,
})
assert(capped_stdout.cpu == "n/a" and capped_stdout.mem == "n/a"
  and capped_stdout.disk == "n/a",
  "oversized process output is discarded for load, memory and disk")

-- hw.memsize alone: padding pushes the number past the cap, so it is dropped.
local capped_memsize = system.status_metrics({
  read_file = function() error("proc unavailable") end,
  run = function(options)
    local argv = options.argv
    if argv[1] == "vm_stat" then
      return { code = 0, stdout = "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n"
        .. "Pages free: 100000.\nPages inactive: 200000.\nPages speculative: 10000.\n" }
    elseif argv[1] == "sysctl" and argv[3] == "hw.memsize" then
      return { code = 0, stdout = string.rep(" ", 8192) .. "4096000000" }
    end
    return { code = 1, stdout = "" }
  end,
})
assert(capped_memsize.mem == "n/a", "oversized hw.memsize output is discarded")

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

-- An npm install puts three files side by side: `claude` (a sh script for Git
-- Bash), `claude.cmd` and `claude.ps1`. Windows cannot start the first one.
local npm = { [ [[C:\npm\claude]] ] = true, [ [[C:\npm\claude.cmd]] ] = true, [ [[C:\npm\claude.ps1]] ] = true }
local npm_found = windows.find_command("claude", {
  path = [[C:\npm]], pathext = ".COM;.EXE;.BAT;.CMD",
  exists = function(path) return npm[path] == true end,
})
assert(npm_found == [[C:\npm\claude.cmd]],
  "Windows lookup must not return the extensionless npm shim: " .. tostring(npm_found))
local npm_only_shim = windows.find_command("claude", {
  path = [[C:\npm]], pathext = ".COM;.EXE;.BAT;.CMD",
  exists = function(path) return path == [[C:\npm\claude]] end,
})
assert(npm_only_shim == nil, "a file without a PATHEXT extension is not a command on Windows")
local named = windows.find_command("claude.cmd", {
  path = [[C:\npm]], pathext = ".COM;.EXE;.BAT;.CMD",
  exists = function(path) return npm[path] == true end,
})
assert(named == [[C:\npm\claude.cmd]], "a name that already has a PATHEXT extension is tried as given")
-- A PATHEXT entry is an extension only when it starts with a dot and has more
-- than the dot (core's rule). "E" must not make "claude" count as named.
local odd_pathext = windows.find_command("claude", {
  path = [[C:\npm]], pathext = "E;.;.CMD",
  exists = function(path) return npm[path] == true end,
})
assert(odd_pathext == [[C:\npm\claude.cmd]],
  "a PATHEXT entry without a leading dot is not an extension: " .. tostring(odd_pathext))
local no_real_pathext = windows.find_command("claude", {
  path = [[C:\npm]], pathext = "E;.",
  exists = function(path) return npm[path] == true end,
})
assert(no_real_pathext == [[C:\npm\claude.cmd]],
  "a PATHEXT with no real extension means the default list: " .. tostring(no_real_pathext))
-- cmd.exe accepts a quoted PATH entry; it must be unquoted, not skipped.
local quoted = windows.find_command("node", {
  path = [["C:\Program Files\nodejs";C:\tools]], pathext = ".EXE",
  exists = function(path) return path == [[C:\Program Files\nodejs\node.exe]] end,
})
assert(quoted == [[C:\Program Files\nodejs\node.exe]],
  "a quoted PATH entry should be searched: " .. tostring(quoted))

-- Exercise the POSIX table with a fake executable path.
local posix = assert(system.posix, "POSIX system table must be testable")
local posix_path = "/opt/agent/bin/claude"
local posix_found = posix.find_command("claude", {
  path = "/opt/agent/bin:/usr/bin:",
  exists = function(path) return path == posix_path end,
})
assert(posix_found == posix_path, "POSIX lookup should find a file on PATH")

local windows_candidates = {}
-- An empty PATHEXT means the default list, as in cmd.exe and in core.
local absolute_windows = [[C:\agent-bin\claude.com]]
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
assert(process_calls == 1 and probes_by_command[found_cmd] == 1 and probes_by_command.codex == nil,
  "doctor should probe only found absolute paths and must not run missing command names")

-- A command in the daemon cwd can still be resolved by process.run through a
-- relative PATH. Doctor must trust only the absolute path returned by lookup.
system.find_command = function() return nil, "not found" end
process_calls = 0
remuda.process.run = function()
  process_calls = process_calls + 1
  return { code = 0, stdout = "logged in", stderr = "", timed_out = false }
end
local rejected_relative = doctor.probe_command({ "claude", "auth", "status" }, "posix")
assert(not rejected_relative.installed and process_calls == 0,
  "doctor must report missing without probing the literal name when find_command returns nil")

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
-- #205: the data home follows core's remuda.storage.dir("data") where the core has it.
;(function()
  local function with_storage(answer)
    remuda.storage = answer ~= nil and { dir = function(kind)
      if type(answer) == "function" then return answer(kind) end
      return answer
    end } or nil
  end
  assert(type(system.storage_dir) == "function" and type(system.data_home) == "function",
    "system must offer storage_dir and data_home")
  local asked
  with_storage(function(kind) asked = kind; return [[C:\Users\u\AppData\Local\remuda]] end)
  assert(system.storage_dir("data") == [[C:\Users\u\AppData\Local\remuda]] and asked == "data",
    "storage_dir should pass core's answer through: " .. tostring(system.storage_dir("data")))
  for name, answer in pairs({ ["nil with a reason"] = function() return nil, "unavailable: no home" end,
      ["a raise"] = function() error("boom") end, ["an empty string"] = "", ["a number"] = 7 }) do
    with_storage(answer)
    assert(system.storage_dir("data") == nil, "storage_dir should answer nil for " .. name)
  end
  remuda.storage = { lock = function() end }
  assert(system.storage_dir("data") == nil, "a core without storage.dir has no answer")
  remuda.storage = nil
  assert(system.storage_dir("data") == nil, "a core without remuda.storage has no answer")

  local function never() error("an old core must not look at the disk") end
  assert(system.data_home("/home/u/.local/share", never) == "/home/u/.local/share",
    "an old core keeps today's data home")
  local nothing = function() return false end
  with_storage("/home/u/.local/share/remuda")
  assert(system.data_home("/home/u/.local/share", never) == "/home/u/.local/share",
    "where both rules agree nothing is checked and nothing moves")
  with_storage([[C:\Users\u\AppData\Local\remuda]])
  assert(system.data_home(nil, nothing) == [[C:\Users\u\AppData\Local]],
    "core's answer gives a data home where Butler had none: " .. tostring(system.data_home(nil, nothing)))
  assert(system.data_home("C:/Users/u/.local/share", nothing) == [[C:\Users\u\AppData\Local]],
    "core's answer wins over the old rule on a fresh install")
  with_storage("/data/remuda/")
  assert(system.data_home("/old", nothing) == "/data", "a trailing separator is accepted")
  for _, odd in ipairs({ "/data/other", "remuda", "/remuda", "/data/remudax" }) do
    with_storage(odd)
    assert(system.data_home("/old", nothing) == "/old", "an answer that is not <base>/remuda is ignored: " .. odd)
  end
  -- An install made under the old rule keeps its data until someone moves it.
  with_storage([[C:\Users\u\AppData\Local\remuda]])
  local seen = {}
  local function old_only(path) seen[#seen + 1] = path; return path == "C:/Users/u/.local/share/remuda/butler" end
  local kept, note = system.data_home("C:/Users/u/.local/share", old_only)
  assert(kept == "C:/Users/u/.local/share", "old data that exists is kept: " .. tostring(kept))
  assert(type(note) == "string" and note:find("C:/Users/u/.local/share/remuda/butler", 1, true)
    and note:find([[C:\Users\u\AppData\Local\remuda]], 1, true), "the note names both places: " .. tostring(note))
  local moved, moved_note = system.data_home("C:/Users/u/.local/share", function() return true end)
  assert(moved == [[C:\Users\u\AppData\Local]] and moved_note == nil, "when both exist, core's place is used and nothing is said")

  -- An inaccessible legacy data directory is not known to be absent. Preserve it
  -- and explain the selected location so Butler cannot silently hide old data.
  with_storage("/new/remuda")
  remuda.fs = { realpath = function(path)
    if path == "/old/remuda/butler" then return nil, "denied: permission denied" end
    return nil, "not_found: path does not exist"
  end }
  local denied_home, denied_note = system.data_home("/old")
  remuda.fs = nil
  assert(denied_home == "/old", "an inaccessible old data home must be kept: " .. tostring(denied_home))
  assert(type(denied_note) == "string" and denied_note:find("/old/remuda/butler", 1, true),
    "an inaccessible old data home must produce a note: " .. tostring(denied_note))
  with_storage([[C:\Users\u\AppData\Local\remuda]])

  -- A check that raises must never stop Butler from loading: the old home is used.
  local raised_ok, raised_home = pcall(system.data_home, "C:/Users/u/.local/share", function() error("disk check exploded") end)
  assert(raised_ok and raised_home == "C:/Users/u/.local/share",
    "a raising existence check falls back to the old home: " .. tostring(raised_home))
  remuda.fs = { realpath = function() error("core realpath exploded") end }
  raised_ok, raised_home = pcall(system.data_home, "C:/Users/u/.local/share")
  remuda.fs = nil
  assert(raised_ok and raised_home == "C:/Users/u/.local/share",
    "a raising core realpath falls back to the old home: " .. tostring(raised_home))
  -- paths.lua builds Butler's directories on that answer.
  local outer_getenv = os.getenv
  os.getenv = function(name)
    if name == "HOME" or name == "USERPROFILE" or name == "XDG_CONFIG_HOME" or name == "XDG_DATA_HOME"
        or name == "REMUDA_BUTLER_TOKEN" or name == "REMUDA_BUTLER_CONFIG"
        or name == "REMUDA_BUTLER_TOPICS" or name == "REMUDA_BUTLER_PROJECT_HOME" then return nil end
    return original_getenv(name)
  end
  remuda.butler = {}
  dofile("packages/butler/paths.lua")
  assert(remuda._butler_paths.data_home == [[C:\Users\u\AppData\Local]]
    and remuda._butler_paths.butler_session_cwd == [[C:\Users\u\AppData\Local]] .. "/remuda/butler/sessions/butler"
    and remuda._butler_paths.mail_root == [[C:\Users\u\AppData\Local]] .. "/remuda/butler/mail",
    "Butler's directories should sit under core's data directory: " .. tostring(remuda._butler_paths.data_home))
  remuda.storage, os.getenv = nil, outer_getenv
end)()

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
remuda._test_identity_saved_random_bytes = remuda.random_bytes
remuda._test_identity_random_requests = {}
remuda.random_bytes = function(n)
  remuda._test_identity_random_requests[#remuda._test_identity_random_requests + 1] = n
  return string.rep("r", n)
end
io.open = function(path, mode)
  if path == "/dev/urandom" then return nil, "simulated unavailable random source" end
  return original_io_open(path, mode)
end
assert(dofile("packages/butler/identity.lua") == nil)
local identity = remuda._butler_identity
assert(#remuda._butler_new_ulid() == 26
  and remuda._test_identity_random_requests[1] == 10,
  "ULID entropy should use remuda.random_bytes when /dev/urandom is unavailable")
remuda.random_bytes = nil
remuda._butler_identity_config.bus.previous_ulid_second = nil
local ulid_ok, ulid_error = pcall(remuda._butler_new_ulid)
assert(not ulid_ok and tostring(ulid_error):find("secure random source unavailable", 1, true),
  "ULID creation must fail when both secure random sources are unavailable")
identity.identity_record({ id = "01ARZ3NDEKTSV4RRFFQ69G5FAV", alias = "butler" })
assert(created_directories[paths.butler_session_cwd] and created_directories[paths.mail_root],
  "the profile data home should provide usable session and mail directories")
assert(identity.identity_path == identity_path and written_identity_path == identity_path,
  "identity records should be written under the profile data home")

remuda.random_bytes = remuda._test_identity_saved_random_bytes
remuda._test_identity_saved_random_bytes, remuda._test_identity_random_requests = nil, nil
os[execute_key], io[popen_key], os.getenv, io.open = original_execute, original_popen, original_getenv, original_io_open
print("ok - system module command lookup, failure lines, and home contract")
