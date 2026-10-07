local builders = assert(remuda._butler_agent_builders)
local support = assert(remuda._butler_agent_support)
local telemetry = assert(remuda._butler_telemetry_adapters)

telemetry.claude = {
  setup = function(spec)
    local status_path = spec.status_path or (os.tmpname() .. "." .. spec.name .. ".status")
    return { status_path = status_path, settings_path = support.status_settings(status_path) }
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
  ready = function(screen) return screen:find("─\n❯", 1, true) ~= nil end, -- idle composer under its rule
  clear_input = "C-u",
  modals = {
    { trust = "claude", pending_match = "Quick safety check:" }, -- option chosen by its text
    -- Decline by option text; never "Yes" (it leads to the shell-history screen) or "Don't show again".
    { title = "Teach auto mode about your environment?", choose = "Not now",
      options = { "Yes", "Not now", "Don't show again" } },
  },
}
