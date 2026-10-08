-- PR2 declared-spec regressions: current cores parse through remuda.cli.parse and older cores
-- retain the same Lua behavior through the explicit capability fallback.
local started
local function start_butler()
  if started then return end
  started = true
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "Butler root start")
  T.eval([=[remuda._butler_bus.agents["agent-test"] = { id = "agent-test", alias = "agent-test",
    session_name = "agent-test", children = {}, kind = "codex" }]=])
end

local function q(words)
  local out = {}
  for _, word in ipairs(words) do out[#out + 1] = string.format("%q", word) end
  return table.concat(out, ",")
end

local function run_command(parser, verb, args, caller, setup)
  start_butler()
  return T.eval([[
    local saved_cli = remuda.cli
    if not ]] .. tostring(parser) .. [[ then remuda.cli = nil end
    ]] .. (setup or "") .. [[
    local ok, value = pcall(remuda._butler_command_run, ]] .. string.format("%q", verb) .. [[, { ]] .. q(args) .. [[ }, ]] ..
      (caller or '{ kind = "outside" }') .. [[)
    remuda.cli = saved_cli
    local suffix = type(remuda._pr2_switch_counts) == "function" and ("|" .. remuda._pr2_switch_counts()) or ""
    remuda._pr2_switch_counts = nil
    if type(value) == "table" and value.failed then return tostring(ok) .. "|" .. value.code .. ":" .. value.text .. suffix end
    return tostring(ok) .. "|" .. tostring(value) .. suffix
  ]])
end

local function both_command(verb, args, caller, want, setup)
  for _, parser in ipairs({ true, false }) do
    T.eq(run_command(parser, verb, args, caller, setup), want,
      verb .. " " .. table.concat(args, " ") .. " parser=" .. tostring(parser))
  end
end

T.test("switches preserve usage, gate order and side-effect-free parse", function()
  local agent = '{ kind = "session", session = "agent-test" }'
  local capture = [[
    local real_fail = remuda.fail
    remuda.fail = function(message, code) return { failed = true, code = code, text = message } end
  ]]
  local malformed = run_command(true, "typed-lines", { "typed-lines", "maybe" }, agent, capture)
  T.ok(malformed:find("Usage: remuda butler typed%-lines on|off"), "invalid values retain switch usage")
  for _, parser in ipairs({ true, false }) do
    local result = run_command(parser, "typed-lines", { "typed-lines", "on" }, agent, [[
      remuda.fail = function(message, code) return { failed = true, code = code, text = message } end
    ]])
    T.ok(result:find("typed%-lines is operator%-only"), "authorization follows valid parsing")
    local no_config = run_command(parser, "typed-lines", { "typed-lines", "off" }, '{ kind = "outside" }', [[
      remuda.fail = function(message, code) return { failed = true, code = code, text = message } end
      remuda._butler_matrix_config = {}
    ]])
    T.ok(no_config:find("Matrix is not configured"), "configuration is checked after parsing")
    local dependency = run_command(parser, "shell-lines", { "shell-lines", "on" }, '{ kind = "outside" }', [[
      local reads, writes = 0, 0
      remuda._butler_matrix_config = { config_path = "/synthetic/config" }
      remuda.butler.matrix.read_config = function() reads = reads + 1; return { typed_lines = false, shell_lines = false } end
      remuda.fs.write_atomic = function(target) if target == "/synthetic/config" then writes = writes + 1 end; return true end
      remuda.fail = function(message, code) return { failed = true, code = code, text = message } end
      remuda._pr2_switch_counts = function() return reads .. ":" .. writes end
    ]])
    T.ok(dependency:find("typed%-lines must be on before shell%-lines"), "dependency check follows parse/config")
    T.ok(dependency:find("|1:0$"), "dependency gate reads config but does not write it")
    local already = run_command(parser, "typed-lines", { "typed-lines", "on" }, '{ kind = "outside" }', [[
      local reads = 0
      remuda._butler_matrix_config = { config_path = "/synthetic/config" }
      remuda.butler.matrix.read_config = function() reads = reads + 1; return { typed_lines = true, shell_lines = false } end
      remuda._pr2_switch_counts = function() return reads .. ":0" end
      remuda.fail = function(message, code) return { failed = true, code = code, text = message } end
    ]])
    T.eq(already, "true|typed-lines is already on.|1:0", "already-on remains after one config read")
  end
  for _, parser in ipairs({ true, false }) do
    local extra = run_command(parser, "typed-lines", { "typed-lines", "on", "extra" }, agent, [[
      local reads = 0
      remuda._butler_matrix_config = { config_path = "/synthetic/config" }
      remuda.butler.matrix.read_config = function() reads = reads + 1; return {} end
      remuda._pr2_switch_counts = function() return reads .. ":0" end
      remuda.fail = function(message, code) return { failed = true, code = code, text = message } end
    ]])
    T.ok(extra:find("Usage: remuda butler typed%-lines on|off"), "extra arguments are rejected before the operator gate")
    T.ok(extra:find("|0:0$"), "invalid parsing does not read or write switch state")
  end
  for _, verb in ipairs({ "typed-lines", "shell-lines", "status-commands" }) do
    for _, state in ipairs({ "on", "off" }) do
      local path = assert(os.getenv("REMUDA_LUA_SCRATCH")) .. "/pr2-" .. verb .. "-" .. state .. ".conf"
      local make_case = function(parser)
        return run_command(parser, verb, { verb, state }, '{ kind = "outside" }', [[
          local path, reads, writes = ]] .. string.format("%q", path) .. [[, 0, 0
          local file = assert(io.open(path, "wb")); file:write("synthetic config\n"); file:close()
          remuda._butler_matrix_config = { config_path = path }
          remuda.butler.matrix.read_config = function()
            reads = reads + 1
            return { typed_lines = ]] .. tostring(verb == "shell-lines") .. [[, shell_lines = ]] .. tostring(state == "off") .. [[,
              status_commands = ]] .. tostring(state == "off") .. [[ }
          end
          remuda.fs.write_atomic = function(target) if target == path then writes = writes + 1 end; return true end
          remuda.pending = function() return {
            prompt_line = function(_, spec) spec.callback("yes") end,
            resolve = function(_, code, stdout, stderr) return { code = code, stdout = stdout, stderr = stderr } end,
          } end
          remuda._pr2_switch_counts = function() os.remove(path); return reads .. ":" .. writes end
        ]])
      end
      local current, fallback = make_case(true), make_case(false)
      if state == "on" then
        T.ok(current:find("true|table:"), verb .. " on resolves through the prompt stub")
        T.ok(fallback:find("true|table:"), verb .. " on works without the parser")
        T.ok(current:find("|3:1$"), verb .. " on reads and writes only after confirmation")
        T.ok(fallback:find("|3:1$"), verb .. " fallback on has the same actions")
      else
        T.eq(current, "true|" .. verb .. " is now off." .. (verb == "typed-lines" and " shell-lines is also off." or "") .. "|2:1")
        T.eq(fallback, current, verb .. " off is identical without the parser")
      end
    end
  end
end)

local function compact_case(parser, args, has_session)
  start_butler()
  return T.eval([[
    local saved_cli, saved_has, saved_tick, saved_compact, saved_fail = remuda.cli,
      remuda._butler_compaction_has_session, remuda._butler_compaction_tick, remuda.butler.compact, remuda.fail
    if not ]] .. tostring(parser) .. [[ then remuda.cli = nil end
    remuda._butler_compaction_has_session = function(name)
      return ]] .. tostring(has_session) .. [[ and (name == "s1" or name:sub(1, 1) == "-")
    end
    remuda._butler_compaction_tick = function(name, dry) return "tick:" .. name .. ":" .. tostring(dry) end
    remuda.butler.compact = function(name, force) return "compact:" .. name .. ":" .. tostring(force) end
    remuda.fail = function(text, code) return { failed = true, code = code, text = text } end
    local ok, value = pcall(remuda._extension_commands.butler, { ]] .. q(args) .. [[ },
      {kind = "session", session = "agent-test"})
    remuda.cli, remuda._butler_compaction_has_session, remuda._butler_compaction_tick,
      remuda.butler.compact, remuda.fail = saved_cli, saved_has, saved_tick, saved_compact, saved_fail
    if type(value) == "table" and value.failed then return tostring(ok) .. "|" .. value.code .. ":" .. value.text end
    return tostring(ok) .. "|" .. tostring(value)
  ]])
end

T.test("compact flags and session precedence match on current and old cores", function()
  for _, parser in ipairs({ true, false }) do
    T.eq(compact_case(parser, { "compact", "s1" }, true), "true|compact:s1:false")
    T.eq(compact_case(parser, { "compact", "s1", "--dry-run" }, true), "true|tick:s1:true")
    T.eq(compact_case(parser, { "compact", "s1", "--force" }, true), "true|compact:s1:true")
    T.ok(compact_case(parser, { "compact", "s1", "--dry-run", "--force" }, true):find("remuda butler — coordination", 1, true),
      "mutually exclusive compact flags return global usage")
    T.eq(compact_case(parser, { "compact", "s1", "--bad" }, false), "true|1:unknown session: s1",
      "session lookup must precede flag validation")
    T.ok(compact_case(parser, { "compact", "s1", "--bad" }, true):find("remuda butler — coordination", 1, true),
      "unknown compact flags return global usage")
  end
end)

T.test("compact dash-prefixed session names keep legacy parsing on current and old cores", function()
  local sessions = { "-s1", "-h", "--force", "--help", "--" }
  local flags = {
    { flag = nil, want = function(name) return "true|compact:" .. name .. ":false" end },
    { flag = "--dry-run", want = function(name) return "true|tick:" .. name .. ":true" end },
    { flag = "--force", want = function(name) return "true|compact:" .. name .. ":true" end },
  }
  for _, name in ipairs(sessions) do
    for _, item in ipairs(flags) do
      local args = { "compact", name }
      if item.flag then args[#args + 1] = item.flag end
      local want = item.want(name)
      local current = compact_case(true, args, true)
      local old = compact_case(false, args, true)
      T.eq(current, want, "parser on: " .. table.concat(args, " "))
      T.eq(old, want, "parser off: " .. table.concat(args, " "))
      T.eq(current, old, "parser modes agree: " .. table.concat(args, " "))
    end
    for _, flag in ipairs({ "--dry-run", "--force" }) do
      local args = { "compact", name, flag }
      local want = "true|1:unknown session: " .. name
      T.eq(compact_case(true, args, false), want, "parser on missing session: " .. table.concat(args, " "))
      T.eq(compact_case(false, args, false), want, "parser off missing session: " .. table.concat(args, " "))
    end
  end
  for _, parser in ipairs({ true, false }) do
    T.eq(compact_case(parser, { "compact", "-missing", "--dry-run" }, false), "true|1:unknown session: -missing",
      "unknown dash-prefixed session retains precedence over flag handling")
  end
end)

local function inbox_case(parser, args, caller)
  start_butler()
  return T.eval([[
    local saved_cli = remuda.cli
    if not ]] .. tostring(parser) .. [[ then remuda.cli = nil end
    local mail = remuda._butler_mail
    local real_find = mail.find_message
    mail.find_message = function(id)
      if id == "01M49D6J4RVBW73XKFGQ6XS94J" or id == "01M49D6J4RVBW73XKFGQ6XS94K" then return { id = id } end
      return nil
    end
    remuda._pr2_mail_state = { reads = 0, deliveries = { ["01M49D6J4RVBW73XKFGQ6XS94J"] = true } }
    remuda._butler_inbox = function(name)
      remuda._pr2_mail_state.reads = remuda._pr2_mail_state.reads + 1
      return "inbox:" .. name
    end
    remuda._butler_inbox_message = function(me, id)
      if not remuda._pr2_mail_state.deliveries[id] then error("not delivered", 0) end
      remuda._pr2_mail_state.reads = remuda._pr2_mail_state.reads + 1
      return "message:" .. id
    end
    remuda.fail = function(text, code) return { failed = true, code = code, text = text } end
    local before = tostring(remuda._pr2_mail_state.reads) .. ":" .. tostring(remuda._pr2_mail_state.deliveries["01M49D6J4RVBW73XKFGQ6XS94J"])
    local ok, value = pcall(remuda._butler_command_run, "inbox", { ]] .. q(args) .. [[ }, ]] ..
      (caller or '{ kind = "outside" }') .. [[)
    local after = tostring(remuda._pr2_mail_state.reads) .. ":" .. tostring(remuda._pr2_mail_state.deliveries["01M49D6J4RVBW73XKFGQ6XS94J"])
    remuda.cli, mail.find_message = saved_cli, real_find
    if type(value) == "table" and value.failed then return tostring(ok) .. "|" .. value.code .. ":" .. value.text .. "|" .. before .. "|" .. after end
    return tostring(ok) .. "|" .. tostring(value) .. "|" .. before .. "|" .. after
  ]])
end

T.test("inbox parser failures do not read mail or change deliveries", function()
  start_butler()
  for _, bad in ipairs({ { "inbox", "--help" }, { "inbox", "alice", "extra" },
    { "inbox", "01M49D6J4RVBW73XKFGQ6XS94J", "extra" }, { "inbox", "x", "y" } }) do
    for _, parser in ipairs({ true, false }) do
      local result = inbox_case(parser, bad)
      local ok, value, before, after = result:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
      T.eq(before, after, "help/extra args leave reads and delivery state untouched")
      value = ok .. "|" .. value
      T.ok(value == "true|nil" or value:find("Usage: remuda butler inbox", 1, true),
        "malformed inbox calls decline or return literal help")
    end
  end
  for _, parser in ipairs({ true, false }) do
    local result = inbox_case(parser, { "inbox", "01M49D6J4RVBW73XKFGQ6XS94K" },
      '{ kind = "session", session = "agent-test" }')
    local ok, value, before, after = result:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    T.eq(before, after, "a nondelivered ID leaves read and delivery state untouched")
    T.ok(ok == "true" and value:find("not delivered", 1, true), "nondelivered ID keeps the Lua access check: " .. tostring(result))
  end
end)

T.test("inbox name and delivered-ID semantics are unchanged", function()
  local setup = [[
    local mail = remuda._butler_mail
    mail.find_message = function(id)
      if id == "01M49D6J4RVBW73XKFGQ6XS94J" then return { id = id } end
      return nil
    end
    remuda._butler_inbox = function(name) return "inbox:" .. name end
    remuda._butler_inbox_message = function(me, id) return "message:" .. id .. ":" .. me end
  ]]
  local caller = '{ kind = "session", session = "agent-test" }'
  -- #439: a member may read only its own inbox; the operator may read any named one.
  both_command("inbox", { "inbox", "alice" }, '{ kind = "outside" }', "true|inbox:alice", setup)
  both_command("inbox", { "inbox", "alice" }, caller, "true|1:agents may only read their own Butler inbox.\nNext: remuda butler inbox", setup)
  both_command("inbox", { "inbox", "--" }, '{ kind = "outside" }', "true|inbox:--", setup)
  both_command("inbox", { "inbox", "-alice" }, '{ kind = "outside" }', "true|inbox:-alice", setup)
  both_command("inbox", { "inbox", "01M49D6J4RVBW73XKFGQ6XS94J" }, caller,
    "true|message:01M49D6J4RVBW73XKFGQ6XS94J:agent-test", setup)
end)
