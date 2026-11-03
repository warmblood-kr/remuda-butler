-- Exercise the actual callbacks in isolated environments, without launching an
-- OpenCode process or changing the user's running Butler instance.
local root = assert(os.getenv("REMUDA_LUA_REPO"))
local host = {
  cli = { parse = function() error("unexpected CLI parse") end },
  _butler_agent_builders = {}, _butler_agent_startup = {},
  _butler_telemetry_adapters = {},
}
local globals = setmetatable({ remuda = host }, { __index = _G })
local env = setmetatable({}, { __index = globals })
env._G = env
local function load(path)
  return assert(loadfile(root .. "/packages/" .. path .. ".lua", "t", env))()
end
load("butler/agents/opencode")
local startup = host._butler_agent_startup.opencode
local declaration = load("butler/init")
local registered
for _, entry in ipairs(declaration.contributes["butler.agent"]) do
  if entry.id == "opencode" then registered = entry end
end
assert(registered, "declared OpenCode registration")
host._butler_sessions_config = {
  registered_agent_kind = function() return registered end,
  call_callback = function(callback, screen) return pcall(callback, {}, screen) end,
}
load("butler/session_status/opencode")
local status = host._butler_session_status_detectors.opencode
local delivery = load("butler/prompt")
local current_screen
host._butler_notice_config = {
  bus = { agents = { probe = { id = "probe-id", session_name = "probe", kind = "opencode" } },
    pending_tasks = {}, messages = {}, objects = {}, mail_delivered = {},
    codex_update_relaunches = {}, codex_update_state = {} },
  resolve = function(n) return n end, mail_address = function() return {} end,
  mail_id = function() return "probe", {} end,
  mail = {
    mailbox = function() return {} end, is_unread = function() return true end,
    unread = function() return 1 end,
    find_message = function() return { from = { alias = "qa", id = "qa-id" } } end,
  },
  take_delivery_notice_result = function() end,
  notify_mail_delivery = function() end, deliver_message = function() end,
}
host._butler_chooser = { known_startup_modal = function() return false end }
host.ls = function() return {{ name = "probe", alive = true, attached = true, human_idle = math.huge }} end
host.session = function() return { is_busy = false } end
host.capture = function() return current_screen end
host.butler = { dialogs = { check = function() return true end } }
env._butler_session_trace = function() end
load("butler/notice")

local function check(screen, expected, label)
  local decision = startup.empty(screen)
  T.eq(decision, expected, label .. " empty")
  local ready = expected == "EMPTY"
  T.eq(startup.ready(screen), ready, label .. " startup ready")
  T.eq(registered.ready({}, screen), ready, label .. " registered ready")
  T.eq(delivery.ready("opencode", screen), ready, label .. " first-task ready")
  T.eq(status(screen), ready and "idle" or "other", label .. " status")
  current_screen = screen
  T.eq(host._butler_prompt_is_empty("opencode", screen), expected, label .. " shared empty")
  T.eq(host._butler_notify_policy("probe", 1000), ready, label .. " idle notice admission")
  T.eq(host._butler_approved_text_policy("probe", 1000), ready, label .. " approved input admission")
end

T.test("all legacy placeholders and literal Unicode wrappers remain supported", function()
  for _, placeholder in ipairs({
    "Ask anything, / for commands, @ for context...",
    "Ask anything, / for commands, @ for context…",
    "Ask anything…", "Ask anything...", "Ask anything",
  }) do
    for _, border in ipairs({ "", "│ ", "┃ ", "| " }) do
      for _, prompt in ipairs({ "", "❯ ", "› ", "> " }) do
        check("\n  " .. border .. prompt .. placeholder .. "  \n", "EMPTY", border .. prompt .. placeholder)
      end
    end
  end
end)

T.test("captured OpenCode quoted suggestions are empty", function()
  for _, suggestion in ipairs({
    "What is the tech stack of this project?", "Fix a TODO in the codebase", "Fix broken tests",
  }) do
    check('┃  Ask anything… "' .. suggestion .. '"\n', "EMPTY", suggestion)
    check('|  Ask anything... "' .. suggestion .. '"\n', "EMPTY", "mono " .. suggestion)
  end
end)

T.test("captured blank composer and synthetic edits preserve boundaries", function()
  local file = assert(io.open(root .. "/tests/fixtures/opencode-idle-blank.txt", "r"))
  local frame = file:read("*a"); file:close()
  check(frame, "EMPTY", "live blank composer")
  -- Sanitized context from the same capture: without cursor/region metadata,
  -- old bordered output plus intervening prose is indistinguishable from a
  -- multiline draft. Conservatively defer this ambiguous real-idle layout.
  check("┃ previous tool output\n┃ previous output continuation\n\n"
    .. "Completed the requested work.\n\nBuild · model · 1m 2s\n\n" .. frame,
    "NON-EMPTY", "ambiguous transcript/current-composer boundary defers")
  check(frame:gsub("┃\n", '┃ Ask anything… "Fix broken tests"\n', 1), "EMPTY", "suggestion in live frame")
  check(frame:gsub("┃\n", "┃ actual draft\n", 1), "NON-EMPTY", "draft in live frame")
  check(frame:gsub("┃\n", "┃ Ask anything…\n┃ actual draft\n", 1), "NON-EMPTY", "multiline in live frame")
end)

