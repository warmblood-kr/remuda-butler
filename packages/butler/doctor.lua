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

-- Same rule as matrix_cli's terminal_safe; that module is not loaded here.
local function safe(text)
  return (tostring(text):gsub("[%c]", " "):gsub("\194[\128-\159]", " "))
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
  local approval_result, approval_next = "HOME (lounge not joined)", "Next: remuda butler matrix join ROOM"
  if approval_mode == "home" then
    approval_result = "HOME"
  elseif type(config.all_room) == "string" and type(config.rooms) == "table"
      and config.rooms[config.all_room] == "all" then
    approval_result, approval_next = config.all_room, nil
  else
    local joined = {}
    for room, kind in pairs(type(config.rooms) == "table" and config.rooms or {}) do
      if kind == "joined" then joined[#joined + 1] = room end
    end
    if #joined == 1 then
      approval_result = "HOME (joined room is not marked ALL-BUTLERS)"
      approval_next = "Next: check that the room's members are only you and Butlers (ALL-BUTLERS receives approval requests in full), then run: remuda butler matrix mark-all '"
        .. safe(joined[1]):gsub("'", "'\\''") .. "'; then remuda exec butler"
    elseif #joined > 1 then
      approval_result = "HOME (no joined room is marked ALL-BUTLERS)"
      approval_next = "Next: remuda butler matrix rooms; then remuda butler matrix mark-all ROOM"
    end
  end
  if approval_mode == "home" then approval_next = nil end
  local approval_room = approval_mode .. " -> " .. approval_result
  return config.typed_lines == true, config.shell_lines == true, config.approve_text == true, true, approval_room, approval_next
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
    results.approval_room, results.approval_next = typed_line_switches()
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
  if probe_results.approval_next then lines[#lines + 1] = probe_results.approval_next end
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
  -- Read-only: which members are checked by instance (legacy-visible ones keep name-only checks).
  local principal = remuda._butler_caller_principal
  if principal and principal.legacy_core() then lines[#lines + 1] = "legacy-core: instance binding not enforced" end
  local unbound = 0
  for _, agent in pairs((remuda._butler_bus or {}).agents or {}) do
    if type(agent) == "table" and not (principal and principal.bound(agent)) then unbound = unbound + 1 end
  end
  if unbound > 0 then lines[#lines + 1] = unbound .. " members not instance-bound: relaunch to bind" end
  return lines
end

-- Read the current files on every invocation; a launch report is only a path hint.
-- https://code.claude.com/docs/en/settings (list merging and precedence)
-- https://code.claude.com/docs/en/auto-mode-config (classifyAllShell scopes)
local function permission_lines(report, kind, context)
  context = context or {}
  local head = "Permissions butler (" .. safe(kind or "?") .. "): "
  if kind == "codex" then
    return { head .. "none — the mod writes no Codex permission rules", "Next: nothing to do" }
  end
  local path = type(report) == "table" and report.path
  if kind ~= "claude" or type(path) ~= "string" then
    return { head .. "close permission unknown — session settings path unavailable",
      "Fix: launch the root Butler and retry remuda butler doctor" }
  end
  local sources = context.sources
  if not sources then
    sources = {}
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    local config = os.getenv("CLAUDE_CONFIG_DIR") or (home and home .. "/.claude")
    if config then sources[#sources + 1] = config .. "/settings.json" end
    sources[#sources + 1] = path:gsub("settings%.local%.json$", "settings.json")
    sources[#sources + 1] = path
    if context.settings_path then sources[#sources + 1] = context.settings_path end
    local platform = system.platform()
    if platform == "windows" then
      sources[#sources + 1] = (os.getenv("ProgramFiles") or "C:/Program Files") .. "/ClaudeCode/managed-settings.json"
    else
      -- system.platform distinguishes POSIX from Windows only. Inspect both
      -- conventional POSIX locations conservatively; absent files are ignored.
      sources[#sources + 1] = "/Library/Application Support/ClaudeCode/managed-settings.json"
      sources[#sources + 1] = "/etc/claude-code/managed-settings.json"
    end
  end
  local allows, asks, denies, classify_all = {}, {}, {}, false
  local function blocked(reason)
    return { head .. "close permission not confirmed — " .. safe(reason),
      "Fix: review permissions.deny/ask and autoMode.classifyAllShell in the checked files; restore Bash(remuda butler:*) in permissions.allow only if intended. Confirm loaded sources with Claude /status; checked "
        .. safe(table.concat(sources, ", ")) }
  end
  local allow_scan = false
  local function matches(rule)
    if rule == "Bash" or rule == "Bash(*)" then return true end
    if type(rule) ~= "string" then return nil end
    local pattern = rule:match("^Bash%((.*)%)$")
    if not pattern then return false end
    pattern = pattern:gsub(":%*$", " *")
    local escaped = pattern:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*")
    if ("remuda butler close NAME"):match("^" .. escaped .. "$") ~= nil then return true end
    if allow_scan then return false end
    -- Deny/ask: block when the rule and the family "remuda butler close *" can match a common
    -- string (conservative glob intersection; family has one trailing wildcard). Only the literal
    -- text before the rule's first `*` constrains it, and it must agree with the family prefix.
    local family = "remuda butler close "
    local star = pattern:find("*", 1, true)
    local lit = star and pattern:sub(1, star - 1) or pattern
    if star then return lit:sub(1, #family) == family:sub(1, #lit) end
    return lit:sub(1, #family) == family
  end
  for _, source in ipairs(sources) do
    local file, why = io.open(source, "rb")
    if file then
      local text = file:read("*a")
      file:close()
      local json = remuda.json
      if not json or type(json.decode) ~= "function" then return blocked("JSON decoder unavailable") end
      local ok, settings = pcall(json.decode, text)
      local array = type(json.array) == "function" and getmetatable(json.array({}))
      local function is(value, want_array)
        if type(value) ~= "table" or value == json.null then return false end
        if array then return (getmetatable(value) == array) == want_array end
        return true
      end
      if not ok or not is(settings, false) or settings[1] ~= nil then
        return blocked("invalid settings in " .. source)
      end
      local perms = settings.permissions
      if perms ~= nil then
        if not is(perms, false) then return blocked("invalid permissions in " .. source) end
        for _, row in ipairs({ { "allow", allows }, { "ask", asks }, { "deny", denies } }) do
          local rules = perms[row[1]]
          if rules ~= nil then
            if not is(rules, true) then return blocked("invalid " .. row[1] .. " in " .. source) end
            for key, rule in pairs(rules) do
              if type(key) ~= "number" or type(rule) ~= "string" then return blocked("invalid rule list in " .. source) end
              row[2][#row[2] + 1] = { rule = rule, source = source }
            end
          end
        end
      end
      if settings.autoMode ~= nil and source ~= path and source ~= path:gsub("settings%.local%.json$", "settings.json") then
        if not is(settings.autoMode, false) then return blocked("invalid autoMode in " .. source) end
        if settings.autoMode.classifyAllShell ~= nil then
          if type(settings.autoMode.classifyAllShell) ~= "boolean" then return blocked("invalid classifyAllShell in " .. source) end
          classify_all = settings.autoMode.classifyAllShell
        end
      end
      if settings.allowManagedPermissionRulesOnly == true then
        return blocked("managed-only permissions require review in Claude")
      end
    elseif not tostring(why):lower():find("no such file", 1, true) then
      return blocked("cannot read " .. source)
    end
  end
  for _, rows in ipairs({ { "deny", denies }, { "ask", asks } }) do
    for _, entry in ipairs(rows[2]) do
      if matches(entry.rule) then return blocked(entry.rule .. " under " .. rows[1] .. " in " .. entry.source) end
    end
  end
  if classify_all then return blocked("autoMode.classifyAllShell suspends shell allow rules") end
  allow_scan = true
  for _, entry in ipairs(allows) do
    if matches(entry.rule) and entry.rule ~= "Bash" and entry.rule ~= "Bash(*)" then
      local prefix = entry.rule:match("^Bash%((.-):%*%)$") or entry.rule:match("^Bash%((.-) %*%)$")
      if prefix and (prefix == "remuda butler" or prefix == "remuda butler close") then
        return { head .. "present " .. safe(entry.rule) .. " — " .. safe(entry.source)
          .. " (candidate allow pattern for remuda butler close NAME; deny and ask rules checked across current settings)",
          "Next: this dry check reads settings files only; Claude hooks, server-managed policy and runtime settings may still block execution" }
      end
    end
  end
  return blocked("no current allow rule covers remuda butler close NAME")
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
