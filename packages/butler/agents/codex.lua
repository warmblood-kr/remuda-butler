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
-- Parse a complete current picker, not a title left in terminal history.
-- Codex 0.162 renders descriptions in a second column and hides Max/Ultra
-- behind the exact "More reasoning…" row. Unknown rows/geometry fail closed.
local function picker(screen)
  if type(screen) ~= "string" then return nil end
  local kind, model, lines, rows, selected, footer = nil, nil, {}, {}, 0, false
  for raw in (screen .. "\n"):gmatch("(.-)\n") do
    local line = raw:match("^%s*(.-)%s*$")
    local title_model = line:lower():match("^select reasoning level for (gpt%-[%w%.%-]+)$")
    if line:lower() == "select model and effort" or title_model then
      kind, model = title_model and "effort" or "model", title_model
      lines, rows, selected, footer = {raw}, {}, 0, false
    elseif kind then
      lines[#lines+1] = raw
      local mark, number, label = raw:match("^%s*([^%s%d]*)%s*(%d+)%.%s+(.-)%s*$")
      if number and not footer then
        if mark ~= "" and mark ~= "›" and mark ~= "❯" then return nil end
        selected = selected + (mark ~= "" and 1 or 0)
        -- Two or more spaces delimit the description column.
        label = (label:match("^(.-)%s%s+") or label):lower()
        if tonumber(number) ~= #rows+1 then return nil end
        local base = label:gsub("%s+%(default%)$", "")
        if kind == "model" then
          local id, suffix = label:match("^(gpt%-[%w%.%-]+)(.*)$")
          if not id or (suffix ~= "" and suffix ~= " (current)") then return nil end
        elseif not ({low=true, medium=true, high=true, ["extra high"]=true,
            max=true, ultra=true, ["more reasoning…"]=true})[base] then return nil end
        rows[#rows+1] = label
      elseif line ~= "" then
        local expected = kind == "model" and "enter select · esc back" or "enter default · s session · esc back"
        if footer or line:lower():gsub("%s+", " ") ~= expected then return nil end
        footer = true
      end
    end
  end
  if not kind or not footer or #rows < 2 or selected ~= 1 then return nil end
  return {kind=kind, model=model, rows=rows, signature=table.concat(lines, "\n")}
end
remuda._butler_agent_startup.codex = {
  picker = picker,
  -- Only the recorded workflow target and phase authorize selector keys.
  owned_picker = function(screen, signature, operation)
    local current = picker(screen)
    if not current or type(operation.model) ~= "string" or type(operation.effort) ~= "string" then return false end
    local phase, target = operation.phase, false
    if current.kind == "model" and (phase == "model" or phase == "escape") then
      for _, label in ipairs(current.rows) do
        target = target or label:match("^(gpt%-[%w%.%-]+)") == operation.model
      end
    elseif current.kind == "effort" and current.model == operation.model
        and (phase == "effort" or phase == "escape") then
      local wanted = operation.effort == "xhigh" and "extra high" or operation.effort
      for _, label in ipairs(current.rows) do
        target = target or label:gsub("%s+%(default%)$", "") == wanted
      end
    else return false end
    return target or phase == "escape"
  end,
  -- Recognised dialog states (see claudecode.lua and docs/butler.md).
  -- `scan` headings may sit above approval metadata and command/diff rows.
  -- No invented Codex denial/cache signatures beyond these.
  dialog_states = {
    { id = "codex_command_approval", response = "approval", scan = true,
      heading = "would you like to run the following command?" },
    { id = "codex_edit_approval", response = "approval", scan = true,
      heading = "would you like to make the following edits?" },
    { id = "codex_permissions_approval", response = "approval", scan = true,
      heading = "would you like to grant these permissions?" },
    { id = "codex_terminal_input_approval", response = "approval", scan = true,
      heading = "would you like to send input to the existing terminal?" },
    -- The guardian (auto-review) refusal: a classifier decision, never answered.
    { id = "codex_auto_review_refused", response = "approval", match = function(heading)
      return heading:match("^automatic approval review rejected too many approval requests for this turn %(") ~= nil
        and heading:match("reviews%); interrupting the turn%.$") ~= nil
    end },
    { id = "codex_model_effort_dialog", response = "report", heading = "select model and effort" },
    { id = "codex_reasoning_dialog", response = "report", match = function(heading)
      return heading:match("^select reasoning level for gpt%-[%w%.%-]+$") ~= nil
    end },
    { id = "codex_model_confirm", response = "report", heading = "switch model?" },
    { id = "codex_effort_confirm", response = "report", heading = "change effort level?" },
    { id = "codex_proceed_confirm", response = "approval", heading = "do you want to proceed?" },
  },
  blocking = {},
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
