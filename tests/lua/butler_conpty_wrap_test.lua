-- ConPTY may join Claude's full-width composer border and prompt glyph on one
-- captured row, while leaving the first captured row blank. This file covers readiness
-- (the anchored rule-row match) and launch diagnostics (row 1 only). Composer-emptiness
-- (notice.lua) is deliberately unchanged from main.
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
-- Lua literal with every non-printable byte escaped, so invalid UTF-8 survives the eval transport.
local function esc(text)
  return '"' .. text:gsub('[^ -!#-%[%]-~]', function(c) return string.format("\\%03d", c:byte()) end) .. '"'
end
local probe_count = 0
local function launch_diagnostic(kind, screen, throw)
  probe_count = probe_count + 1
  local name = "diag-" .. probe_count
  T.eval(string.format([[
    remuda._butler_agent_builders[%q] = function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_test_force_launch_probe = remuda._butler_test_force_launch_probe or {}
    remuda._butler_test_force_launch_probe[%q] = true
    remuda.capture = function(session) if session == %q then if %s then error(%s, 0) end return %s end return "" end
    remuda._diag = remuda._diag or {}
    remuda._butler_choose_async({ %q }, {
      name = %q, cwd = os.getenv("XDG_DATA_HOME"), timeout = 4,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, attempts) remuda._diag[%q] = attempts[1] end)
  ]], kind, name, name, tostring(throw == true), esc(screen), esc(screen), kind, name, name))
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

local NONPLAIN = "<first row: non-plain, "
local function sanitize(input)
  return T.eval("return remuda._butler_chooser.sanitize_row(" .. esc(input) .. ")")
