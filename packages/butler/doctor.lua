-- Read-only installation and authentication checks for the Butler CLI.
local system = assert(remuda._butler_system)

local function command_candidates(name, platform)
  platform = platform or system.platform()
  if platform == "windows" then return { name, name .. ".cmd" } end
  return { name }
end

local function probe_command(argv)
  local path = system.find_command(argv[1])
  if not path then return { installed = false, logged_in = false } end
  local candidate = { path }
  for i = 2, #argv do candidate[#candidate + 1] = argv[i] end
  local ok, result = pcall(remuda.process.run, { argv = candidate, timeout = 5 })
  if ok then
    return {
      installed = true,
      logged_in = result.code == 0 and not result.timed_out,
      timed_out = not not result.timed_out,
      stdout = result.stdout,
      stderr = result.stderr,
    }
  end

  local message = tostring(result):lower()
  if message:find("os error 2", 1, true)
      or message:find("no such file or directory", 1, true)
      or message:find("cannot find the file specified", 1, true) then
    return { installed = false, logged_in = false }
  end
  return { installed = true, probe_error = true }
end

local function typed_line_switches()
  local matrix = remuda.butler and remuda.butler.matrix
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  if not matrix or type(matrix.read_config) ~= "function"
      or type(paths.config_path) ~= "string" or paths.config_path == "" then
    return false, false
  end
  local ok, config = pcall(matrix.read_config, paths.config_path)
  if not ok or type(config) ~= "table" then return false, false end
  local approval_mode = config.approval_room == "home" and "home" or "all"
  local approval_result = "HOME (lounge not joined)"
  if approval_mode == "home" then
    approval_result = "HOME"
  elseif type(config.all_room) == "string" and type(config.rooms) == "table"
      and config.rooms[config.all_room] == "all" then
    approval_result = config.all_room
  end
  local approval_room = approval_mode .. " -> " .. approval_result
  return config.typed_lines == true, config.shell_lines == true, config.approve_text == true, true, approval_room
end

local function probe()
  local results = {}
  for _, agent in ipairs({
    { key = "claude", argv = { "claude", "auth", "status" } },
    { key = "codex", argv = { "codex", "login", "status" } },
  }) do
    results[agent.key] = probe_command(agent.argv)
  end
  local policy = remuda.butler and remuda.butler.guard_policy
  if policy then results.guard = policy.enabled() end
  if policy then results.guard_approvals = policy.approvals_enabled() end
  if policy then results.guard_deny = policy.deny_enabled() end
  results.typed_lines, results.shell_lines, results.approve_text, results.matrix_configured,
    results.approval_room = typed_line_switches()
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
    "Typed lines: " .. (probe_results.typed_lines == true and "on" or "off"),
    "Shell lines: " .. (probe_results.shell_lines == true and "on" or "off"),
    "Approve text: " .. (probe_results.approve_text == true and "on" or "off"),
    "Approval room: " .. tostring(probe_results.approval_room or "all -> HOME (lounge not joined)"),
  }
  if probe_results.guard_approvals ~= nil then
    lines[#lines + 1] = "Guard approvals: " .. (probe_results.guard_approvals
      and "on (the owner answers Claude permission prompts of new sessions in Matrix; no answer means Claude's own prompt)"
      or "off")
  end
  if probe_results.guard_deny ~= nil then
    lines[#lines + 1] = "Guard deny: " .. (probe_results.guard_deny and "on" or "off")
  end
  if probe_results.guard ~= nil then
    lines[#lines + 1] = "Guard audit: "
      .. (probe_results.guard and "on (records tool calls of new Claude sessions; never blocks)" or "off")
  end
  local guard = remuda.butler and remuda.butler.guard
  local unguarded = guard and guard.unguarded_line()
  if unguarded then lines[#lines + 1] = unguarded end
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
  if claude.installed and claude.logged_in and codex.installed and codex.logged_in
      and probe_results.matrix_configured ~= true then
    lines[#lines + 1] = "Next: remuda butler matrix setup"
  end
  return lines
end

-- The root Butler's permission rule (permissions.lua): what the mod did to its
-- settings.local.json at the last launch or load. The block ends with Next:.
local function permission_lines(report, kind)
  local function one_line(value) return (tostring(value):gsub("[\r\n]+", " "):gsub("%c", "?")) end
  local head = "Permissions butler (" .. one_line(kind or "?") .. "): "
  if kind == "codex" then
    return { head .. "none — the mod writes no Codex permission rules", "Next: nothing to do" }
  end
  if type(report) ~= "table" then return { head .. "not checked yet", "Next: remuda butler status" } end
  local path, withheld = one_line(report.path or "?"), report.withheld[1]
  if report.error then
    return { head .. "not written: " .. one_line(report.error) .. " — " .. path,
      "Next: fix or delete that file; Butler adds the rule at its next launch" }
  elseif withheld then
    return { head .. "withheld " .. one_line(withheld.rule) .. " — listed under " .. withheld.list .. " in " .. path,
      "Next: remove the rule from " .. withheld.list .. " in that file; Butler adds it at its next launch" }
  elseif #report.added > 0 then
    return { head .. "added " .. #report.added .. " rule to " .. path .. ": " .. one_line(table.concat(report.added, ", "))
      .. " (file rewritten: private, mode 600)", "Next: to block the rule, move it to permissions.deny in that file" }
  elseif #report.present > 0 then
    return { head .. "present " .. one_line(table.concat(report.present, ", ")) .. " — " .. path,
      "Next: to block the rule, move it to permissions.deny in that file" }
  end
  return { head .. "none", "Next: nothing to do" }
end

local doctor = {
  probe = probe,
  render = render,
  probe_command = probe_command,
  permission_lines = permission_lines,
  candidate_names = command_candidates,
}
remuda._butler_doctor = doctor
return doctor
