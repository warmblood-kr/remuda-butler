-- B02 parity port of tests/butler_daemon.rs: agent argv builders (D065, D066),
-- doctor rendering (D122-D127) and the doctor CLI (D128-D131). Test names equal the Rust names.
-- Doctor renderings assert the CURRENT doctor.lua output (it gained the Approve text and
-- Approval room lines after the Rust assertions were written).
local repo = assert(os.getenv("REMUDA_LUA_REPO"))
local exe = assert(os.getenv("REMUDA_BIN"))
local child = assert(os.getenv("REMUDA_LUA_CHILD_SERVER"))
local started

local function start_butler()
  if started then return end
  started = true
  T.install_mod("butler", repo)
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1; remuda._butler_test_mode = "lifecycle"')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 30, "Butler root start")
end

local function read_file(path)
  local file = assert(io.open(path, "rb"), "cannot read " .. path)
  local text = file:read("*a")
  file:close()
  return text
end

T.test("butler_claude_builder_keeps_its_noninteractive_cli_hint", function()
  local adapter = read_file(repo .. "/packages/butler/agents/claudecode.lua")
  local permission_mode = adapter:find('"--permission-mode"', 1, true)
  local append_system_prompt = adapter:find('"--append-system-prompt"', 1, true)
  T.ok(permission_mode, "butler launch argv lost --permission-mode")
  T.ok(append_system_prompt, "butler launch argv lost --append-system-prompt")
  T.ok(permission_mode < append_system_prompt, "expected --permission-mode before --append-system-prompt")
end)

-- Reload Butler with REMUDA_RUNTIME_DIR forced to `runtime_dir` (nil = unset), build the Codex argv, restore.
local function codex_argv(runtime_dir, supported)
  local getenv_value = runtime_dir and string.format("%q", runtime_dir) or "nil"
  return T.eval(string.format([=[
    local old_getenv = os.getenv
    os.getenv = function(key) if key == "REMUDA_RUNTIME_DIR" then return %s end return old_getenv(key) end
    remuda.exec("butler")
    os.getenv = old_getenv
    remuda._butler_codex_config_supported = %s
    local a = remuda._butler_agent_builders.codex({name="codex", token="token", telemetry={status_path="/tmp/status"}})
    return table.concat(a, "\n")
  ]=], getenv_value, tostring(supported)))
end

