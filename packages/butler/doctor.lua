-- Read-only installation and authentication checks for the Butler CLI.
local function platform_name()
  return package.config:sub(1, 1) == "\\" and "windows" or "posix"
end

local function probe_command(argv)
  local ok, result = pcall(remuda.process.run, { argv = argv, timeout = 5 })
  if not ok then
    local message = tostring(result):lower()
    if message:find("os error 2", 1, true)
        or message:find("no such file or directory", 1, true)
        or message:find("cannot find the file specified", 1, true) then
      return false, false
    end
    error("Could not run " .. argv[1] .. " authentication check.", 0)
  end
  return true, result.code == 0 and not result.timed_out
end

local function probe()
  local results = {}
  for _, agent in ipairs({
    { key = "claude", argv = { "claude", "auth", "status" } },
    { key = "codex", argv = { "codex", "login", "status" } },
  }) do
    local installed, logged_in = probe_command(agent.argv)
    results[agent.key] = { installed = installed, logged_in = installed and logged_in or false }
  end
  return results
end

local function render(probe_results, platform)
  probe_results = probe_results or {}
  platform = platform or platform_name()
  local claude = probe_results.claude or {}
  local codex = probe_results.codex or {}
  local lines = {
    "Claude Code: " .. (claude.installed and (claude.logged_in and "installed, logged in" or "installed, not logged in") or "missing"),
    "Codex CLI: " .. (codex.installed and (codex.logged_in and "installed, logged in" or "installed, not logged in") or "missing"),
  }
  if not claude.installed then
    lines[#lines + 1] = platform == "windows"
      and "Next: irm https://claude.ai/install.ps1 | iex"
      or "Next: curl -fsSL https://claude.ai/install.sh | bash"
  elseif not claude.logged_in then
    lines[#lines + 1] = "Next: claude auth login"
  end
  if not codex.installed then
    lines[#lines + 1] = "Next: npm install -g @openai/codex"
  elseif not codex.logged_in then
    lines[#lines + 1] = "Next: codex login"
  end
  if claude.installed and claude.logged_in and codex.installed and codex.logged_in then
    lines[#lines + 1] = "Next: remuda butler matrix setup"
  end
  return lines
end

local doctor = { probe = probe, render = render }
remuda._butler_doctor = doctor
return doctor