T.test("CRLF and NBSP indentation preserve exact placeholder matching", function()
  check('\r\n┃  Ask anything… "Fix broken tests"\r\n', "EMPTY", "CRLF")
  check('\194\160┃\194\160❯\194\160Ask anything…', "EMPTY", "NBSP")
end)

T.test("complete legacy box bottoms establish blank composer frames", function()
  for _, bottom in ipairs({ "╰───", "└───", "╚═══" }) do
    check("┃\n┃\n" .. bottom, "EMPTY", "legacy bottom " .. bottom)
  end
end)

T.test("drafts cannot borrow readiness from an earlier placeholder", function()
  for _, screen in ipairs({
    "┃ Ask anything…\n┃ actual draft",
    "┃ Ask anything…\n┃ ❯ actual draft",
    "┃ Ask anything…\n┃ › actual draft",
    "┃ Ask anything…\n┃ > actual draft",
    "┃ Ask anything…\n┃ actual\n┃ multiline draft",
    "┃ Ask anything…\nactual draft",
    "┃ actual draft\n\n┃  \n╹▀▀▀",
    "┃ Ask anything…\n┃ my · draft\n└",
    "┃ Ask anything…\n┃ my · draft\n╹▀▀▀",
    "┃ Ask anything…\n┃ My · draft\n╹▀▀▀",
    "┃ Build · draft\n╹▀▀▀",
    "┃ Ask anything…\n~ actual draft",
    "┃ Ask anything…\nctrl+p commands actual draft",
    "┃ Ask anything…\n~ arbitrary human draft long enough ~",
    "┃ Ask anything…\nactual draft\n┃ \n┃ Build · model\n╹▀▀▀\nctrl+p commands",
    "┃ actual draft\nactual continuation\n┃ \n╹▀▀▀",
  }) do
    check(screen, "NON-EMPTY", screen)
    local _, text = startup.empty(screen)
    T.ok(text:find("draft", 1, true), "retain draft text")
  end
end)

T.test("typed text and malformed suggestions remain nonempty", function()
  for _, text in ipairs({
    "draft", "Ask anything else", "Ask anything… actual draft",
    'Ask anything… "Fix broken tests" actual draft',
    'Ask anything… "Please destroy the workspace"',
    'Ask anything… "Fix broken tests', 'Ask anything… ""',
    "❯draft", "›draft", ">draft", "│draft", "┃draft", "|draft",
    "éAsk anything…", "界Ask anything…", "❮ Ask anything…",
    "Ask anything…\226", -- a partial UTF-8 prefix is still input
    "> ", "❯ ", "› ", "Run a command…", 'Run a command… "git status"',
  }) do
    check("┃ " .. text, "NON-EMPTY", text)
  end
end)

T.test("long input cannot hide its draft above the bottom scan window", function()
  check("┃ actual draft\n" .. string.rep("┃\n", 15) .. "┃ Ask anything…", "NON-EMPTY", "long composer")
  for _, length in ipairs({ 1, 2, 5, 15 }) do
    check("┃ Ask anything…\n" .. string.rep("actual draft\n", length)
      .. "┃ \n┃ Build · model\n╹▀▀▀\nctrl+p commands", "NON-EMPTY", "unbordered run " .. length)
  end
end)

T.test("partial Unicode glyphs cannot be stripped into placeholders", function()
  for _, glyph in ipairs({ "┃", "│", "❯", "›" }) do
    for length = 1, #glyph - 1 do
      check("┃ " .. glyph:sub(1, length) .. "Ask anything…", "NON-EMPTY", "partial " .. glyph .. length)
    end
  end
end)

T.test("typed prefixes and suffixes cannot extend known empty strings", function()
  local placeholder = 'Ask anything… "Fix broken tests"'
  for _, draft in ipairs({ "x", "é", "界", "|", "┃", "❯", "·", '"', "[Pasted Content 200 chars]" }) do
    check("┃ " .. draft .. placeholder, "NON-EMPTY", "typed prefix " .. draft)
    check("┃ " .. placeholder .. draft, "NON-EMPTY", "typed suffix " .. draft)
  end
end)

T.test("post-write Return requires the complete owned composer", function()
  current_screen = "┃ QA initial task"
  local allowed, reason = host._butler_approved_text_policy("probe", 1000, function(text)
    return text == "QA initial task"
  end)
  T.eq(allowed, true, "owned task may be submitted")
  T.eq(reason, "owned_composer")
  current_screen = "┃ QA initial task\n┃ human continuation"
  T.eq(host._butler_approved_text_policy("probe", 1000, function(text)
    return text == "QA initial task"
  end), false, "human continuation invalidates ownership")
  current_screen = "┃ QA initial task\n┃ Build · draft\n╹▀▀▀"
  T.eq(host._butler_approved_text_policy("probe", 1000, function(text)
    return text == "QA initial task"
  end), false, "unseparated status-shaped draft invalidates ownership")
  for _, glyph in ipairs({ ">", "❯", "›" }) do
    current_screen = "┃ " .. glyph .. " QA initial task"
    T.eq(host._butler_approved_text_policy("probe", 1000, function(text)
      return text == "QA initial task"
    end), false, "typed glyph must not be stripped from owned text " .. glyph)
  end
end)

