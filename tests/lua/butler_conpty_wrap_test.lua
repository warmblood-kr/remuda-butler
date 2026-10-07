-- ConPTY may join Claude's full-width composer border and prompt glyph on one
-- captured row, while leaving the first captured row blank.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.test("Claude accepts a border and prompt joined by ConPTY", function()
  local fixture = "\n────❯ "
  T.eq(T.eval(string.format("return tostring(remuda._butler_agent_startup.claude.ready(%q))", fixture)),
    "true", "startup matcher should recognize the wrapped composer")
  local choice = "────────❯ Yes, continue\n────────"
  T.eq(T.eval(string.format("return tostring(remuda._butler_agent_startup.claude.ready(%q))", choice)),
    "false", "a joined modal choice row must not look like the composer")
  T.eq(T.eval(string.format("local decision = remuda._butler_prompt_is_empty('claude', %q); return decision", fixture)),
    "EMPTY", "empty-composer matcher should recognize the wrapped composer")

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

T.test("a blank first row does not make a visible screen blank", function()
  T.eval([[
    remuda._butler_agent_builders.visible_probe = function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_test_force_launch_probe["conpty-visible"] = true
    remuda.capture = function(name)
      if name == "conpty-visible" then return "   \nSECRET_SENTINEL" end
      return ""
    end
    remuda._conpty_visible_result = nil
    remuda._butler_choose_async({ "visible_probe" }, {
      name = "conpty-visible", cwd = os.getenv("XDG_DATA_HOME"), timeout = 1,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, attempts)
      remuda._conpty_visible_result = { session = session, reason = attempts[1].reason,
        detail = attempts[1].detail, attempt = attempts[1] }
    end)
  ]])
  T.wait_until(function()
    return T.eval("return tostring(remuda._conpty_visible_result ~= nil)") == "true"
  end, 5, "visible screen timeout")
  T.eq(T.eval("return remuda._conpty_visible_result.reason"), "timeout",
    "visible content after a blank first row must not be classified as blank")
  local detail = T.eval("return remuda._conpty_visible_result.detail")
  T.ok(detail:find("<empty first row>", 1, true), "timeout detail must identify a blank first row")
  T.ok(not detail:find("SECRET_SENTINEL", 1, true), "timeout detail must not scan row two")
  T.eval([[local attempt = remuda._conpty_visible_result.attempt
    remuda._butler_bus.launch_failures = { ["visible-failure"] = { attempts = { attempt } } }]])
  local sessions = T.eval("return remuda._butler_sessions()")
  T.ok(not sessions:find("SECRET_SENTINEL", 1, true), "sessions output must not leak row two")
  T.eval([[remuda._butler_session_trace_path = os.tmpname()
    local attempt = remuda._conpty_visible_result.attempt
    _butler_session_trace("launch_failed", "visible-failure: " .. attempt.kind .. ": " .. attempt.reason .. " (" .. attempt.detail .. ")")]])
  local trace = T.eval([[local f=assert(io.open(remuda._butler_session_trace_path,"rb")); local s=f:read("*a"); f:close(); return s]])
  T.ok(not trace:find("SECRET_SENTINEL", 1, true), "launch trace must not leak row two")
end)


T.test("Claude dim Try suggestions are empty while typed Try drafts stay protected", function()
  local repo = assert(os.getenv("REMUDA_LUA_REPO"))
  local fixtures = {
    { "claude-2.1.292-100x30.txt", "100x30" },
    { "claude-2.1.292-120x30.txt", "120x30" },
    { "claude-2.1.292-140x30.txt", "140x30" },
    { "claude-2.1.292-win/claude-2.1.292-100x30.txt", "variant 100x30" },
    { "claude-2.1.292-win/claude-2.1.292-120x30.txt", "variant 120x30" },
    { "claude-2.1.292-win/claude-2.1.292-140x30.txt", "variant 140x30" },
  }
  for _, item in ipairs(fixtures) do
    local label, path = item[2], item[1]
    local file = assert(io.open(repo .. "/tests/fixtures/" .. path, "rb"))
    local fixture = file:read("a")
    file:close()
    local cursor = assert(fixture:find("────────────────", 1, true), "fixture composer border")
    local row = 1
    for i = 1, cursor do if fixture:sub(i, i) == "\n" then row = row + 1 end end
    local prompt_row = fixture:match("([^\n]*❯[^\n]*)")
    T.ok(prompt_row and prompt_row:find('Try "', 1, true), label .. " fixture should contain Claude suggestion")
    T.eq(T.eval(string.format("local d = remuda._butler_prompt_is_empty('claude', %q); return d", fixture)), "UNPARSEABLE",
      label .. " raw ANSI frame must retain its main-branch classification")
    local suggestion_at = prompt_row:find('Try "', 1, true)
    local prefix, suggestion = prompt_row:sub(1, suggestion_at - 1), prompt_row:sub(suggestion_at)
    T.eval(string.format([[
      remuda.capture = function(name) if name == %q then return %q end return "" end
      remuda.capture_styled = function(name)
        if name ~= %q then return nil end
        local rows = {}
        for i = 1, %d do rows[i] = {} end
        rows[%d] = { { text = %q }, { text = %q, dim = true } }
        return { cursor = { row = %d }, rows = rows }
      end
      remuda._butler_bus.agents[%q] = { kind = "claude" }
    ]], "conpty-" .. label, fixture, "conpty-" .. label, row, row, prefix, suggestion, row, "conpty-" .. label))
    T.eq(T.eval(string.format("local d = remuda._butler_composer_decision('claude', %q, %q); return d", "conpty-" .. label, fixture)),
      "EMPTY", label .. " dim Try suggestion should be empty by prefix")
    T.eq(T.eval(string.format([[
      local original_ls = remuda.ls
      remuda.ls = function() return { { name = %q, alive = true, attached = false } } end
      local allowed = remuda._butler_notify_policy(%q)
      remuda.ls = original_ls
      return tostring(allowed)
    ]], "conpty-" .. label, "conpty-" .. label)), "true",
      label .. " notice policy should treat the dim Try hint as an empty composer")
  end

  local draft = "Try \"refactor my file\""
  T.eval(string.format([[
    remuda.capture_styled = function(name)
      return { cursor = { row = 1 }, rows = { { { text = "────❯ " .. %q } } } }
    end
  ]], draft))
  T.eq(T.eval(string.format("local d = remuda._butler_composer_decision('claude', 'typed-try', %q); return d", "❯ " .. draft .. "\n────")),
    "NON-EMPTY", "normal-style text beginning Try must remain a draft")
  T.eval([[remuda.capture_styled = function() return { cursor = { row = 1 }, rows = {
    { { text = "❯ " }, { text = "generic suggestion", dim = true } },
  } } end]])
  T.eq(T.eval("local d = remuda._butler_composer_decision('claude', 'generic-dim', '❯ generic suggestion'); return d"),
    "NON-EMPTY", "dim text outside Claude's Try suggestion must not override the raw draft")
end)

T.test("wrapped continuation rows keep notice policy from typing over attached drafts", function()
  local wrapped = "────❯ \n─user draft\n────"
  T.eq(T.eval(string.format("local d = remuda._butler_prompt_is_empty('claude', %q); return d", wrapped)),
    "NON-EMPTY", "a rule-prefixed continuation is draft text")

  local screen = "────❯ Try \"suggested text\"\ncontinuation user draft\n────"
  T.eval(string.format([[
    remuda._butler_bus.agents["attached-draft"] = { kind = "claude" }
    remuda.capture = function(name) if name == "attached-draft" then return %q end return "" end
    remuda.capture_styled = function(name)
      if name ~= "attached-draft" then return nil end
      return { cursor = { row = 1 }, rows = { {
        { text = "────❯ " }, { text = "Try \"suggested text\"", dim = true },
      } } }
    end
    remuda.ls = function() return { { name = "attached-draft", alive = true, attached = true, human_idle = 20 } } end
  ]], screen))
  T.eq(T.eval("return tostring(remuda._butler_notify_policy('attached-draft'))"), "false",
    "an empty styled cursor row must not hide continuation draft text")
end)

T.test("composer safety matrix defers drafts behind footer-like continuation rows", function()
  local continuations = {
    { name = "blank footer", tail = "\n────\n" },
    { name = "draft after rule", tail = "\n────\nuser draft\n────" },
    { name = "mode draft after rule", tail = "\n────\n─⏵⏵ user draft\n────" },
    { name = "status then draft", tail = "\n─⏵⏵ auto mode on\nuser draft\n────" },
    { name = "footer prefix then draft", tail = "\n────\n⚠ hidden draft\n────" },
  }
  local shapes = {
    { name = "empty cursor", prompt = "────❯ " },
    { name = "dim Try", prompt = '────❯ Try "suggested text"' },
    { name = "typed draft", prompt = "────❯ typed draft" },
    { name = "multiline draft", prompt = "────❯ \ncontinuation draft" },
    { name = "footer-like draft", prompt = "────❯ \n────\nuser draft" },
    { name = "new prompt after draft", prompt = "────❯ user draft\n❯ " },
    { name = "modal row", prompt = "────❯ Yes, continue" },
    { name = "wrapped border 100", prompt = "─" .. string.rep("─", 99) .. "❯ " },
    { name = "wrapped border 120", prompt = "─" .. string.rep("─", 119) .. "❯ " },
    { name = "wrapped border 140", prompt = "─" .. string.rep("─", 139) .. "❯ " },
  }
  for si, shape in ipairs(shapes) do
    for ci, continuation in ipairs(continuations) do
      local name = "matrix-" .. si .. "-" .. ci
      local screen = shape.prompt .. continuation.tail
      T.eval(string.format([[
        remuda._butler_bus.agents[%q] = { kind = "claude" }
        remuda.capture = function(session) if session == %q then return %q end return "" end
        remuda.capture_styled = nil
        remuda.ls = function() return {{ name=%q, alive=true, attached=true, human_idle=20 }} end
      ]], name, name, screen, name))
      local decision = T.eval(string.format("local d=remuda._butler_prompt_is_empty('claude',%q); return d", screen))
      local allowed = T.eval(string.format("return tostring(remuda._butler_notify_policy(%q))", name))
      if (shape.name == "empty cursor" or shape.name:match("^wrapped border"))
          and continuation.name == "blank footer" then
        T.eq(decision, "EMPTY", shape.name .. " / " .. continuation.name .. " should remain ready")
      else
        T.ok(decision ~= "EMPTY", shape.name .. " / " .. continuation.name .. " hid a draft")
        T.eq(allowed, "false", shape.name .. " / " .. continuation.name .. " notice must defer")
      end
    end
  end

  local ghost_words = {
    { text = "❯ ", dim = false }, { text = "Try", dim = true }, { text = " ", dim = false },
    { text = '"fix', dim = true }, { text = " ", dim = false }, { text = "typecheck", dim = true },
    { text = " ", dim = false }, { text = 'errors"', dim = true },
  }
  T.eval([[remuda._matrix_ghost_words = {}
    remuda._butler_bus.agents["matrix-ghost-words"] = { kind = "claude" }
    remuda.capture = function() error("styled composer path should not need plain capture") end
    remuda.capture_styled = function() return { cursor={row=2}, rows={
      {{text="history",dim=false}}, remuda._matrix_ghost_words,
    } } end
    remuda.ls = function() return {{name="matrix-ghost-words",alive=true,attached=true,human_idle=20}} end
  ]])
  for _, span in ipairs(ghost_words) do
    T.eval(string.format("table.insert(remuda._matrix_ghost_words, { text=%q, dim=%s })", span.text, tostring(span.dim)))
  end
  T.eq(T.eval([[return tostring(remuda._butler_notify_policy("matrix-ghost-words"))]]), "true",
    "a dim Try ghost split across word spans must remain ready")

  T.eval([[remuda._matrix_ghost_single = {{text="❯ ",dim=false},{text='Try "fix typecheck errors"',dim=true}}
    remuda._butler_bus.agents["matrix-ghost-single"] = { kind = "claude" }
    remuda.capture_styled = function() return { cursor={row=2}, rows={
      {{text="history",dim=false}}, remuda._matrix_ghost_single,
    } } end
    remuda.ls = function() return {{name="matrix-ghost-single",alive=true,attached=true,human_idle=12}} end
  ]])
  T.eq(T.eval([[return tostring(remuda._butler_notify_policy("matrix-ghost-single"))]]), "true",
    "a single-run dim Try ghost must remain ready")
  T.eval([[remuda._matrix_typed = {{text="❯ co",dim=false}}
    remuda._butler_bus.agents["matrix-typed"] = { kind = "claude" }
    remuda.capture_styled = function() return { cursor={row=2}, rows={
      {{text="history",dim=false}}, remuda._matrix_typed,
    } } end
    remuda.ls = function() return {{name="matrix-typed",alive=true,attached=true,human_idle=12}} end
  ]])
  T.eq(T.eval([[return tostring(remuda._butler_notify_policy("matrix-typed"))]]), "false",
    "plain typed text stays protected when plain capture is unavailable")

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

T.test("known Claude footer rows must match whole lines", function()
  local probes = {
    { "╰user draft", false },
    { "└user draft", false },
    { "? for shortcuts user draft", false },
  }
  for _, probe in ipairs(probes) do
    local screen = "❯ \n" .. probe[1] .. "\n────"
    T.eq(T.eval(string.format("local decision = remuda._butler_prompt_is_empty('claude', %q); return decision", screen)),
      "NON-EMPTY", "footer-looking draft must not be stripped: " .. probe[1])
  end
  local ghost = 'Try "refactor <filepath>"'
  for _, probe in ipairs(probes) do
    local screen = "❯ " .. ghost .. "\n" .. probe[1] .. "\n────"
    T.eval(string.format([[remuda.capture_styled = function() return { cursor={row=1}, rows={
      {{text="❯ ",dim=false},{text=%q,dim=true}} } } end]], ghost))
    T.eq(T.eval(string.format("local decision = remuda._butler_composer_decision('claude', 'conpty-wrapped', %q); return decision", screen)),
      "NON-EMPTY", "dim Try plus footer-looking draft must defer: " .. probe[1])
  end
  T.eval("remuda.capture_styled = nil")
end)

T.test("every row in the current Claude composer is protected", function()
  local screen = "────❯ \nuser draft\n❯ \n────"
  T.eq(T.eval(string.format("local decision = remuda._butler_prompt_is_empty('claude', %q); return decision", screen)),
    "NON-EMPTY", "a later blank prompt cannot hide a draft in the current composer")
end)

T.test("SEC round 3 unsafe prompt probes stay deferred", function()
  -- The 66 cases below are the unsafe cases recorded by the SEC round 3 audit.
  -- Their dimensions and row shapes are kept inline so this test has no audit-file dependency.
  local widths = { 0, 1, 4, 100, 120, 140 }
  local ghost = 'Try "refactor <filepath>"'
  local tails = {
    { "corner_round", "╰user draft" },
    { "corner_square", "└user draft" },
    { "shortcuts_prefix", "? for shortcuts user draft" },
    { "empty_prompt", "user draft\n❯ " },
    { "empty_ascii_prompt", "user draft\n> " },
    { "empty_small_prompt", "user draft\n› " },
    { "empty_wrapped_prompt", "user draft\n─❯ " },
    { "empty_pipe_prompt", "user draft\n│ ❯ " },
  }
  local total = 0
  for _, width in ipairs(widths) do
    local prompt = string.rep("─", width) .. "❯ "
    for _, tail in ipairs(tails) do
      local screen = prompt .. "\n" .. tail[2] .. "\n────"
      T.eq(T.eval(string.format("local decision = remuda._butler_prompt_is_empty('claude', %q); return decision", screen)),
        "NON-EMPTY", string.format("SEC3 %d/empty_%s", width, tail[1]))
      total = total + 1
      if tail[1] == "corner_round" or tail[1] == "corner_square" or tail[1] == "shortcuts_prefix" then
        local ghost_screen = prompt .. ghost .. "\n" .. tail[2] .. "\n────"
        T.eval(string.format([[remuda.capture_styled = function() return { cursor={row=1}, rows={
          {{text=%q,dim=false},{text=%q,dim=true}} } } end]], prompt, ghost))
        local decision = T.eval(string.format("local decision = remuda._butler_composer_decision('claude', 'conpty-wrapped', %q); return decision", ghost_screen))
        T.ok(decision ~= "EMPTY", string.format("SEC3 %d/ghost_%s must defer", width, tail[1]))
        total = total + 1
      end
    end
  end
  T.eval("remuda.capture_styled = nil")
  T.eq(tostring(total), "66", "all SEC round 3 unsafe probes are permanent cases")
end)

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
