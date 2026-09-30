-- Read-only installation and authentication checks for the Butler CLI.
local function successful(result, reason, code)
  return result == true or result == 0 or (reason == "exit" and code == 0)
end

local function platform_name()
  return package.config:sub(1, 1) == "\\" and "windows" or "posix"
end

local function probe(execute, platform)
  execute = execute or os.execute
  platform = platform or platform_name()
  local windows = platform == "windows"
  local redirect = windows and " >NUL 2>&1" or " >/dev/null 2>&1"
  local locate = windows and "where " or "command -v "
  local results = {}
  for _, agent in ipairs({
    { key = "claude", binary = "claude", check = "claude auth status" },
    { key = "codex", binary = "codex", check = "codex login status" },
  }) do
    local exists = successful(execute(locate .. agent.binary .. redirect))
    local logged_in = false
    if exists then logged_in = successful(execute(agent.check .. redirect)) end
    results[agent.key] = { installed = exists, logged_in = logged_in }
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