T.test("capture failures block approved OpenCode writes", function()
  local capture = host.capture
  host.capture = function() error("QA capture unavailable") end
  local admitted = host._butler_approved_text_policy("probe", 1000)
  host.capture = capture
  T.eq(admitted, false, "capture failure is not renderer-unknown permission")
end)

T.test("parser failures cannot fall through to generic prompt recognition", function()
  local empty = startup.empty
  current_screen = "> Ask anything…"
  startup.empty = function() error("QA parser unavailable") end
  local notice = host._butler_notify_policy("probe", 1000)
  local approved = host._butler_approved_text_policy("probe", 1000)
  startup.empty = empty
  T.eq(notice, false, "parser error blocks notice")
  T.eq(approved, false, "parser error blocks approved input")
end)

T.test("styled cursor row cannot erase a multiline draft", function()
  current_screen = '┃ Ask anything…\n┃ actual draft'
  host.capture_styled = function()
    return { cursor = { row = 1 }, rows = {
      {{ text = "┃ Ask anything…", dim = false }},
      {{ text = "┃ actual draft", dim = false }},
    } }
  end
  local admitted = host._butler_notify_policy("probe", 1000)
  local decision = host._butler_composer_decision("opencode", "probe", current_screen)
  host.capture_styled = nil
  T.eq(admitted, false, "full screen draft blocks notice")
  T.eq(decision, "NON-EMPTY", "full draft survives styled cursor")
end)

T.test("history, banners, and authentication do not prove readiness", function()
  for _, screen in ipairs({
    "", "OpenCode", "Authentication required", "Not authenticated", "Please log in",
    "assistant: Ask anything…", "Ask anything…\n" .. string.rep("history\n", 15),
    "Ask anything…\nactual draft",
    "┃", "┃ \n┃ \n┃ ",
  }) do
    check(screen, "UNPARSEABLE", screen)
  end
end)

T.test("footer-only or malformed frames cannot establish emptiness", function()
  for _, screen in ipairs({
    "┃ \n~ footer only", "┃ \nctrl+p commands",
    "┃ \n└", "┃ \n╰", "┃ \n╚",
  }) do
    local decision = startup.empty(screen)
    T.ok(decision == "NON-EMPTY" or decision == "UNPARSEABLE", screen .. " must not be EMPTY")
    check(screen, decision, screen)
  end
end)

T.test("working status takes precedence over a visible empty composer", function()
  local screen = 'esc to interrupt\n┃ Ask anything… "Fix broken tests"'
  T.eq(startup.working(screen), true)
  T.eq(registered.working({}, screen), true)
  T.eq(status(screen), "working")
end)

T.test("first-task poll writes only after the composer is empty", function()
  local writes, poll
  host.schedule = function(spec) poll = spec.run; return 1 end
  host.cancel = function() end
  host.type_text = function() writes = writes + 1 end
  for _, row in ipairs({
    { '┃ Ask anything… "Fix broken tests"', 1 },
    { "┃ actual draft", 0 },
    { "┃ Ask anything…\n┃ later draft", 0 },
    { "┃ Ask anything…\n┃ > actual draft", 0 },
    { "unrecognized renderer", 0 },
  }) do
    current_screen, writes = row[1], 0
    delivery.schedule(host, "opencode", "probe", "probe", nil, "QA initial task", {
      empty = startup.empty, working = startup.working, detect_only = true,
    })
    poll()
    T.eq(writes, row[2], row[1] .. " first-task writes")
  end
end)

T.test("notice delivery never writes into drafts or unknown OpenCode screens", function()
  local writes = 0
  host.type_text = function() writes = writes + 1 end
  host.key = function() error("notice must not probe or clear a draft") end
  host._butler_notice_clock = function() return 1000 end
  local bus = host._butler_notice_config.bus
  for _, screen in ipairs({
    "┃ actual draft", "┃ Ask anything…\n┃ later draft", "┃ Ask anything…\nactual draft",
    "┃ >", "unrecognized renderer", "",
  }) do
    current_screen = screen
    bus.notice_screens, bus.notice_recoveries, bus.notice_fallbacks = {}, {}, {}
    bus.notices.probe = { count = 1, message_order = { "qa-message" },
      message_ids = { ["qa-message"] = "QA notice" }, text = "QA notice", kind = "opencode", delivery_attempts = 0 }
    host._butler_notice.deliver_notice("probe")
    T.eq(writes, 0, screen .. " notice writes")
  end
end)
