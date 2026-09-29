local builders = assert(remuda._butler_agent_builders)
local telemetry = assert(remuda._butler_telemetry_adapters)

telemetry.codex = {
  setup = function(spec)
    return { model = spec.model, status_path = os.tmpname() .. "." .. spec.name .. ".status" }
  end,
  read = function(state)
    local f = state.status_path and io.open(state.status_path, "r")
    if not f then return { model = state.model } end
    local line = f:read("*l")
    f:close()
    local model, used, window, percent = (line or ""):match("^MODEL:([A-Za-z0-9_.%-?]+) CTX:([0-9?]+) CTXWIN:([0-9?]+) CTXPCT:([0-9?]+)$")
    return { model = model or state.model, context_used = used, context_window = window, context_percent = percent }
  end,
}

builders.codex = function(spec)
  local argv = { "remuda", "_codex_tui", "--status", spec.telemetry.status_path }
  if spec.model and spec.model ~= "" then argv[#argv + 1] = "--model"; argv[#argv + 1] = spec.model end
  return argv
end

local codex_modal_markers = {
  "Update available",
  "A new version of Codex is available",
  "A new version is available",
  "New version available",
  "Codex update available",
  "Update now",
  "Skip until next version",
  "Trust this folder?",
}
remuda._butler_agent_startup.codex = {
  ready = function(screen)
    local lower = screen:lower()
    for _, marker in ipairs(codex_modal_markers) do
      if lower:find(marker:lower(), 1, true) then return false end
    end
    return screen:find("Ask Codex", 1, true) ~= nil
  end,
  working = function(screen) return screen:find("esc to interrupt", 1, true) ~= nil end,
  clear_input = "C-u",
  -- #29: the empty composer's fixed placeholder (codex 0.156.0), exact match.
  placeholders = { "Ask Codex to do anything" },
  modals = {
    { match = "Update available", update = true },
    { match = "A new version of Codex is available", update = true },
    { match = "A new version is available", update = true },
    { match = "New version available", update = true },
    { match = "Codex update available", update = true },
    { match = "Update now", update = true },
    { match = "Skip until next version", update = true },
    { trust = "codex", keys = { "1" } }, -- only a stable, exact two-option trust modal is actionable
  },
}
