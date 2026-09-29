local builders = assert(remuda._butler_agent_builders)
local support = assert(remuda._butler_agent_support)
local telemetry = assert(remuda._butler_telemetry_adapters)

telemetry.claude = {
  setup = function(spec)
    local status_path = spec.status_path or (os.tmpname() .. "." .. spec.name .. ".status")
    return { status_path = status_path, settings_path = support.status_settings(status_path) }
  end,
  read = function(state)
    local status = state.status_path and io.open(state.status_path, "r")
    if not status then return {} end
    local line = status:read("*l")
    status:close()
    if not line then return {} end
    local model, used, window, percent = line:match(
      "^MODEL:([A-Za-z0-9_.%-?]+) CTX:([0-9?]+) CTXWIN:([0-9?]+) CTXPCT:([0-9?]+)$"
    )
    if not model then return {} end
    return { model = model, context_used = used, context_window = window, context_percent = percent }
  end,
}

builders.claude = function(spec)
  local argv = { "claude" }
  if spec.settings_path then argv[#argv + 1] = "--settings"; argv[#argv + 1] = spec.settings_path end
  argv[#argv + 1] = "--mcp-config"; argv[#argv + 1] = spec.mcp_config_path or support.mcp_config_path(spec.name, spec.token)
  argv[#argv + 1] = "--strict-mcp-config"
  argv[#argv + 1] = "--permission-mode"; argv[#argv + 1] = "auto"
  argv[#argv + 1] = "--append-system-prompt"
  argv[#argv + 1] = spec.system_prompt
    or "This session is managed by Remuda Butler. The remuda butler CLI is available for coordination."
  if spec.model and spec.model ~= "" then argv[#argv + 1] = "--model"; argv[#argv + 1] = spec.model end
  return argv
end

-- Fresh topic dirs are created by Butler itself, so trusting them is safe.
remuda._butler_agent_startup.claude = {
  ready = function(screen) return screen:find("─\n❯", 1, true) ~= nil end, -- idle composer under its rule
  clear_input = "C-u",
  modals = {
    { match = "Do you trust the files in this folder?", keys = { "<down>", "RET" } },
    { match = "Yes, I trust this folder", keys = { "<down>", "RET" } },
  },
}
