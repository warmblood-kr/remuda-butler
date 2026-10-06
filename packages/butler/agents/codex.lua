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

-- #201: the remuda MCP server reaches the daemon from outside Codex's command
-- sandbox. Only a core whose `_codex_tui` forwards `-c KEY=VALUE` gets the
-- flags; an older core would reject them and the member would not start.
-- Only a completed probe is cached. The sandbox profile needs the same support.
function remuda._butler_codex_config_ok()
  local supported = remuda._butler_codex_config_supported
  if supported == nil then
    local ok, result = false, "process.run unavailable"
    if remuda.process and type(remuda.process.run) == "function" then
      ok, result = pcall(remuda.process.run, { argv = { "remuda", "_codex_tui", "--help" }, timeout = 5 })
    end
    if ok and type(result) == "table" and not result.timed_out then
      supported = ((result.stdout or "") .. "\n" .. (result.stderr or "")):find("-c KEY=VALUE", 1, true) ~= nil
      remuda._butler_codex_config_supported = supported
    elseif remuda.log then
      -- No answer is not "unsupported": this launch goes without, the next probes again.
      remuda.log("warn", "Codex -c KEY=VALUE help probe gave no answer ("
        .. (ok and (result and "timed out" or "no result") or tostring(result))
        .. "); this member starts without the remuda MCP server")
    end
  end
  return supported == true
end

builders.codex = function(spec)
  local argv = { "remuda", "_codex_tui", "--status", spec.telemetry.status_path }
  if spec.model and spec.model ~= "" then argv[#argv + 1] = "--model"; argv[#argv + 1] = spec.model end
  local profile = { sandbox = spec.sandbox, writable = spec.writable }
  local wants_profile = profile.sandbox ~= nil or (profile.writable and #profile.writable > 0)
  if not spec.token and not wants_profile then return argv end
  if not remuda._butler_codex_config_ok() then
    if wants_profile then
      error("this core cannot pass a sandbox profile to Codex (`_codex_tui` lacks -c KEY=VALUE).\nNext: remuda upgrade, then retry", 0)
    end
    return argv
  end
  if spec.token then
    for _, flag in ipairs(remuda._butler_agent_support.mcp_flags(spec.token)) do argv[#argv + 1] = flag end
  end
  for _, flag in ipairs(remuda._butler_sandbox.flags(profile, remuda._butler_agent_support.json_quote)) do
    argv[#argv + 1] = flag
  end
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
    { trust = "codex" }, -- the option is chosen by its exact text, never by number
  },
}
