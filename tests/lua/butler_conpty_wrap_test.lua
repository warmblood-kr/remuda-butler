-- ConPTY may join Claude's full-width composer border and prompt glyph on one
-- captured row, while leaving the first captured row blank. A Claude composer
-- is EMPTY only when styled capture proves it (cursor row, dim Try ghost, blank
-- rows down to the bottom border); every other shape defers. The probe tables
-- below are the permanent SEC round 2-4 audit cases (inlined, no external files).
local REPO = assert(os.getenv("REMUDA_LUA_REPO"))
T.install_mod("butler", REPO)
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

local function read_fixture(path)
  local file = assert(io.open(REPO .. "/tests/fixtures/" .. path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

-- Lua literal for strings, booleans and (nested) span tables.
local function lit(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return tostring(value) end
  local out, keys = {}, {}
  for _, item in ipairs(value) do out[#out + 1] = lit(item) end
  for key in pairs(value) do if type(key) ~= "number" then keys[#keys + 1] = key end end
  table.sort(keys)
  for _, key in ipairs(keys) do out[#out + 1] = key .. "=" .. lit(value[key]) end
  return "{" .. table.concat(out, ",") .. "}"
end

-- Install plain/styled capture stubs for session "audit" and run the policy
-- detached and attached plus the first-task composer decision.
-- styled: nil (no styled capture), "error", or { rows = {...}, cursor = n }.
local function decide(kind, screen, styled)
  local stub = "remuda.capture_styled = nil"
  if styled == "error" then stub = 'remuda.capture_styled = function() error("synthetic failure") end'
  elseif styled then
    stub = "remuda.capture_styled = function() return { cursor = { row = " .. (styled.cursor or 1)
      .. " }, rows = " .. lit(styled.rows) .. " } end"
  end
  local out = T.eval(string.format([[
    local kind, screen = %q, %q
    local bus = remuda._butler_bus
    bus.agents.audit = { kind = kind }
    bus.notice_screens, bus.notices = {}, {}
    remuda.capture = function() return screen end
    %s
    remuda.ls = function() return {{ name = "audit", alive = true, attached = false }} end
    local detached = remuda._butler_notify_policy("audit", 100)
    remuda.ls = function() return {{ name = "audit", alive = true, attached = true, human_idle = 20 }} end
    local attached = remuda._butler_notify_policy("audit", 100)
    local composer = remuda._butler_composer_decision(kind, "audit", screen)
    return table.concat({ tostring(detached), tostring(attached), composer }, "|")
  ]], kind, screen, stub))
  local detached, attached, composer = out:match("^(%a+)|(%a+)|(.+)$")
  return { detached = detached == "true", attached = attached == "true", composer = composer }
end

local function join(rows)
  local lines = {}
  for index, row in ipairs(rows) do
    local parts = {}
    for _, span in ipairs(row) do parts[#parts + 1] = span.text end
    lines[index] = table.concat(parts)
  end
  return table.concat(lines, "\n")
end

local function safe(result) return not result.detached and not result.attached and result.composer ~= "EMPTY" end

T.test("Claude accepts a border and prompt joined by ConPTY", function()
  local fixture = "\n────❯ "
  T.eq(T.eval(string.format("return tostring(remuda._butler_agent_startup.claude.ready(%q))", fixture)),
    "true", "startup matcher should recognize the wrapped composer")
  local choice = "────────❯ Yes, continue\n────────"
  T.eq(T.eval(string.format("return tostring(remuda._butler_agent_startup.claude.ready(%q))", choice)),
    "false", "a joined modal choice row must not look like the composer")
  for _, width in ipairs({ 100, 120, 140 }) do
    for _, label in ipairs({ "Teach auto mode", "Yes, I trust this folder", "Update now" }) do
      local modal = label .. "\n" .. string.rep("─", width) .. "❯ " .. label .. "\n────"
      T.eq(T.eval(string.format("return tostring(remuda._butler_agent_startup.claude.ready(%q))", modal)),
        "false", "wrapped modal choice must not look ready: " .. label)
    end
  end
  -- Plain text alone can no longer prove a wrapped composer empty; readiness does not need it.
  T.ok(T.eval(string.format("local d = remuda._butler_prompt_is_empty('claude', %q); return d", fixture)) ~= "EMPTY",
    "plain text must not prove a wrapped composer empty")

  T.eval(string.format([[
    remuda._butler_agent_builders.claude = function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_test_force_launch_probe = { ["conpty-wrapped"] = true }
    remuda.capture = function(name) if name == "conpty-wrapped" then return %q end return "" end
    remuda._conpty_result = nil
    remuda._butler_choose_async({ "claude" }, {
      name = "conpty-wrapped", cwd = os.getenv("XDG_DATA_HOME"), timeout = 2,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, attempts)
      remuda._conpty_result = { session = session, agent = agent, reason = attempts[1].reason }
    end)
  ]], fixture))
  T.wait_until(function()
    return T.eval("return tostring(remuda._conpty_result ~= nil)") == "true"
  end, 5, "wrapped composer readiness")
  T.eq(T.eval("return remuda._conpty_result.reason"), "ready",
    "a wrapped composer should deliver the first task through the normal ready path")
  T.eval('return remuda.close("conpty-wrapped")')
end)

-- Launch a probe session whose screen never becomes ready; return reason, detail and the
-- rendered sessions output / launch trace for that attempt.
local probe_count = 0
local function launch_diagnostic(kind, screen)
  probe_count = probe_count + 1
  local name = "diag-" .. probe_count
  T.eval(string.format([[
    remuda._butler_agent_builders[%q] = function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_test_force_launch_probe = remuda._butler_test_force_launch_probe or {}
    remuda._butler_test_force_launch_probe[%q] = true
    remuda.capture = function(session) if session == %q then return %q end return "" end
    remuda._diag = remuda._diag or {}
    remuda._butler_choose_async({ %q }, {
      name = %q, cwd = os.getenv("XDG_DATA_HOME"), timeout = 4,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, attempts) remuda._diag[%q] = attempts[1] end)
  ]], kind, name, name, screen, kind, name, name))
  T.wait_until(function()
    return T.eval(string.format("return tostring(remuda._diag[%q] ~= nil)", name)) == "true"
  end, 12, name .. " launch diagnostic")
  local out = T.eval(string.format([[
    local attempt = remuda._diag[%q]
    remuda._butler_bus.launch_failures = { [%q] = { attempts = { attempt } } }
    remuda._butler_attempts = { attempt }
    local sessions = remuda._butler_sessions()
    remuda._butler_session_trace_path = os.tmpname()
    _butler_session_trace("launch_failed", %q .. ": " .. attempt.kind .. ": " .. attempt.reason .. " (" .. tostring(attempt.detail) .. ")")
    local f = assert(io.open(remuda._butler_session_trace_path, "rb")); local trace = f:read("*a"); f:close()
    return attempt.reason .. "\0" .. tostring(attempt.detail) .. "\0" .. sessions .. "\0" .. trace
  ]], name, name, name))
  local reason, detail, sessions, trace = out:match("^([^%z]*)%z([^%z]*)%z([^%z]*)%z(.*)$")
  T.eval(string.format("pcall(remuda.close, %q)", name))
  return reason, detail, sessions, trace
end

T.test("launch diagnostics show row 1 only, cut at 80 characters, never a later row", function()
  local screens = {
    { "claude", "\nSECRET_SENTINEL_ROW2\nPlease log in", "login", "<empty first row>" },
    { "claude", "   \nSECRET_SENTINEL_ROW2\nPlease log in", "login", "<empty first row>" },
    { "claude", "\r\nSECRET_SENTINEL_ROW2\nPlease log in", "login", "<empty first row>" },
    { "claude", "\nSECRET_SENTINEL_ROW2\nPress enter to continue", "dialog", "<empty first row>" },
    { "claude", "\27[2m\27[0m\nSECRET_SENTINEL_ROW2\nPress enter to continue", "dialog", "<empty first row>" },
    { "retry_probe", "   \nSECRET_SENTINEL_ROW2", "timeout", "<empty first row>" },
    { "retry_probe", "\r\nSECRET_SENTINEL_ROW2", "timeout", "<empty first row>" },
    { "claude", "Please log in\nSECRET_SENTINEL_ROW2", "login", "Please log in" },
    { "claude", "\27[2mPlease log in\27[0m\a\nSECRET_SENTINEL_ROW2", "login", "Please log in" },
    { "retry_probe", "first visible row\nSECRET_SENTINEL_ROW2", "timeout", "first visible row" },
  }
  for index, item in ipairs(screens) do
    local reason, detail, sessions, trace = launch_diagnostic(item[1], item[2])
    T.eq(reason, item[3], "diagnostic " .. index .. " reason")
    T.ok(detail:find(item[4], 1, true), "diagnostic " .. index .. " should show row 1: " .. detail)
    for label, text in pairs({ detail = detail, sessions = sessions, trace = trace }) do
      T.ok(not text:find("SECRET_SENTINEL_ROW2", 1, true), "diagnostic " .. index .. " leaked row 2 into " .. label)
      T.ok(not text:find("\27", 1, true), "diagnostic " .. index .. " kept a control sequence in " .. label)
    end
  end
  local _, long = launch_diagnostic("claude", "Please log in " .. string.rep("─", 120) .. "SECRET_AFTER_80\nSECRET_SENTINEL_ROW2")
  local shown = long:match("^Please log in (.*)$") or long
  T.ok(not long:find("SECRET", 1, true), "text past 80 characters leaked: " .. long)
  local count = 0
  for _ in long:gmatch("[%z\1-\127\194-\244][\128-\191]*") do count = count + 1 end
  T.ok(count <= 80, "first row must be cut at 80 characters, got " .. count)
  T.ok(shown ~= "", "first row text is kept")
end)

-- Real fixtures: a stub styled capture built from the fixture: the dim Try span on the prompt row,
-- plain text everywhere else.
local function fixture_frame(path, dim_prompt)
  local text, rows, cursor = read_fixture(path), {}, nil
  local index = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    index = index + 1
    local at = not cursor and line:find("❯", 1, true) and line:find('Try "', 1, true)
    if at then
      rows[index] = dim_prompt and { { text = line:sub(1, at - 1) }, { text = line:sub(at), dim = true } }
        or { { text = line } }
      cursor = index
    else
      rows[index] = { { text = line } }
    end
  end
  return text, rows, cursor
end

local TRY_FIXTURES = {
  "claude-2.1.292-100x30.txt", "claude-2.1.292-120x30.txt", "claude-2.1.292-140x30.txt",
  "claude-2.1.292-win/claude-2.1.292-100x30.txt", "claude-2.1.292-win/claude-2.1.292-120x30.txt",
  "claude-2.1.292-win/claude-2.1.292-140x30.txt",
}

T.test("Claude dim Try suggestion is EMPTY only through a styled capture of the fixture", function()
  for _, path in ipairs(TRY_FIXTURES) do
    local screen, rows, cursor = fixture_frame(path, true)
    T.eq(T.eval(string.format("local d = remuda._butler_prompt_is_empty('claude', %q); return d", screen)),
      "UNPARSEABLE", path .. " plain parse keeps the main-branch classification")
    local proven = decide("claude", screen, { rows = rows, cursor = cursor })
    T.eq(proven.composer, "EMPTY", path .. " styled proof gives EMPTY")
    T.ok(proven.detached and proven.attached, path .. " notice policy may type")
    local _, normal_rows = fixture_frame(path, false)
    T.ok(safe(decide("claude", screen, { rows = normal_rows, cursor = cursor })), path .. " normal-style Try is a draft")
    T.ok(safe(decide("claude", screen, nil)), path .. " without styled capture defers")
    T.ok(safe(decide("claude", screen, "error")), path .. " with a failing styled capture defers")
    T.ok(safe(decide("claude", screen, { rows = { rows[cursor] }, cursor = 1 })),
      path .. " a styled capture that does not cover the screen defers")
    local drafted = {}
    for index, row in ipairs(rows) do drafted[index] = row end
    drafted[cursor + 1] = { { text = "  hidden draft" } }
    T.ok(safe(decide("claude", screen, { rows = drafted, cursor = cursor })), path .. " text below the prompt defers")
  end
end)

-- A classic (non-wrapped) frame and styled stubs proving or refusing it.
local RULE = string.rep("─", 20)
local function frame(prompt_row, below)
  local rows = { { { text = RULE } }, prompt_row, below or { { text = RULE } }, { { text = "  ⏵⏵ auto mode on" } } }
  return join(rows), { rows = rows, cursor = 2 }
end
local function ghost_words()
  return { { text = "❯\194\160" }, { text = "Try", dim = true }, { text = " " }, { text = '"fix', dim = true },
    { text = " " }, { text = "typecheck", dim = true }, { text = " " }, { text = 'errors"', dim = true } }
end

T.test("styled proof: empty or dim Try prompt with blank rows to the bottom border", function()
  for label, prompt in pairs({
    empty = { { text = "❯ " } },
    nbsp = { { text = "❯\194\160" } },
    single_ghost = { { text = "❯ " }, { text = 'Try "fix typecheck errors"', dim = true } },
    split_words = ghost_words(),
  }) do
    local screen, styled = frame(prompt)
    local result = decide("claude", screen, styled)
    T.eq(result.composer, "EMPTY", label .. " composer")
    T.ok(result.detached and result.attached, label .. " notice policy")
  end
  local screen, styled = frame({ { text = "❯ " } }, nil)
  styled.rows[3] = { { text = "" } }
  table.insert(styled.rows, 4, { { text = RULE } })
  T.eq(decide("claude", join(styled.rows), styled).composer, "EMPTY", "blank rows before the bottom border are fine")
end)

T.test("styled proof: anything else defers", function()
  local refusals = {
    typed = { { text = "❯ co" } },
    normal_try = { { text = '❯ Try "fix typecheck errors"' } },
    generic_dim = { { text = "❯ " }, { text = "generic suggestion", dim = true } },
    half_try = { { text = "❯ " }, { text = 'Try "fix', dim = true } },
    mixed_style = { { text = "❯ " }, { text = "Try ", dim = true }, { text = '"fix typecheck errors"' } },
    ghost_then_typed = { { text = "❯ " }, { text = 'Try "fix"', dim = true }, { text = " user draft" } },
    dim_draft = { { text = "❯ " }, { text = "user draft", dim = true } },
    no_glyph = { { text = "Try " }, { text = '"fix"', dim = true } },
  }
  for label, prompt in pairs(refusals) do
    local screen, styled = frame(prompt)
    T.ok(safe(decide("claude", screen, styled)), label .. " must defer")
  end
  local below = {
    footer_lookalike = "MODEL:secret_draft CTX:123", shortcuts = "? for shortcuts user draft",
    mode = "⏵⏵ auto mode on", draft = "user draft", corner = "╰user draft", dash = "─user draft",
    prompt_glyph = "❯ ", pipe = "│", short_rule_draft = "────user draft",
  }
  for label, text in pairs(below) do
    for _, ghost in ipairs({ false, true }) do
      local prompt = ghost and { { text = "❯ " }, { text = 'Try "fix"', dim = true } } or { { text = "❯ " } }
      local screen, styled = frame(prompt, { { text = text } })
      styled.rows[4] = { { text = RULE } }
      T.ok(safe(decide("claude", join(styled.rows), styled)), label .. (ghost and " under a ghost" or "") .. " row before the border defers")
    end
  end
  -- No bottom border / cursor off the prompt row / plain capture disagreeing with the styled rows.
  local screen, styled = frame({ { text = "❯ " } })
  styled.rows[3] = nil
  T.ok(safe(decide("claude", join(styled.rows), styled)), "no bottom border")
  screen, styled = frame({ { text = "❯ " } })
  styled.cursor = 1
  T.ok(safe(decide("claude", screen, styled)), "cursor on the rule row")
  screen, styled = frame({ { text = "❯ " } })
  T.ok(safe(decide("claude", (screen:gsub("❯ ", "❯ user draft")), styled)), "plain capture shows a draft the styled rows hide")
  T.ok(safe(decide("claude", screen .. "\nuser draft", styled)), "plain capture has an extra row")
  screen, styled = frame({ { text = "❯ " } })
  styled.rows[3] = { { text = "────" } }
  T.ok(safe(decide("claude", join(styled.rows), styled)), "bottom border shorter than the top border")
  screen, styled = frame({ { text = "❯ " } })
  styled.rows[1] = { { text = "────" } }
  T.ok(safe(decide("claude", join(styled.rows), styled)), "top border shorter than the bottom border")
  styled.rows[3] = { { text = "────user draft" } }
  T.ok(safe(decide("claude", join(styled.rows), styled)), "short borders cannot prove a composer")
end)

T.test("SEC round 4 repros stay deferred", function()
  local ghost = 'Try "refactor <filepath>"'
  local cases = {
    { "no top rule, MODEL-like draft row", "❯ \nMODEL:secret_draft CTX:123\n────",
      { { { text = "❯ " } }, { { text = "MODEL:secret_draft CTX:123" } }, { { text = "────" } } } },
    { "dim Try, MODEL-like draft row", "❯ " .. ghost .. "\nMODEL:secret_draft CTX:123\n────",
      { { { text = "❯ " }, { text = ghost, dim = true } }, { { text = "MODEL:secret_draft CTX:123" } }, { { text = "────" } } } },
    { "rule before the prompt, MODEL-like draft row", "────\n❯ \nMODEL:secret_draft CTX:123\n────",
      { { { text = "────" } }, { { text = "❯ " } }, { { text = "MODEL:secret_draft CTX:123" } }, { { text = "────" } } }, 2 },
    { "dim Try, rule before the prompt, MODEL-like draft row", "────\n❯ " .. ghost .. "\nMODEL:secret_draft CTX:123\n────",
      { { { text = "────" } }, { { text = "❯ " }, { text = ghost, dim = true } }, { { text = "MODEL:secret_draft CTX:123" } }, { { text = "────" } } }, 2 },
    { "draft then a later blank prompt", "────❯ \nuser draft\n────\n❯ \n────",
      { { { text = "────❯ " } }, { { text = "user draft" } }, { { text = "────" } }, { { text = "❯ " } }, { { text = "────" } } } },
    { "dim Try, draft then a later blank prompt", "────❯ " .. ghost .. "\nuser draft\n────\n❯ \n────",
      { { { text = "────" }, { text = "❯ " }, { text = ghost, dim = true } }, { { text = "user draft" } }, { { text = "────" } },
        { { text = "❯ " } }, { { text = "────" } } } },
  }
  for _, case in ipairs(cases) do
    T.ok(safe(decide("claude", case[2], { rows = case[3], cursor = case[4] or 1 })), case[1] .. " (full styled rows)")
    T.ok(safe(decide("claude", case[2], { rows = { case[3][case[4] or 1] }, cursor = 1 })), case[1] .. " (cursor row only)")
    T.ok(safe(decide("claude", case[2], nil)), case[1] .. " (no styled capture)")
  end
end)


-- SEC audit probes, inlined from the round 2, 3 and 4 audits. Each probe is one plain capture plus
-- (optionally) a one-row styled capture on the cursor row, as the auditors stubbed them. Every probe
-- must be safe: never typed (detached or attached), never EMPTY. Real EMPTY composers are proven by the
-- full-frame fixture tests above.
local GHOST = 'Try "refactor <filepath>"'
local FIXTURES_18 = {
  "claude-2.1.292-100x30.txt", "claude-2.1.292-120x30.txt", "claude-2.1.292-140x30.txt",
  "claude-2.1.292-win/claude-2.1.292-100x30.txt", "claude-2.1.292-win/claude-2.1.292-120x30.txt",
  "claude-2.1.292-win/claude-2.1.292-140x30.txt",
  "claude-model-confirm-composer-one-row-status.txt", "claude-model-confirm-composer-two-row-status.txt",
  "claude-model-confirm-dialog-changing-status.txt", "claude-model-confirm-dialog-with-status.txt",
  "claude-model-confirm-dialog.txt", "claude-model-confirm-live-capture-0556Z.txt",
  "claude-model-confirm-live-composer-nbsp.txt", "claude-model-confirm-multiline-draft.txt",
  "claude-model-confirm-transcript-copy.txt", "claude-model-confirm-wrong-title.txt",
  "claude-stale-model-confirm-with-permission.txt", "claude-trust-dialog.txt",
}

local function probe_list()
  local cases = {}
  local function add(name, screen, style, kind, mode)
    cases[#cases + 1] = { name = name, screen = screen, rows = style and { style } or nil,
      kind = kind or "claude", mode = mode }
  end
  return cases, add
end

-- Rounds 3 and 4 `audit`: 316 probes.
local function sec3_probes()
  local cases, add = probe_list()
  local tails = {
    { "multiline", "user draft" }, { "rule_draft", "────\nuser draft" }, { "dash", "─user draft" },
    { "mode_prefix", "─⏵⏵ user draft" }, { "rule_mode_draft", "────\n─⏵⏵ user draft" },
    { "mode_then_draft", "⏵⏵ auto mode on\nuser draft" }, { "corner_round", "╰user draft" },
    { "corner_square", "└user draft" }, { "shortcuts_prefix", "? for shortcuts user draft" },
    { "empty_prompt", "user draft\n❯ " }, { "empty_ascii_prompt", "user draft\n> " },
    { "empty_small_prompt", "user draft\n› " }, { "empty_wrapped_prompt", "user draft\n─❯ " },
    { "empty_pipe_prompt", "user draft\n│ ❯ " }, { "rule_only", "────" },
    { "mode_exact", "⏵⏵ auto mode on" }, { "ansi_draft", "\27[2muser draft\27[0m" },
    { "nbsp_draft", " user draft" }, { "crlf_draft", "user draft\r\nmore draft" },
    { "long_draft", string.rep("x", 5000) }, { "prompt_after_ansi", "user draft\n\27[0m❯ " },
    { "prompt_after_corner", "user draft\n╰❯ " }, { "row_start_rule", "─\nuser draft" },
  }
  for _, w in ipairs({ 0, 1, 4, 100, 120, 140 }) do
    local p = string.rep("─", w) .. "❯ "
    add(w .. "/empty", p .. "\n────", { { text = p } })
    add(w .. "/dim_try", p .. GHOST .. "\n────", { { text = p }, { text = GHOST, dim = true } })
    add(w .. "/normal_try", p .. GHOST .. "\n────", { { text = p .. GHOST } })
    add(w .. "/half_try", p .. 'Try "refa\n────', { { text = p .. 'Try "refa' } })
    add(w .. "/raw_try", p .. GHOST .. "\n────", nil)
    add(w .. "/mixed_style", p .. GHOST .. "\n────",
      { { text = p }, { text = "Try ", dim = true }, { text = '"refactor <filepath>"' } })
    add(w .. "/typed_after_ghost", p .. GHOST .. " user draft\n────",
      { { text = p }, { text = GHOST, dim = true }, { text = " user draft" } })
    for _, tail in ipairs(tails) do
      if tail[1] ~= "rule_only" and tail[1] ~= "mode_exact" then
        add(w .. "/empty_" .. tail[1], p .. "\n" .. tail[2] .. "\n────", { { text = p } })
        add(w .. "/ghost_" .. tail[1], p .. GHOST .. "\n" .. tail[2] .. "\n────",
          { { text = p }, { text = GHOST, dim = true } })
      end
    end
  end
  for _, s in ipairs({ "unrecognized draft", "\27[0m❯ user draft", "─❯ Teach auto mode\n────",
      "─❯ Yes, continue\n────", "Trust this folder?\n─❯ Yes, I trust this folder\n────",
      "Quick safety check:\n─❯ \n────", "Updating Codex\n❯ " }) do add("odd/" .. s, s, nil) end
  add("unparseable_style", "unrecognized draft", { { text = "❯ " }, { text = GHOST, dim = true } })
  add("codex_dim", "> " .. GHOST, { { text = "> " }, { text = GHOST, dim = true } }, "codex")
  add("split_word_ghost", '❯ Try "fix typecheck errors"\n────', {
    { text = "❯ " }, { text = "Try", dim = true }, { text = " " }, { text = '"fix', dim = true },
    { text = " " }, { text = "typecheck", dim = true }, { text = " " }, { text = 'errors"', dim = true } })
  for _, path in ipairs(FIXTURES_18) do
    if path:find("2.1.292", 1, true) then
      local screen = read_fixture(path)
      local row = assert(screen:match("([^\n]*❯[^\n]*)"))
      local at = assert(row:find('Try "', 1, true))
      add("fixture_dim/" .. path, screen, { { text = row:sub(1, at - 1) }, { text = row:sub(at), dim = true } })
      add("fixture_normal/" .. path, screen, { { text = row } })
    end
  end
  return cases
end

-- Round 4 `adversarial`: 425 new probes.
local function sec4_probes()
  local cases, add = probe_list()
  local footers = { "? for shortcuts", "⏵⏵ auto mode on", "⏵⏵ auto mode on (shift+tab to cycle) · ← for agents",
    "MODEL:secret_draft CTX:123", "MODEL:Opus-5.5 CTX:123 CTXWIN:200k CTXPCT:2",
    "⏵⏵ auto mode on · 2 shells · ← 3 agents", "⏵⏵ auto mode on      · ←…" }
  for _, w in ipairs({ 0, 4, 100, 120, 140 }) do
    local p = string.rep("─", w) .. "❯ "
    local rule = string.rep("─", math.max(w, 4))
    local style = { { text = p }, { text = GHOST, dim = true } }
    for i, footer in ipairs(footers) do
      add(w .. "/typed_exact_footer_" .. i, p .. "\n" .. footer .. "\n" .. rule, { { text = p } })
      add(w .. "/ghost_plus_typed_footer_" .. i, p .. GHOST .. "\n" .. footer .. "\n" .. rule, style)
      add(w .. "/ghost_plus_nbsp_footer_" .. i, p .. GHOST .. "\n " .. footer .. "\n" .. rule, style)
      add(w .. "/typed_footer_plus_long_draft_" .. i,
        p .. "\n" .. footer .. "\n" .. string.rep("x", 5000) .. "\n" .. rule, { { text = p } })
    end
    for _, tail in ipairs({ "│", "│ ", "────", "────\n❯ ", "user draft\n────\n❯ ", "user draft\n────\n─❯ ",
        "user draft\n────\n> ", "user draft\n────\n› ", 'user draft\n────\n❯ Try "refactor <filepath>"',
        "user draft\n────⏵⏵ auto mode on\n❯ ", "? for shortcuts user draft", "─⏵⏵ auto mode on user draft",
        "╰draft", "└draft", " draft", "\27[2mdraft\27[0m", "━❯ draft", "—❯ draft", "❱ draft", "❯ draft",
        "\27[0m❯ draft" }) do
      add(w .. "/tail/" .. tail, p .. "\n" .. tail .. "\n" .. rule, { { text = p } })
      add(w .. "/ghost_tail/" .. tail, p .. GHOST .. "\n" .. tail .. "\n" .. rule, style)
    end
    for _, suffix in ipairs({ " user draft", " user draft", "│", "⏵⏵ auto mode on", "\27[0mtyped", 'Try "second"' }) do
      add(w .. "/inline/" .. suffix, p .. GHOST .. suffix .. "\n" .. rule,
        { { text = p }, { text = GHOST, dim = true }, { text = suffix } })
    end
    for _, header in ipairs({ "Teach auto mode", "Quick safety check:", "Trust this folder?", "Update available",
        "Updating Codex" }) do
      add(w .. "/modal/" .. header, header .. "\n" .. rule .. "❯ " .. header .. "\n" .. rule, nil)
    end
    add(w .. "/mismatch", p .. "user draft\n" .. rule, style)
    add(w .. "/normal_try", p .. GHOST .. "\n" .. rule, { { text = p .. GHOST } })
    add(w .. "/half_try", p .. 'Try "refa\n' .. rule, { { text = p }, { text = 'Try "refa', dim = true } })
    add(w .. "/ansi_tail", p .. GHOST .. "\n\27[0muser draft\n" .. rule, style)
  end
  return cases
end

-- Round 2 `audit`: the original wrapped-prompt probes (incl. a failing styled capture).
local function sec2_probes()
  local cases, add = probe_list()
  local prefixes = { "❯ ", "────❯ ", "─❯ ", "│ ❯ ", "  ────❯ ", "────❯ ", "────\n❯ " }
  for i, p in ipairs(prefixes) do
    local row = p:match("([^\n]*)$")
    add(i .. "/empty", p .. "\n────", { { text = row } })
    add(i .. "/typed_try", p .. GHOST .. "\n────", { { text = row .. GHOST } })
    add(i .. "/half_typed", p .. 'Try "re' .. "\n────", { { text = row .. 'Try "re' } })
    add(i .. "/multiline", p .. "\nuser draft\n────", { { text = row } })
    add(i .. "/dash_continuation", p .. "\n─user draft\n────", { { text = row } })
    add(i .. "/ghost_continuation", p .. GHOST .. "\nuser draft\n────", { { text = row }, { text = GHOST, dim = true } })
    add(i .. "/ghost_plus_typed", p .. GHOST .. "user draft\n────",
      { { text = row }, { text = GHOST, dim = true }, { text = "user draft" } })
  end
  for _, p in ipairs({ "❯ ", "────❯ " }) do
    add(p .. "/dim_try", p .. GHOST .. "\n────", { { text = p }, { text = GHOST, dim = true } })
    add(p .. "/generic_dim", p .. "generic hint\n────", { { text = p }, { text = "generic hint", dim = true } })
    add(p .. "/no_style", p .. GHOST .. "\n────", nil)
    add(p .. "/style_error", p .. GHOST .. "\n────", nil, nil, "error")
    add(p .. "/style_mismatch", p .. 'Try "different"\n────', { { text = p }, { text = GHOST, dim = true } })
    add(p .. "/ghost_then_text_next_row", p .. GHOST .. "\nuser draft\n────", { { text = p }, { text = GHOST, dim = true } })
    add(p .. "/border_only_draft", p .. "\n────\nuser draft\n────", { { text = p } })
    add(p .. "/footer_prefix_draft", p .. "\n─⏵⏵ user draft\n────", { { text = p } })
    add(p .. "/new_prompt_in_continuation", p .. "user draft\n❯ \n────", { { text = p .. "user draft" } })
  end
  add("codex_dim", "> " .. GHOST .. "\n────", { { text = "> " }, { text = GHOST, dim = true } }, "codex")
  add("unparseable_styled_prompt", "unrecognized user draft", { { text = "❯ " }, { text = GHOST, dim = true } })
  add("unparseable_no_style", "unrecognized user draft", nil)
  add("try_missing_quote", "────❯ Try refactor\n────", { { text = "────❯ " }, { text = "Try refactor", dim = true } })
  for _, path in ipairs(TRY_FIXTURES) do
    local screen = read_fixture(path)
    local line = assert(screen:match("([^\n]*❯[^\n]*)"))
    local at = assert(line:find('Try "', 1, true))
    add("fixture/" .. path, screen, { { text = line:sub(1, at - 1) }, { text = line:sub(at), dim = true } })
    add("fixture_normal/" .. path, screen, { { text = line } })
  end
  return cases
end

local function run_probes(label, cases, expected_count)
  T.eq(#cases, expected_count, label .. " probe count")
  for _, case in ipairs(cases) do
    local styled = case.mode == "error" and "error" or (case.rows and { rows = case.rows, cursor = 1 }) or nil
    local result = decide(case.kind, case.screen, styled)
    if case.kind == "codex" then
      -- Out of scope: the Claude-only rule leaves main's Codex contract (a dim ghost is an idle prompt, #137).
      T.ok(result.detached and result.attached, label .. " " .. case.name .. " keeps main's Codex dim-ghost contract")
      goto continue
    end
    T.ok(not result.detached and not result.attached,
      label .. " " .. case.name:gsub("%c", "?") .. " must not type (detached=" .. tostring(result.detached)
      .. " attached=" .. tostring(result.attached) .. ")")
    if styled then
      T.ok(result.composer ~= "EMPTY", label .. " " .. case.name:gsub("%c", "?") .. " composer must not be EMPTY")
    end
    ::continue::
  end
end

T.test("SEC round 2 probes never type", function() run_probes("SEC2", sec2_probes(), 83) end)
T.test("SEC round 3 probes (316) never type", function() run_probes("SEC3", sec3_probes(), 316) end)
T.test("SEC round 4 probes (425) never type", function() run_probes("SEC4", sec4_probes(), 425) end)


T.test("all Claude fixtures retain main-branch classifications", function()
  local fixtures = {
    { "claude-2.1.292-100x30.txt", false, "UNPARSEABLE" },
    { "claude-2.1.292-120x30.txt", false, "UNPARSEABLE" },
    { "claude-2.1.292-140x30.txt", false, "UNPARSEABLE" },
    { "claude-2.1.292-win/claude-2.1.292-100x30.txt", false, "UNPARSEABLE" },
    { "claude-2.1.292-win/claude-2.1.292-120x30.txt", false, "UNPARSEABLE" },
    { "claude-2.1.292-win/claude-2.1.292-140x30.txt", false, "UNPARSEABLE" },
    { "claude-model-confirm-composer-one-row-status.txt", true, "EMPTY" },
    { "claude-model-confirm-composer-two-row-status.txt", true, "EMPTY" },
    { "claude-model-confirm-dialog-changing-status.txt", false, "NON-EMPTY" },
    { "claude-model-confirm-dialog-with-status.txt", false, "NON-EMPTY" },
    { "claude-model-confirm-dialog.txt", false, "NON-EMPTY" },
    { "claude-model-confirm-live-capture-0556Z.txt", true, "EMPTY" },
    { "claude-model-confirm-live-composer-nbsp.txt", true, "EMPTY" },
    { "claude-model-confirm-multiline-draft.txt", true, "NON-EMPTY" },
    { "claude-model-confirm-transcript-copy.txt", true, "EMPTY" },
    { "claude-model-confirm-wrong-title.txt", false, "NON-EMPTY" },
    { "claude-stale-model-confirm-with-permission.txt", false, "NON-EMPTY" },
    { "claude-trust-dialog.txt", false, "NON-EMPTY" },
  }
  for _, fixture in ipairs(fixtures) do
    local path = os.getenv("REMUDA_LUA_REPO") .. "/tests/fixtures/" .. fixture[1]
    local file = assert(io.open(path, "rb"))
    local screen = file:read("*a")
    file:close()
    T.eq(T.eval(string.format("return tostring(remuda._butler_agent_startup.claude.ready(%q))", screen)),
      tostring(fixture[2]), fixture[1] .. " readiness classification")
    T.eq(T.eval(string.format("local decision = remuda._butler_prompt_is_empty('claude', %q); return decision", screen)),
      fixture[3], fixture[1] .. " composer classification")
  end
end)


T.test("narrow wrapped notices are verified and submitted", function()
  T.eval([=[
    local state = { columns = 27, events = {}, screen = "❯ \n", submitted = false, busy = false,
      notice = "Butler message 01M4B0QGR0DVRZ0AY6D6QKNEE5 from local/butler-platform-lead arrived. Read it: MCP butler_inbox (or remuda butler inbox)" }
    remuda._matrix_narrow_state = state
    remuda._butler_bus.agents["matrix-narrow"] = { kind = "claude", id = "matrix-narrow" }
    remuda._butler_bus.notice_recoveries["matrix-narrow"] = nil
    remuda.capture_styled = nil
    remuda._butler_notice_clock = function() return 100 end
    remuda.ls = function() return {{name="matrix-narrow",alive=true,attached=false}} end
    remuda.session = function() return {is_busy=state.busy} end
    remuda.capture = function() return state.screen end
    remuda._butler_notify_policy = function() return true end
    local function render_notice(text)
      local rows, width, line = {}, state.columns - 2, ""
      local function push(prefix, value)
        rows[#rows + 1] = prefix .. value .. string.rep(" ", state.columns - 2 - #value)
      end
      local function append_word(word)
        while #word > width do
          if line ~= "" then push(#rows == 0 and "❯ " or "  ", line); line = "" end
          push(#rows == 0 and "❯ " or "  ", word:sub(1, width))
          word = word:sub(width + 1)
        end
        if line == "" then line = word
        elseif #line + 1 + #word <= width then line = line .. " " .. word
        else push(#rows == 0 and "❯ " or "  ", line); line = word end
      end
      for word in text:gmatch("%S+") do append_word(word) end
      push(#rows == 0 and "❯ " or "  ", line)
      local rule = string.rep("─", state.columns)
      local empty_prompt = "❯ " .. string.rep(" ", state.columns - 2)
      local status = "  MODEL:Opus-5.5 CTX:13925…\n  ⏵⏵ auto mode on      · ←…"
      local screen = rule .. "\n" .. table.concat(rows, "\n") .. "\n" .. rule
      if state.submitted then screen = screen .. "\n" .. empty_prompt .. "\n" .. rule end
      return screen .. "\n" .. status
    end
    remuda.type_text = function(_, text)
      table.insert(state.events, "type")
      state.screen = render_notice(text)
      return true
    end
    remuda.key = function(_, key)
      table.insert(state.events, "key " .. key)
      if key == "RET" then
        state.submitted, state.busy = true, true
        state.screen = "❯ " .. string.rep(" ", state.columns - 2)
          .. "\n" .. string.rep("─", state.columns) .. "\n  MODEL:Opus-5.5 CTX:13925…"
      end
    end
    local function run_notice()
      remuda._butler_bus.notices["matrix-narrow"] = {count=1,text=state.notice,due_at=0}
      for _ = 1, 4 do remuda._butler_deliver_notices() end
      return table.concat(state.events, ","), remuda._butler_bus.notices["matrix-narrow"] == nil
    end
    local events, done = run_notice()
    assert(done, "wrapped notice was not verified")
    assert(events:find("key RET", 1, true), "wrapped notice was not submitted: " .. events)
    assert(not events:find("key C-u", 1, true), "recovery erased its wrapped notice: " .. events)
    state.events, state.submitted, state.busy = {}, true, false
    remuda._butler_bus.notice_recoveries["matrix-narrow"] = nil
    local history_events, history_done = run_notice()
    assert(history_done, "wrapped history notice was not verified")
    assert(history_events:find("type", 1, true), "history notice was not seen: " .. history_events)
    assert(not history_events:find("key RET", 1, true), "history notice was submitted twice: " .. history_events)
  ]=])
end)