local function lines_of(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

T.test("butler_codex_builder_uses_automatic_approval", function()
  start_butler()
  local old = { "remuda", "_codex_tui", "--status", "/tmp/status" }
  local argv = lines_of(codex_argv(nil, false))
  T.eq(table.concat(argv, "\n"), table.concat(old, "\n"), "old core")

  -- #201: the real builder and the real mcp_flags give Codex the MCP server.
  argv = lines_of(codex_argv(nil, true))
  for _, arg in ipairs(argv) do
    T.ok(not arg:find("shell_environment_policy", 1, true), "unset runtime dir: " .. table.concat(argv, " "))
  end
  T.eq(#argv, 10, table.concat(argv, " "))
  for i = 1, 4 do T.eq(argv[i], old[i]) end
  T.eq(argv[5], "-c")
  T.eq(argv[6], 'mcp_servers.remuda.command="remuda"')
  T.ok(argv[7] == "-c" and argv[8]:find('mcp_servers.remuda.args=["-s","', 1, true) == 1, table.concat(argv, " "))
  T.ok(argv[9] == "-c" and argv[10]:find('mcp_servers.remuda.env={REMUDA_SESSION_CAPABILITY="token"', 1, true) == 1,
    table.concat(argv, " "))

  local runtime_dir = [[/tmp/remuda "runtime"\dir]]
  argv = lines_of(codex_argv(runtime_dir, true))
  T.eq(#argv, 12, table.concat(argv, " "))
  T.eq(argv[11], "-c")
  T.eq(argv[12], [[shell_environment_policy.set={REMUDA_RUNTIME_DIR="/tmp/remuda \"runtime\"\\dir"}]])
  codex_argv(nil, true) -- leave the shared daemon with its real runtime dir
end)

-- doctor.render / candidate_names in the daemon, with the guard line source removed so the
-- rendering is the doctor module's own.
local function render(probes, platform)
  start_butler()
  return T.eval(string.format([=[
    local butler = remuda.butler
    local guard = butler and butler.guard
    if butler then butler.guard = nil end
    local ok, lines = pcall(remuda._butler_doctor.render, %s, %q)
    if butler then butler.guard = guard end
    assert(ok, lines)
    return table.concat(lines, "\n")
  ]=], probes, platform))
end

local function candidates(name, platform)
  start_butler()
  return T.eval(string.format("return table.concat(remuda._butler_doctor.candidate_names(%q, %q), ',')", name, platform))
end

local function status(installed, logged_in)
  return string.format("{ installed = %s, logged_in = %s }", tostring(installed), tostring(logged_in))
end
local function probes(claude, codex)
  return string.format("{ claude = %s, codex = %s }", claude, codex)
end

local SWITCHES = "Typed lines: off\nShell lines: off\nApprove text: off\nApproval room: all -> HOME (lounge not joined)"

T.test("doctor_candidate_names_include_windows_cmd_fallback", function()
  T.eq(candidates("codex", "windows"), "codex,codex.cmd")
  T.eq(candidates("codex", "posix"), "codex")
end)

T.test("doctor_reports_all_good", function()
  T.eq(render(probes(status(true, true), status(true, true)), "macos"),
    "Claude Code: installed, logged in\nCodex CLI: installed, logged in\n" .. SWITCHES
      .. "\nNext: remuda butler matrix setup")
end)

T.test("doctor_reports_missing_claude_posix", function()
  local p = probes(status(false, false), status(true, true))
  local expected = "Claude Code: missing\nCodex CLI: installed, logged in\n" .. SWITCHES
    .. "\nNext: curl -fsSL https://claude.ai/install.sh | bash"
  T.eq(render(p, "macos"), expected)
  T.eq(render(p, "linux"), expected)
end)

T.test("doctor_reports_missing_claude_windows", function()
  T.eq(render(probes(status(false, false), status(true, true)), "windows"),
    "Claude Code: missing\nCodex CLI: installed, logged in\n" .. SWITCHES
      .. "\nNext: irm https://claude.ai/install.ps1 | iex")
end)

T.test("doctor_reports_codex_logged_out", function()
  T.eq(render(probes(status(true, true), status(true, false)), "macos"),
    "Claude Code: installed, logged in\nCodex CLI: installed, not logged in\n" .. SWITCHES
      .. "\nNext: codex login")
end)

T.test("doctor_reports_both_missing_with_two_next_lines", function()
  T.eq(render(probes(status(false, false), status(false, false)), "linux"),
    "Claude Code: missing\nCodex CLI: missing\n" .. SWITCHES
      .. "\nNext: curl -fsSL https://claude.ai/install.sh | bash\nNext: npm install -g @openai/codex")
end)

-- The doctor CLI through the real `remuda butler doctor` front door. The agent CLIs are stubbed at the two
-- seams doctor.lua uses (system.find_command and remuda.process.run) instead of sh scripts on PATH.
local function doctor_cli(stub)
  start_butler()
  T.eval([[
    local system = remuda._butler_system
    remuda._doctor_saved = remuda._doctor_saved or { find = system.find_command, run = remuda.process.run }
    system.find_command = remuda._doctor_saved.find
    remuda.process.run = remuda._doctor_saved.run
  ]])
  T.eval(stub)
  local result = remuda.process.run { argv = { exe, "-s", child, "butler", "doctor" }, timeout = 20 }
  T.eval([[
    remuda._butler_system.find_command = remuda._doctor_saved.find
    remuda.process.run = remuda._doctor_saved.run
    return "ok"
  ]])
  T.ok(not result.timed_out, "doctor timed out")
  T.eq(result.code, 0, result.stderr)
  return result.stdout or "", result.stderr or ""
end

-- Keep the agent-status and Next lines: the rest (guard, permissions) is other features' output.
local function agent_lines(stdout)
  local kept = {}
  for _, line in ipairs(lines_of((stdout:gsub("%s+$", "")))) do
    if line:find("^Claude Code: ") or line:find("^Codex CLI: ") or line:find("^Next: ") then kept[#kept + 1] = line end
  end
  return table.concat(kept, "\n")
end

T.test("doctor_cli_all_good_never_echoes_agent_output", function()
  local stdout, stderr = doctor_cli([[
    remuda._butler_system.find_command = function(name) return "/stub/" .. name end
    remuda.process.run = function(options)
      if options.argv[1]:find("claude", 1, true) then
        return { code = 0, timed_out = false, stdout = '{"status":"logged-in","token":"DOCTOR_SECRET_CLAUDE"}\n', stderr = "" }
      end
      return { code = 0, timed_out = false, stdout = "Logged in using ChatGPT; DOCTOR_SECRET_CODEX\n", stderr = "" }
    end
  ]])
  T.ok(stdout:find("Claude Code: installed, logged in", 1, true), stdout)
  T.ok(stdout:find("Codex CLI: installed, logged in", 1, true), stdout)
  T.ok(stdout:find("Next: remuda butler matrix setup", 1, true), stdout)
  for _, secret in ipairs({ "DOCTOR_SECRET_CLAUDE", "DOCTOR_SECRET_CODEX", "logged-in" }) do
    T.ok(not stdout:find(secret, 1, true), "doctor leaked " .. secret .. ": " .. stdout)
    T.ok(not stderr:find(secret, 1, true), "doctor leaked " .. secret .. ": " .. stderr)
  end
end)

T.test("doctor_cli_both_missing_prints_two_next_commands", function()
  local stdout = doctor_cli("remuda._butler_system.find_command = function() return nil end")
  T.eq(agent_lines(stdout),
    "Claude Code: missing\nCodex CLI: missing\nNext: curl -fsSL https://claude.ai/install.sh | bash\nNext: npm install -g @openai/codex", stdout)
  T.ok(stdout:find("Typed lines: off\nShell lines: off\n", 1, true), stdout)
end)

T.test("doctor_cli_timeout_reports_retry_and_the_other_agent", function()
  local stdout = doctor_cli([[
    remuda._butler_system.find_command = function(name) return "/stub/" .. name end
    remuda.process.run = function(options)
      if options.argv[1]:find("claude", 1, true) then return { code = 1, timed_out = true } end
      return { code = 0, timed_out = false }
    end
  ]])
  T.ok(stdout:find("Claude Code: check timed out", 1, true), stdout)
  T.ok(stdout:find("Codex CLI: installed, logged in", 1, true), stdout)
  T.ok(stdout:find("Next: retry remuda butler doctor", 1, true), stdout)
end)

T.test("doctor_cli_unexpected_probe_error_still_reports_other_agent_and_next", function()
  -- A claude that exists but cannot be run (Rust: a non-executable stub), and no codex at all.
  local stdout = doctor_cli([[
    remuda._butler_system.find_command = function(name) if name == "claude" then return "/stub/claude" end return nil end
    remuda.process.run = function() error("Permission denied (os error 13)") end
  ]])
  T.ok(stdout:find("Claude Code: check failed", 1, true), stdout)
  T.ok(stdout:find("Codex CLI: missing", 1, true), stdout)
  T.ok(stdout:find("Next: retry remuda butler doctor", 1, true), stdout)
  T.ok(stdout:find("Next: npm install -g @openai/codex", 1, true), stdout)
end)
