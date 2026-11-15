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
  -- Additive native flag: the core launcher binds and publishes after its
  -- owning-request capture. Old/off launches keep the exact previous argv.
  if type(spec.native) == "table" and spec.native.mode == "native"
      and spec.native.kind == "codex" and type(spec.native.binding) == "string" then
    argv[#argv + 1] = "--binding"; argv[#argv + 1] = spec.native.binding
  end
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
-- One-time owner approval for a current command-approval prompt. It matches
-- only this exact geometry: the heading, one displayed command, both options in
-- this order, and the cursor already on "Yes, proceed". Return confirms that
-- selected option; Escape is the prompt's own cancel ("esc to cancel"). An
-- unrecognised line above the choices (a wrapped command, another section)
-- makes the prompt non-actionable instead of guessing.
local COMMAND_APPROVAL_HEADING = 'would you like to run the following command?'
local COMMAND_APPROVAL_MAX = 200 -- the request summary must show the command in full
-- The command is owner-room visible and Matrix history is durable, so a command
-- that may carry a credential is never made actionable. This screening is
-- heuristic and deliberately conservative: a miss leaves the prompt report-only
-- (the owner answers in the pane), and the target room must stay owner-controlled.
local COMMAND_APPROVAL_UNSAFE_WORDS = { 'token', 'secret', 'password', 'passwd', 'credential',
  'apikey', 'api_key', 'access_key', 'private_key', 'auth' }
local COMMAND_APPROVAL_UNSAFE_PREFIXES = { 'ghp_', 'github_pat_', 'xoxb-', 'xoxp-', 'xoxa-', 'sk-', 'akia' }
local function unsafe_to_show(command)
  local lower = command:lower()
  for _, word in ipairs(COMMAND_APPROVAL_UNSAFE_WORDS) do
    local name = word:gsub('_', '[_-]?')
    if lower:find(name .. '%s*=') or lower:find('%-%-[%w%-]*' .. name) then return true end
  end
  for _, prefix in ipairs(COMMAND_APPROVAL_UNSAFE_PREFIXES) do
    if lower:find(prefix, 1, true) then return true end
  end
  return lower:find('bearer%s+%S') ~= nil
    or lower:find('://[^/%s@]+:[^/%s@]+@') ~= nil
    or lower:find('authorization%s*:') ~= nil
    or lower:find('begin [a-z ]*private key') ~= nil
    or lower:find('%-%-user%s+[^%s:]+:[^%s]+') ~= nil
    or lower:find('%-u%s+[^%s:]+:[^%s]+') ~= nil
end
local function command_approval_plan(screen)
  if type(screen) ~= 'string' then return nil end
  local compaction = remuda._butler_compaction
  if type(compaction) ~= 'table' or type(compaction.unknown_dialog_signature) ~= 'function' then return nil end
  local block = compaction.unknown_dialog_signature(screen)
  if type(block) ~= 'string' or block == '' then return nil end
  local labels, selected = {}, nil
  for line in (block .. '\n'):gmatch('(.-)\n') do
    local number, label, marked = compaction.numbered_option(line)
    if number then
      labels[#labels + 1] = label:gsub('%s+$', ''):lower()
      if marked then selected = #labels end
    elseif line:match('^%s*(.-)%s*$') ~= '' then
      -- A long option label may wrap; only its indented continuation is allowed.
      -- A marker line here is a composer or a second prompt, never this dialog.
      if not line:match('^%s+') or line:match('^%s*[❯›>]') or #labels == 0 or #labels > 3 then return nil end
    end
  end
  -- Codex 0.167.2 offers three choices; the middle one is a standing permission
  -- and is never selected by this action. Any other shape is not actionable.
  if #labels ~= 3 or selected ~= 1
      or not labels[1]:match('^yes, proceed %(y%)$')
      or not labels[2]:match('^yes, and don')
      or not labels[3]:match('^no, and tell codex what to do differently %(esc%)$') then return nil end
  -- Bind the heading and the one command above the current choice segment. A
  -- repeated block in scrollback is fine: only the last occurrence is current.
  local start, from = nil, 1
  while true do
    local found = screen:find(block, from, true)
    if not found then break end
    start, from = found, found + 1
  end
  if not start then return nil end
  local prefix = screen:sub(1, start - 1)
  -- The prompt's own footer must directly follow the current choices, and no
  -- composer may sit below them: either means this is history, not a live prompt.
  local footer, suffix = false, screen:sub(start + #block)
  for line in (suffix .. '\n'):gmatch('(.-)\n') do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed == '❯' or trimmed == '›' or trimmed == '>' or trimmed:match('^> ')
        or trimmed:find('Ask Codex to do anything', 1, true) == 1 then return nil end
    if not footer and trimmed ~= '' then
      footer = trimmed:lower() == 'press enter to confirm or esc to cancel'
    end
  end
  if not footer then return nil end
  local lines = {}
  for line in (prefix .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
  local command, heading
  for i = #lines, 1, -1 do
    local trimmed = lines[i]:match('^%s*(.-)%s*$')
    local lower = trimmed:lower()
    if trimmed == '' or trimmed:match('^Reason:') or trimmed:match('^Thread:')
        or trimmed:match('^Environment:') or trimmed:match('^Permission rule:')
        or trimmed:match('^Description:') or trimmed:match('^Destination:') then
      -- known prompt metadata, not execution content
    elseif lower == COMMAND_APPROVAL_HEADING then
      heading = lower
      break
    elseif trimmed:match('^%$%s+%S') then
      if command then return nil end -- more than one command line: ambiguous
      command = trimmed:match('^%$%s+(.+)$'):gsub('%s+$', '')
    else
      return nil -- wrapped command or unknown section: never guess
    end
  end
  if not heading or not command or #command > COMMAND_APPROVAL_MAX or command:find('%c')
      or unsafe_to_show(command) then return nil end
  return { signature = heading .. '\n' .. command .. '\n' .. block,
    key = 'RET', label = 'Yes, proceed', summary = 'run `' .. command .. '`' }
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
  -- One fixture-backed one-time action: the current command-approval prompt.
  -- Approve confirms the already-selected "Yes, proceed" with Return; reject
  -- sends the prompt's own Escape cancel. No other prompt is actionable.
  dialog_approvals = {
    { id = 'codex_command_approval_once', state_id = 'codex_command_approval',
      version = '1', fixture = 'tests/fixtures/codex-approval-command.txt',
      action_scope = 'once', category = 'permission',
      deny_key = 'ESC',
      deny_label = 'send the prompt’s Escape cancel = "No, and tell Codex what to do differently" '
        .. '(declines; 0.167.2 also interrupts the turn)',
      match = command_approval_plan,
      verify = function(screen) return command_approval_plan(screen) == nil end },
  },
  -- Recognised dialog states (see claudecode.lua and docs/butler.md).
  -- `scan` headings may sit above approval metadata and command/diff rows.
  -- No invented Codex denial/cache signatures beyond these.
  dialog_states = {
    -- action_scope enables the one fixture-backed one-time action below.
    { id = "codex_command_approval", response = "approval", scan = true, action_scope = "once",
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
