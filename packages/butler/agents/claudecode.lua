local builders = assert(remuda._butler_agent_builders)
local support = assert(remuda._butler_agent_support)
local telemetry = assert(remuda._butler_telemetry_adapters)

-- Owned status directories by member name, replaced (old one removed) on the
-- next setup for that name; also the key for the settings directory.
local status_dirs = {}

telemetry.claude = {
  setup = function(spec)
    local status_path = spec.status_path
    if not status_path then
      -- Not a name beside a reserved tmpname file: a directory this session owns.
      local dir, why
      if type(support.new_private_dir) == "function" then dir, why = support.new_private_dir()
      else why = "support lacks a private directory helper" end
      if not dir then
        if _butler_session_trace then _butler_session_trace("settings_not_written", tostring(why)) end
        return { settings_error = why }
      end
      status_path = dir .. "/" .. spec.name .. ".status"
      local previous = status_dirs[spec.name]
      status_dirs[spec.name] = dir
      if previous then pcall(remuda.remove_dir_all, previous) end
    end
    local settings_path, why = support.status_settings(status_path, spec.name, spec.memory_dir)
    if not settings_path and _butler_session_trace then _butler_session_trace("settings_not_written", tostring(why)) end
    return { status_path = status_path, settings_path = settings_path, settings_error = why }
  end,
  read = function(state)
    -- The hook-written `.state` file: "<word> <unix time>", one fixed word.
    local hook_state, hook_at
    local hook = state.status_path and io.open(state.status_path .. ".state", "r")
    if hook then
      local word, at = (hook:read("*l") or ""):match("^(%a+ ?%a*) (%d+)$")
      hook:close()
      if word == "working" or word == "idle" or word == "needs you" then hook_state, hook_at = word, tonumber(at) end
    end
    local status = state.status_path and io.open(state.status_path, "r")
    if not status then return { hook_state = hook_state, hook_at = hook_at } end
    local line = status:read("*l")
    local second_line = status:read("*l")
    status:close()
    if not line then return { hook_state = hook_state, hook_at = hook_at } end
    local model, used, window, percent = line:match(
      "^MODEL:([A-Za-z0-9_.%-?]+) CTX:([0-9?]+) CTXWIN:([0-9?]+) CTXPCT:([0-9?]+)$"
    )
    if not model then return { hook_state = hook_state, hook_at = hook_at } end
    return {
      hook_state = hook_state,
      hook_at = hook_at,
      model = model,
      context_used = used,
      context_window = window,
      context_percent = percent,
      rate_limits = remuda._butler_quota
        and remuda._butler_quota.parse_rate_limits_line(second_line),
    }
  end,
}

builders.claude = function(spec)
  -- The per-launch settings file carries the guard hooks (PreToolUse and
  -- PermissionRequest) when guard policy is on. A launch that needs them but
  -- could not persist the file is refused (fail closed) only when the owner
  -- EXPLICITLY turned guard on: the chooser records a spawn_error for this
  -- candidate and never starts Claude without them. With guard off, or on
  -- only by default, the failure only drops the defaults and status
  -- telemetry; the launch continues without --settings (traced).
  local settings_error = spec.telemetry and spec.telemetry.settings_error
  if settings_error then
    local policy = remuda.butler and remuda.butler.guard_policy
    local ok, guard_on = pcall(function() return policy and policy.explicitly_on() end)
    if not ok or guard_on then
      error("Claude settings file could not be written (" .. tostring(settings_error)
        .. "); refusing to start Claude without its guard hooks", 0)
    end
  end
  local argv = { "claude" }
  local config = remuda._butler_compaction_config or {}
  local configured = remuda._butler_claude_autocompact
    or os.getenv("REMUDA_BUTLER_CLAUDE_AUTOCOMPACT") or config.claude_autocompact or "600k"
  if type(configured) ~= "string" or (configured ~= "auto"
      and not configured:match("^%d+k$") ) then configured = "600k" end
  if configured ~= "auto" then
    local amount = tonumber(configured:match("^(%d+)k$"))
    if not amount or amount < 100 or amount > 1000 then configured = "600k" end
  end
  local supported = remuda._butler_claude_autocompact_supported
  if supported == nil then
    local ok, result = false, "process.run unavailable"
    if remuda.process and type(remuda.process.run) == "function" then
      ok, result = pcall(remuda.process.run, { argv = { "claude", "--help" }, timeout = 5 })
    end
    local output = ok and result and ((result.stdout or "") .. "\n" .. (result.stderr or "")) or ""
    supported = ok and output:find("--autocompact", 1, true) ~= nil
    remuda._butler_claude_autocompact_supported = supported
    if not ok and remuda.log then remuda.log("warn", "Claude --autocompact help probe failed: " .. tostring(result)) end
  end
  if supported then
    argv[#argv + 1] = "--autocompact"; argv[#argv + 1] = configured
  end
  if spec.settings_path then argv[#argv + 1] = "--settings"; argv[#argv + 1] = spec.settings_path end
  argv[#argv + 1] = "--mcp-config"; argv[#argv + 1] = spec.mcp_config_path or support.mcp_config_path(spec.name, spec.token)
  argv[#argv + 1] = "--strict-mcp-config"
  argv[#argv + 1] = "--permission-mode"; argv[#argv + 1] = "auto"
  argv[#argv + 1] = "--append-system-prompt"
  argv[#argv + 1] = spec.system_prompt
    or "This session is managed by Remuda Butler. The remuda butler CLI is available for coordination."
  local model = spec.model
  if not model or model == "" then
    local config = remuda._butler_compaction_config or {}
    model = remuda._butler_claude_default_model
      or os.getenv("REMUDA_BUTLER_CLAUDE_DEFAULT_MODEL") or config.claude_default_model or "opus"
  end
  argv[#argv + 1] = "--model"; argv[#argv + 1] = model
  return argv
end

remuda._butler_agent_startup.claude = {
  -- Report-only descriptor contract; tool-result auto-mode denials are outside
  -- PR1. Future semantic recognisers require an observed dialog-only fixture.
  blocking = {
    { id = "unknown_choice", risk = "report", match = function(screen, probes)
      return probes.unknown and probes.unknown(screen)
    end },
  },
  ready = function(screen)
    if screen:find("─\n❯", 1, true) then return true end
    for line in (screen .. "\n"):gmatch("(.-)\n") do
      local offset = 1
      while line:sub(offset, offset + 2) == "─" do offset = offset + 3 end
      if offset > 1 and line:sub(offset, offset + 2) == "❯" then
        local suffix = line:sub(offset + 3):gsub("^[ \t\194\160]+", "")
        -- Empty suffix only: a joined 'Try "' hint is launch-ready (init.lua) but not startup-ready.
        if suffix == "" then return true end
      end
    end
    return false
  end, -- idle composer under its rule, including a ConPTY-wrapped border
  clear_input = "C-u",
  modals = {
    { trust = "claude", pending_match = "Quick safety check:" }, -- option chosen by its text
    -- Detect + defer only (never answered): the title (or option text with title/context) on screen holds the first task.
    -- The TITLE keys detection; option text counts only together with the title or the
    -- "about your environment" context (a lone "Not now" is ordinary text).
    { title = "Teach auto mode", context = "about your environment",
      options = { "Not now", "Don't show again" } },
  },
}
