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
    { "claude", "Please log in \27]8;;https://example.invalid/SECRET_OSClabel\7link\27]8;;\7\nSECRET_SENTINEL_ROW2", "login", "Please log in" },
    { "claude", "Please log in \27]8;;https://example.invalid/SECRET_OSClabel\27\\link\27]8;;\27\\", "login", "Please log in" },
    { "claude", "Please log in \27P1$rSECRET_DCS\27\\\27_SECRET_APC\27\\\27^SECRET_PM\27\\", "login", "Please log in" },
    { "claude", "Please log in \27]8;;SECRET_OSC_UNTERMINATED", "login", "Please log in" },
  }
  for index, item in ipairs(screens) do
    local reason, detail, sessions, trace = launch_diagnostic(item[1], item[2])
    T.eq(reason, item[3], "diagnostic " .. index .. " reason")
    T.ok(detail:find(item[4], 1, true), "diagnostic " .. index .. " should show row 1: " .. detail)
    for label, text in pairs({ detail = detail, sessions = sessions, trace = trace }) do
      T.ok(not text:find("SECRET", 1, true), "diagnostic " .. index .. " leaked a later row or a control-string payload into " .. label)
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


local function valid_utf8(text)
  local i, n = 1, #text
  while i <= n do
    local b = text:byte(i)
    local len = b < 0x80 and 1 or (b >= 0xC2 and b <= 0xDF) and 2 or (b >= 0xE0 and b <= 0xEF) and 3
      or (b >= 0xF0 and b <= 0xF4) and 4 or nil
    if not len or i + len - 1 > n then return false end
    for k = 1, len - 1 do
      local c = text:byte(i + k)
      if c < 0x80 or c > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

T.test("launch diagnostics drop every string control, C1 form and CSI shape", function()
  local cases = {
    "Please log in \27P1$r PUBLIC \7 SECRET_DCS\27\\ ok",
    "Please log in \27_ PUBLIC \7 SECRET_APC\27\\ ok",
    "Please log in \27^ PUBLIC \7 SECRET_PM\27\\ ok",
    "Please log in \27X PUBLIC \7 SECRET_SOS\27\\ ok",
    "Please log in \27]0;title\27\\\27]8;;SECRET_OSC_ST\27\\x\27]8;;\7 ok",
    "Please log in \194\157" .. "8;;SECRET_C1_OSC\194\156 ok",
    "Please log in \194\157" .. "8;;SECRET_C1_OSC_BEL\7 ok",
    "Please log in \194\144 PUBLIC \7 SECRET_C1_DCS\194\156 ok",
    "Please log in \194\159 SECRET_C1_APC\194\156 \194\158 SECRET_C1_PM\194\156 \194\152 SECRET_C1_SOS\194\156 ok",
    "Please log in \27[38:2::SECRET:1:2m ok\27[1;2 q\27[?25l\27[31;SECRET",
    "Please log in \194\155" .. "31m ok",
    "Please log in \27]8;;SECRET_UNTERMINATED",
    "Please log in \27P PUBLIC \7 SECRET_DCS_UNTERMINATED",
  }
  for index, screen in ipairs(cases) do
    local _, detail, sessions, trace = launch_diagnostic("claude", screen .. "\nSECRET_ROW2")
    for label, text in pairs({ detail = detail, sessions = sessions, trace = trace }) do
      T.ok(not text:find("SECRET", 1, true), "string-control case " .. index .. " leaked into " .. label .. ": " .. text)
    end
    T.ok(detail:find("Please log in", 1, true), "case " .. index .. " keeps the visible text: " .. detail)
    T.ok(not detail:find("[%z\1-\8\11-\31\127]"), "case " .. index .. " kept a control byte")
  end
end)

T.test("launch diagnostics stay valid UTF-8 within 80 characters and 240 bytes", function()
  local screens = {
    "Please log in A" .. string.rep("\128", 10000),
    "Please log in \255\254\192\175\237\160\128\240\128\128\128 tail",
    "Please log in \226\148 cut" .. string.rep("\226\148", 50),
    string.rep("界", 200),
    string.rep("😀", 200),
    "Please log in " .. string.rep("é", 5000) .. "\226",
  }
  for index, screen in ipairs(screens) do
    local _, detail = launch_diagnostic("claude", "Please log in " .. screen .. "\nSECRET_ROW2")
    T.ok(valid_utf8(detail), "case " .. index .. " emitted invalid UTF-8")
    T.ok(#detail <= 240, "case " .. index .. " exceeds 240 bytes: " .. #detail)
    local count = select(2, detail:gsub("[^\128-\191]", ""))
    T.ok(count <= 80, "case " .. index .. " exceeds 80 characters: " .. count)
    T.ok(not detail:find("SECRET", 1, true), "case " .. index .. " leaked row 2")
  end
end)

T.test("capture errors reach diagnostics through the same sanitizer", function()
  local message = "capture failed \27]8;;SECRET_ERR\7link\27]8;;\7 \27[31m" .. string.rep("x", 5000) .. "\128\nSECRET_ERR_ROW2"
  local reason, detail, sessions, trace = launch_diagnostic("retry_probe", message, true)
  T.eq(reason, "ready_unverified", "a pane whose capture always fails stays unverified")
  for label, text in pairs({ detail = detail, sessions = sessions, trace = trace }) do
    T.ok(not text:find("SECRET", 1, true), "capture error leaked into " .. label)
    T.ok(valid_utf8(text), "capture error produced invalid UTF-8 in " .. label)
  end
  T.ok(#detail < 600, "capture error detail must be bounded: " .. #detail)
  T.ok(detail:find("last capture error: capture failed", 1, true), "visible error text is kept: " .. detail)
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
