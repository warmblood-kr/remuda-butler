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
      if name == "conpty-visible" then return "\nClaude is still starting" end
      return ""
    end
    remuda._conpty_visible_result = nil
    remuda._butler_choose_async({ "visible_probe" }, {
      name = "conpty-visible", cwd = os.getenv("XDG_DATA_HOME"), timeout = 1,
      spec = function() return {} end, env = function() return {} end,
    }, function(session, agent, attempts)
      remuda._conpty_visible_result = { session = session, reason = attempts[1].reason }
    end)
  ]])
  T.wait_until(function()
    return T.eval("return tostring(remuda._conpty_visible_result ~= nil)") == "true"
  end, 5, "visible screen timeout")
  T.eq(T.eval("return remuda._conpty_visible_result.reason"), "timeout",
    "visible content after a blank first row must not be classified as blank")
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
    T.eq(T.eval(string.format("local d = remuda._butler_prompt_is_empty('claude', %q); return d", fixture)), "NON-EMPTY",
      label .. " raw dim suggestion must remain non-empty under #137")
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
end)
