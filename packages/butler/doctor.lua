-- Read-only installation and authentication checks for the Butler CLI.
local function platform_name()
  return package.config:sub(1, 1) == "\\" and "windows" or "posix"
end

local function command_candidates(name, platform)
  platform = platform or platform_name()
  if platform == "windows" then return { name, name .. ".cmd" } end
  return { name }
end

local function probe_command(argv, platform)
  for _, name in ipairs(command_candidates(argv[1], platform)) do
    local candidate = { name }
    for i = 2, #argv do candidate[#candidate + 1] = argv[i] end
    local ok, result = pcall(remuda.process.run, { argv = candidate, timeout = 5 })
    if ok then
      return {
        installed = true,
        logged_in = result.code == 0 and not result.timed_out,
        timed_out = not not result.timed_out,
      }
    end

    local message = tostring(result):lower()
    if not (message:find("os error 2", 1, true)
        or message:find("no such file or directory", 1, true)
        or message:find("cannot find the file specified", 1, true)) then
      return { installed = true, probe_error = true }
    end
  end
  return { installed = false, logged_in = false }
end

local function probe()
  local results = {}
  for _, agent in ipairs({
    { key = "claude", argv = { "claude", "auth", "status" } },
    { key = "codex", argv = { "codex", "login", "status" } },
  }) do
    results[agent.key] = probe_command(agent.argv)
  end
  return results
end

local function render(probe_results, platform)
  probe_results = probe_results or {}
  platform = platform or platform_name()
  local claude = probe_results.claude or {}
  local codex = probe_results.codex or {}
  local function status(cli)
    if cli.timed_out then return "check timed out" end
    if cli.probe_error then return "check failed" end
    return cli.installed and (cli.logged_in and "installed, logged in" or "installed, not logged in") or "missing"
  end
  local lines = {
    "Claude Code: " .. status(claude),
    "Codex CLI: " .. status(codex),
  }
  if not claude.timed_out and not claude.probe_error then
    if not claude.installed then
      lines[#lines + 1] = platform == "windows"
        and "Next: irm https://claude.ai/install.ps1 | iex"
        or "Next: curl -fsSL https://claude.ai/install.sh | bash"
    elseif not claude.logged_in then
      lines[#lines + 1] = "Next: claude auth login"
    end
  end
  if not codex.timed_out and not codex.probe_error then
    if not codex.installed then
      lines[#lines + 1] = "Next: npm install -g @openai/codex"
    elseif not codex.logged_in then
      lines[#lines + 1] = "Next: codex login"
    end
  end
  if claude.timed_out or claude.probe_error or codex.timed_out or codex.probe_error then
    lines[#lines + 1] = "Next: retry remuda butler doctor"
  end
  if claude.installed and claude.logged_in and codex.installed and codex.logged_in then
    lines[#lines + 1] = "Next: remuda butler matrix setup"
  end
  return lines
end

local doctor = {
  probe = probe,
  render = render,
  candidate_names = command_candidates,
}
remuda._butler_doctor = doctor
return doctor
