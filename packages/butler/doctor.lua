-- Read-only installation and authentication checks for the Butler CLI.
local system = assert(remuda._butler_system)

local function probe_command(argv)
  local path = system.find_command(argv[1])
  if not path then return { installed = false, logged_in = false } end
  local candidate = { path }
  for i = 2, #argv do candidate[#candidate + 1] = argv[i] end
  local ok, result = pcall(remuda.process.run, { argv = candidate, timeout = 5 })
  if not ok then return { installed = true, probe_error = true } end
  return { installed = true, logged_in = result.code == 0 and not result.timed_out,
    timed_out = not not result.timed_out }
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
  platform = platform or system.platform()
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
}
remuda._butler_doctor = doctor
return doctor