end
local function placeholder(input) return NONPLAIN .. math.min(#input, 240) .. " bytes>" end

T.test("launch diagnostics show an allowlisted row 1 only, never a later row", function()
  local screens = {
    { "claude", "\nSECRET_SENTINEL_ROW2\nPlease log in", "login", "<empty first row>" },
    { "claude", "   \nSECRET_SENTINEL_ROW2\nPlease log in", "login", "<empty first row>" },
    { "claude", "\r\nSECRET_SENTINEL_ROW2\nPlease log in", "login", "<empty first row>" },
    { "claude", "\nSECRET_SENTINEL_ROW2\nPress enter to continue", "dialog", "<empty first row>" },
    { "retry_probe", "   \nSECRET_SENTINEL_ROW2", "timeout", "<empty first row>" },
    { "retry_probe", "\r\nSECRET_SENTINEL_ROW2", "timeout", "<empty first row>" },
    { "claude", "Please log in\nSECRET_SENTINEL_ROW2", "login", "Please log in" },
    { "retry_probe", "first visible row\nSECRET_SENTINEL_ROW2", "timeout", "first visible row" },
    { "claude", "\27[2mPlease log in\27[0m\a\nSECRET_SENTINEL_ROW2", "login", NONPLAIN },
    { "claude", "\27[2m\27[0m\nSECRET_SENTINEL_ROW2\nPress enter to continue", "dialog", NONPLAIN },
    { "claude", "Please log in \27]8;;https://example.invalid/SECRET_OSClabel\7link\27]8;;\7", "login", NONPLAIN },
    { "claude", "Please log in \27]8;;https://example.invalid/SECRET_OSClabel\27\\link\27]8;;\27\\", "login", NONPLAIN },
    { "claude", "Please log in \27P1$rSECRET_DCS\27\\\27_SECRET_APC\27\\\27^SECRET_PM\27\\", "login", NONPLAIN },
    { "claude", "Please log in ──── \226\148", "login", NONPLAIN },
  }
  for index, item in ipairs(screens) do
    local reason, detail, sessions, trace = launch_diagnostic(item[1], item[2])
    T.eq(reason, item[3], "diagnostic " .. index .. " reason")
    T.ok(detail:find(item[4], 1, true), "diagnostic " .. index .. " should show row 1: " .. detail)
    for label, text in pairs({ detail = detail, sessions = sessions, trace = trace }) do
      T.ok(not text:find("SECRET", 1, true), "diagnostic " .. index .. " leaked into " .. label)
      T.ok(not text:find("\27", 1, true), "diagnostic " .. index .. " kept a control byte in " .. label)
    end
  end
  local _, long = launch_diagnostic("claude", "Please log in " .. string.rep("x", 300) .. "SECRET_AFTER_80\nSECRET_SENTINEL_ROW2")
  T.eq(#long, 80, "plain first row is cut at 80 characters: " .. long)
  T.ok(not long:find("SECRET", 1, true), "text past 80 characters leaked: " .. long)
end)

T.test("sanitize_row allowlists plain ASCII and otherwise prints only a fixed placeholder", function()
  local payloads = {
    "Please log in \27P x\7 SECRET_DCS\27\\", "Please log in \27_ x\7 SECRET_APC\27\\", "Please log in \27^ SECRET_PM\27\\",
    "Please log in \27X SECRET_SOS\27\\", "Please log in \27]8;;http://x/SECRET_OSC8\7label\27]8;;\7",
    "Please log in \27[38:2::1:2:3m SECRET_CSI", "A\27[ qSECRET", "A\27[1;SECRET",
    "A\194\157" .. "8;;SECRET_C1\194\156B", "A\194\144 x SECRET_C1_DCS\194\156", "A\194\155" .. "31m SECRET",
    "A\157" .. "SECRET_RAW\156B", "A\144 SECRET_RAW", "A\159 SECRET_RAW", "A\158 SECRET_RAW", "A\152 SECRET_RAW", "A\155 SECRET_RAW",
    string.char(194, 0, 157) .. "8;;SECRET_SYNTH" .. string.char(194, 0, 156),
    string.char(194, 27, 157) .. "8;;SECRET_SYNTH" .. string.char(194, 7, 156),
    "A\t SECRET", "A\127 SECRET", "A\0 SECRET", "é SECRET", "界 SECRET", "\240\128\128\128 SECRET", "\237\160\128 SECRET",
    "\244\144\128\128 SECRET", "A" .. string.rep("\128", 10000),
  }
  for index, input in ipairs(payloads) do
    local got = sanitize(input)
    T.eq(got, placeholder(input), "payload " .. index .. " becomes the placeholder")
    T.ok(not got:find("SECRET", 1, true) and not got:find("[^\32-\126]"), "payload " .. index .. " leaks no payload byte")
  end
  T.eq(sanitize("\27" .. string.rep("x", 1000)), NONPLAIN .. "240 bytes>", "placeholder length is capped at 240")
  T.eq(sanitize("Please log in"), "Please log in", "plain text is kept")
  T.eq(sanitize("  indented"), "  indented", "plain text is kept verbatim")
  T.eq(sanitize(string.rep("x", 1000)), string.rep("x", 80), "long plain row is cut at 80 characters")
  T.eq(sanitize("A" .. string.rep(" ", 100) .. "B"), "A", "trailing spaces after the cut are trimmed")
  T.eq(sanitize("one\nSECRET_ROW2"), "one", "row 2 never appears")
  T.eq(sanitize("one\rSECRET_ROW2"), "one", "a bare CR ends row 1")
  for _, blank in ipairs({ "", "   ", "\nSECRET_ROW2", "   \nSECRET_ROW2", "\r\nSECRET_ROW2" }) do
    T.eq(sanitize(blank), "<empty first row>", "blank row 1")
  end
  T.eq(T.eval("return remuda._butler_chooser.sanitize_row(12345)"), "12345", "non-strings go through tostring")
  T.eq(T.eval("return remuda._butler_chooser.sanitize_row(nil)"), "<empty first row>", "nil is an empty row")
end)

T.test("sanitize_row stays linear on floods", function()
  local out = T.eval([[
    local s = remuda._butler_chooser.sanitize_row
    local inputs = { string.rep(" ", 100000), "A" .. string.rep(" ", 16000) .. "B", "A" .. string.rep(" ", 100000) .. "B",
      string.rep("x", 16384), string.rep("\27", 16384), string.rep("\194", 100000), "\27]" .. string.rep("x\194", 40000) }
    local worst = 0
    for _, input in ipairs(inputs) do
      local started = os.clock()
      s(input)
      worst = math.max(worst, os.clock() - started)
    end
    return tostring(worst)
  ]])
  T.ok(tonumber(out) < 0.05, "sanitizer worst case " .. out .. "s must stay under 0.05s")
end)

T.test("real ConPTY captures give sensible row-1 diagnostics", function()
  for _, path in ipairs({ "claude-2.1.292-win/claude-2.1.292-100x30.txt", "claude-2.1.292-120x30.txt" }) do
    local screen = read_fixture(path)
    T.eq(sanitize(screen), "<empty first row>", path .. " starts with an empty row")
    local prompt_row = screen:match("([^\n]*❯[^\n]*)")
    T.eq(sanitize(prompt_row), placeholder(prompt_row), path .. " box-drawing prompt row becomes the placeholder")
  end
end)

T.test("capture errors reach diagnostics through the same function", function()
  local message = "capture failed \27]8;;SECRET_ERR\7link\27]8;;\7 " .. string.rep("x", 5000) .. "\nSECRET_ERR_ROW2"
  local reason, detail, sessions, trace = launch_diagnostic("retry_probe", message, true)
  T.eq(reason, "ready_unverified", "a pane whose capture always fails stays unverified")
  for label, text in pairs({ detail = detail, sessions = sessions, trace = trace }) do
    T.ok(not text:find("SECRET", 1, true), "capture error leaked into " .. label)
    T.ok(not text:find("\27", 1, true), "capture error kept a control byte in " .. label)
  end
  T.ok(detail:find("last capture error: " .. NONPLAIN, 1, true), "non-plain error text is a placeholder: " .. detail)
  _, detail = launch_diagnostic("retry_probe", "capture failed plainly\nSECRET_ROW2", true)
  T.ok(detail:find("last capture error: capture failed plainly", 1, true), "plain error text is kept: " .. detail)
  T.ok(not detail:find("SECRET", 1, true), "error row 2 never appears")
end)

local TRY_FIXTURES = {
  "claude-2.1.292-100x30.txt", "claude-2.1.292-120x30.txt", "claude-2.1.292-140x30.txt",
  "claude-2.1.292-win/claude-2.1.292-100x30.txt", "claude-2.1.292-win/claude-2.1.292-120x30.txt",
  "claude-2.1.292-win/claude-2.1.292-140x30.txt",
}

T.test("real Claude 2.1.292 captures (incl. ConPTY) are ready through the launch path", function()
  for index, path in ipairs(TRY_FIXTURES) do
    local screen = read_fixture(path)
    local name = "ready-fixture-" .. index
    T.eval(string.format([[
      remuda._butler_agent_builders.claude = function() return { "sh", "-c", "sleep 60" } end
      remuda._butler_test_force_launch_probe = remuda._butler_test_force_launch_probe or {}
      remuda._butler_test_force_launch_probe[%q] = true
      remuda.capture = function(session) if session == %q then return %q end return "" end
      remuda._ready_fixture = remuda._ready_fixture or {}
      remuda._butler_choose_async({ "claude" }, {
        name = %q, cwd = os.getenv("XDG_DATA_HOME"), timeout = 3,
        spec = function() return {} end, env = function() return {} end,
      }, function(_, _, attempts) remuda._ready_fixture[%q] = attempts[1].reason end)
    ]], name, name, screen, name, name))
    T.wait_until(function()
      return T.eval(string.format("return tostring(remuda._ready_fixture[%q])", name)) ~= "nil"
    end, 8, path .. " readiness")
    T.eq(T.eval(string.format("return remuda._ready_fixture[%q]", name)), "ready", path .. " must be ready")
    T.eval(string.format("pcall(remuda.close, %q)", name))
  end
end)

T.test("Claude readiness table over the real fixtures matches main", function()
  local fixtures = {
    { "claude-model-confirm-composer-one-row-status.txt", true },
    { "claude-model-confirm-composer-two-row-status.txt", true },
    { "claude-model-confirm-dialog-changing-status.txt", false },
    { "claude-model-confirm-dialog-with-status.txt", false },
    { "claude-model-confirm-dialog.txt", false },
    { "claude-model-confirm-live-capture-0556Z.txt", true },
    { "claude-model-confirm-live-composer-nbsp.txt", true },
    { "claude-model-confirm-multiline-draft.txt", true },
    { "claude-model-confirm-transcript-copy.txt", true },
    { "claude-model-confirm-wrong-title.txt", false },
    { "claude-stale-model-confirm-with-permission.txt", false },
    { "claude-trust-dialog.txt", false },
  }
  for _, fixture in ipairs(fixtures) do
    T.eq(T.eval(string.format("return tostring(remuda._butler_agent_startup.claude.ready(%q))", read_fixture(fixture[1]))),
      tostring(fixture[2]), fixture[1] .. " readiness")
  end
end)
