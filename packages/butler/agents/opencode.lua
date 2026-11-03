local builders = assert(remuda._butler_agent_builders)
local startup = assert(remuda._butler_agent_startup)
local telemetry = assert(remuda._butler_telemetry_adapters)

-- OpenCode's composer is at the bottom; a prompt quoted higher in the
-- transcript must not prove readiness. This matches the previous window
-- (start = #lines - 11).
local SCAN_TAIL = 11

-- The composer's left border is U+2503 (ASCII '|' in mono); older builds used
-- U+2502. Both are multi-byte, so compare literal prefixes; a Lua byte class
-- would strip only the first byte and leave a malformed glyph tail.
local BORDERS = { "┃", "│", "|" }
local PROMPT_GLYPHS = { "❯", "›", ">" }

-- Exact idle placeholders from OpenCode's TUI. The first entry is the home
-- screen: "Ask anything, / for commands, @ for context" plus the Unicode
-- ellipsis, or three ASCII dots in mono mode.
local PLACEHOLDERS = {
  "Ask anything, / for commands, @ for context…",
  "Ask anything, / for commands, @ for context...",
  "Ask anything…",
  "Ask anything...",
  "Ask anything",
}

-- OpenCode 2.2.x renders a muted suggestion as `Ask anything… "<suggestion>"`
-- (`...` in mono). The set is static in the bundled TUI. A complete,
-- closing-quoted known suggestion is placeholder-shaped text; arbitrary quoted
-- text is a real draft and must stay NON-EMPTY. Text alone cannot prove
-- provenance: a human can type the same bytes, so this is a fail-closed
-- whitelist, not forensic proof.
-- Narrow-terminal truncations require reliable composer geometry; incomplete
-- or unknown suggestions defer rather than accepting arbitrary text prefixes.
local SUGGESTION_PREFIXES = { "Ask anything… \"", "Ask anything... \"" }
local SUGGESTIONS = {
  "Fix a TODO in the codebase",
  "What is the tech stack of this project?",
  "Fix broken tests",
}
-- Shell mode has an empty composer but is unsafe for a task or notice: typed
-- text runs as a shell command. It therefore blocks instead of reading EMPTY.
local SHELL_PREFIXES = { "Run a command… \"", "Run a command... \"" }
local SHELL_SUGGESTIONS = { "ls -la", "git status", "pwd" }

-- U+00A0 is whitespace for the TUI but not for Lua's %s.
local function fold_space(text)
  return (tostring(text or ""):gsub("\194\160", " "))
end

local function trim(text)
  return fold_space(text):match("^%s*(.-)%s*$")
end

local function trim_left(text)
  return fold_space(text):gsub("^%s+", "")
end

local function starts_with(text, prefix)
  return text:sub(1, #prefix) == prefix
end

-- Split one captured row into its composer body. The old `[│|]` byte class
-- matched only the first byte of a multi-byte glyph, leaving its tail in the
-- body; literal prefixes keep the comparison UTF-8 safe.
--
-- `text` is the normalized body used for grammar decisions; `raw` keeps a
-- prompt glyph so owned-text comparisons never lose typed bytes. After a
-- composer border, a prompt glyph is only stripped from `text` when text
-- follows it. That keeps a typed `>`/`❯` draft (alone, or with no separating
-- space) as NON-EMPTY instead of turning it into an empty body.
local function composer_line(line)
  local text = trim_left(line)
  local marked, border = false, false
  for _, prefix in ipairs(BORDERS) do
    if starts_with(text, prefix) then
      marked, border = true, true
      text = trim_left(text:sub(#prefix + 1))
      break
    end
  end
  local raw = text
  for _, prefix in ipairs(PROMPT_GLYPHS) do
    if starts_with(text, prefix) then
      local rest = text:sub(#prefix + 1)
      -- With a composer border, a glyph is only decoration when text follows
      -- it. `┃ > ` is a typed draft, not an empty TUI prompt.
      if not border or (rest:match("^%s") and trim(rest) ~= "") then
        marked = true
        text = trim_left(rest)
      end
      break
    end
  end
  return text, marked, border, raw
end

local function known_quoted(text, prefixes, values)
  for _, prefix in ipairs(prefixes) do
    if starts_with(text, prefix) then
      local rest = text:sub(#prefix + 1)
      for _, value in ipairs(values) do
        if rest == value .. '"' then return true end
      end
    end
  end
  return false
end

-- "blank"/"placeholder"/"suggestion" are empty composers. "shell" and
-- "text" are not: a task would overwrite a draft or run a shell command.
local function classify(text)
  text = trim(text)
  if text == "" then return "blank" end
  for _, placeholder in ipairs(PLACEHOLDERS) do
    if text == placeholder then return "placeholder" end
  end
  if known_quoted(text, SUGGESTION_PREFIXES, SUGGESTIONS) then return "suggestion" end
  if known_quoted(text, SHELL_PREFIXES, SHELL_SUGGESTIONS) then return "shell" end
  return "text"
end

-- OpenCode's composer box ends with a validated bottom boundary and the
-- agent/model status line sits just above it inside the same left border. It
-- is chrome only in that structural slot. Lua has no `|` alternation, so the
-- label is captured once and checked against the narrow known set; an unknown
-- or merely title-cased `·` row remains input.
local STATUS_LABELS = { Build = true, Plan = true, Shell = true }
local function is_status_body(text)
  local label, rest = text:match("^(%a[%w_%-]*)%s*·%s*(.+)$")
  return label ~= nil and STATUS_LABELS[label] == true and rest ~= ""
end

-- Validate the whole bottom row, not just a corner prefix. The current frame
-- is U+2579 followed by one or more full U+2580 tokens. Legacy explicit box
-- bottoms are U+2570/U+2514 + at least one U+2500, and U+255A + U+2550.
local LEGACY_BOTTOMS = { { "╰", "─" }, { "└", "─" }, { "╚", "═" } }
local function is_bottom_border(line)
  local text = trim_left(line)
  if starts_with(text, "╹") then
    local rest = text:sub(#"╹" + 1)
    local blocks = 0
    while starts_with(rest, "▀") do
      rest = rest:sub(#"▀" + 1)
      blocks = blocks + 1
    end
    return blocks > 0 and rest:match("^%s*$") ~= nil
  end
  for _, spec in ipairs(LEGACY_BOTTOMS) do
    if starts_with(text, spec[1]) then
      local rest = text:sub(#spec[1] + 1)
      local dashes = 0
      while starts_with(rest, spec[2]) do
        rest = rest:sub(#spec[2] + 1)
        dashes = dashes + 1
      end
      return dashes > 0 and rest:match("^%s*$") ~= nil
    end
  end
  return false
end

-- Return the last composer block in the bottom window: its body, whether a
-- composer row was found, and whether a structural bottom/footer frames it.
-- Only a border/prompt row (or an exact placeholder on a borderless legacy
-- screen) establishes a composer, so a transcript line cannot masquerade as
-- one. The body joins continuation rows (walking past the scan window and
-- through blank padding), which keeps a stale placeholder from hiding a draft
-- above, beside, or below it.
local function composer(screen)
  local lines = {}
  local normalized = tostring(screen or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (normalized .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local start = math.max(1, #lines - SCAN_TAIL)
  local last
  for index = start, #lines do
    local _, marked = composer_line(lines[index])
    if marked then last = index end
  end
  local first
  if last then
    first = last
    while first > 1 do
      local body, marked = composer_line(lines[first - 1])
      if marked or trim(body) == "" then
        first = first - 1
      else
        -- A missing border must not reset a multiline draft to blank padding.
        -- Inspect the entire run, stopping only at a validated box boundary.
        -- Plain captures cannot always separate old bordered output from the
        -- active composer; retaining that text conservatively defers input.
        local previous = first - 1
        while previous > 0 and not is_bottom_border(lines[previous]) do
          local _, earlier_marked = composer_line(lines[previous])
          if earlier_marked then break end
          previous = previous - 1
        end
        local _, earlier_marked = composer_line(lines[previous] or "")
        if previous == 0 or not earlier_marked then break end
        first = previous
      end
    end
    -- Only a complete box boundary ends input. Footer-like text and malformed
    -- corners can be human drafts, so include them as continuation text.
    local probe = last + 1
    while probe <= #lines do
      if is_bottom_border(lines[probe]) then break end
      local body, marked = composer_line(lines[probe])
      if marked then break end
      if trim(body) ~= "" then
        last = probe
      end
      probe = probe + 1
    end
  else
    -- Compatibility: a screen without a border may still show the exact
    -- placeholder, but only as the last non-blank row. A borderless
    -- placeholder followed by more text is transcript, not a composer.
    for index = #lines, start, -1 do
      if classify((composer_line(lines[index]))) == "placeholder" then
        local trailing = false
        for after = index + 1, #lines do
          if trim((composer_line(lines[after]))) ~= "" then trailing = true; break end
        end
        if not trailing then first, last = index, index end
        break
      end
    end
  end
  if not first then return nil, false, false end
  local framed = false
  local after = last + 1
  while after <= #lines and trim(lines[after]) == "" do after = after + 1 end
  framed = is_bottom_border(lines[after] or "")
  -- The status row is chrome only in the real final slot: immediately above a
  -- validated bottom boundary and immediately below a blank bordered padding
  -- row. If a tall draft has no separator, the status stays part of the text
  -- (NON-EMPTY) and delivery defers rather than trimming real content.
  local status_body = (composer_line(lines[last]))
  local above_body, above_marked = composer_line(lines[last - 1] or "")
  if last > first and is_bottom_border(lines[last + 1] or "")
      and is_status_body(status_body) and above_marked and trim(above_body) == "" then
    last = last - 1
  end
  local bodies, normalized_bodies = {}, {}
  for index = first, last do
    local body, _, _, raw = composer_line(lines[index])
    normalized_bodies[#normalized_bodies + 1] = body
    bodies[#bodies + 1] = raw
  end
  return trim(table.concat(bodies, "\n")), true, framed,
    trim(table.concat(normalized_bodies, "\n"))
end

local function empty(screen)
  local text, found, framed, normalized = composer(screen)
  if not found then return "UNPARSEABLE", "" end
  local kind = classify(normalized or text)
  if kind == "blank" then
    -- Blank bordered rows alone are ambiguous; require a structural frame.
    if framed then return "EMPTY", text end
    return "UNPARSEABLE", ""
  end
  if kind == "placeholder" or kind == "suggestion" then return "EMPTY", text end
  return "NON-EMPTY", text
end

local function ready(screen)
  return empty(screen) == "EMPTY"
end

local function working(screen)
  local lines = {}
  local normalized = tostring(screen or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (normalized .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local bottom
  for index = math.max(1, #lines - SCAN_TAIL), #lines do
    if is_bottom_border(lines[index]) then bottom = index end
  end
  if not bottom then return false end
  -- Both current and legacy clients paint the interrupt hint below the box.
  -- Transcript/draft quotes above it are not evidence of active work.
  for index = bottom + 1, math.min(#lines, bottom + 3) do
    local _, marked = composer_line(lines[index])
    if marked or is_bottom_border(lines[index]) then break end
    local footer = fold_space(lines[index])
    if footer:match("%f[%w_]esc%s+interrupt%f[^%w_]")
        or footer:match("%f[%w_]esc%s+to%s+interrupt%f[^%w_]") then
      return true
    end
  end
  return false
end

telemetry.opencode = {
  setup = function(spec) return { model = spec.model } end,
  read = function(state) return { model = state.model } end,
}

builders.opencode = function(spec)
  assert(type(spec.name) == "string", "OpenCode agent spec requires a string name")
  local argv = { "opencode", "--standalone" }
  if type(spec.cwd) == "string" and spec.cwd ~= "" then argv[#argv + 1] = spec.cwd end
  return argv
end

startup.opencode = {
  -- OpenCode's idle composer shows a placeholder, or a muted quoted suggestion
  -- once its session is live. Do not accept generic banner text or an
  -- authentication screen as a ready composer. The grammar lives here once so
  -- the init.lua registration, notices, first-task delivery, compaction, and
  -- status probes cannot drift.
  ready = ready,
  working = working,
  placeholders = PLACEHOLDERS,
  empty = empty,
  login = { "Authentication required", "Not authenticated", "Please log in" },
}
