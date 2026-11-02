-- Hierarchical help: `remuda butler help` groups the verbs into headed sections
-- separated by blank lines and points at `remuda butler matrix --help`, which
-- lists the Matrix verbs in their own groups. Help exits 0; usage errors keep 2.
local exe = assert(os.getenv("REMUDA_BIN"))
local child = assert(os.getenv("REMUDA_LUA_CHILD_SERVER"))
local repo = assert(os.getenv("REMUDA_LUA_REPO"))
local started

local function start_butler()
  if started then return end
  started = true
  T.install_mod("butler", repo)
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "Butler root start")
end

local function butler(...)
  local argv = { exe, "-s", child, "butler", ... }
  local result = remuda.process.run { argv = argv, timeout = 20 }
  assert(not result.timed_out, "timed out: " .. table.concat(argv, " "))
  return result
end

-- The section heading lines of a help text, in order.
local function headings(text)
  local found = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%u[^:]*:$") then found[#found + 1] = line end
  end
  return table.concat(found, "|")
end

-- Each heading after the first starts a new block: the line before it is blank.
local function headed_blocks_separated(text)
  local previous
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%u[^:]*:$") and previous ~= nil and previous ~= "" then return false, line end
    previous = line
  end
  return true
end

T.test("remuda butler help, --help and -h print the same grouped sections", function()
  start_butler()
  local help = butler("help")
  T.eq(help.code, 0, "help exit")
  T.eq(help.stderr, "", "help stderr")
  for _, flag in ipairs({ "--help", "-h" }) do
    local other = butler(flag)
    T.eq(other.code, 0, flag .. " exit")
    T.eq(other.stdout, help.stdout, flag .. " must print the grouped help")
  end
  local text = help.stdout
  T.eq(headings(text), "Mail:|Sessions and teams:|Approvals:|Matrix:|Schedule:|Health and accounts:|Switches and input:|Notes:",
    "help sections: " .. text)
  local ok, line = headed_blocks_separated(text)
  T.expect(ok, "section " .. tostring(line) .. " is not preceded by a blank line: " .. text)
  T.expect(text:find("Mail:\n  remuda butler send <to>", 1, true), "mail verbs under Mail: " .. text)
  T.expect(text:find("Approvals:\n  remuda butler approve-text request SESSION - | on|off\n  remuda butler approvals\n  remuda butler approve <ID>\n  remuda butler deny <ID>\n", 1, true),
    "approval verbs under Approvals: " .. text)
  T.expect(text:find("remuda butler matrix --help", 1, true), "help must point at matrix --help: " .. text)
  T.expect(not text:find("redact EVENT_ID", 1, true), "help must not list every Matrix verb: " .. text)
end)

T.test("remuda butler matrix --help lists the Matrix verbs in groups", function()
  start_butler()
  local help = butler("matrix", "--help")
  T.eq(help.code, 0, "matrix --help exit: " .. help.stderr)
  T.eq(help.stderr, "", "matrix --help stderr")
  for _, argv in ipairs({ { "matrix", "-h" }, { "matrix", "help" }, { "matrix" } }) do
    local other = butler((table.unpack or unpack)(argv))
    T.eq(other.code, 0, table.concat(argv, " ") .. " exit")
    T.eq(other.stdout, help.stdout, table.concat(argv, " ") .. " must print the same Matrix help")
  end
  local text = help.stdout
  T.expect(text:find("^Usage: remuda butler matrix %[%-%-json%] %[%-%-room ROOM%] <verb>"), "matrix usage line: " .. text)
  T.eq(headings(text), "Read:|Threads and notifications:|Write:|Rooms and moderation (operator):|Setup (operator):",
    "matrix sections: " .. text)
  local ok, line = headed_blocks_separated(text)
  T.expect(ok, "section " .. tostring(line) .. " is not preceded by a blank line: " .. text)
  for _, row in ipairs({ "event|get EVENT_ID", "join ROOM (ID, #alias, or public name; operator)",
      "redact EVENT_ID [--reason TEXT]", "matrix setup [OPTIONS]", "Example: remuda butler matrix setup" }) do
    T.expect(text:find(row, 1, true), "matrix help omitted " .. row .. ": " .. text)
  end
end)

T.test("usage errors keep exit 2 and the grouped usage", function()
  start_butler()
  local unknown = butler("no-such-verb")
  T.eq(unknown.code, 2, "unknown verb exit")
  T.expect(unknown.stderr:find("Mail:\n", 1, true) and unknown.stderr:find("\n\nMatrix:\n", 1, true),
    "unknown verb prints the grouped usage: " .. unknown.stderr)
  local matrix_unknown = butler("matrix", "--bogus")
  T.eq(matrix_unknown.code, 2, "matrix --bogus exit")
end)

-- The top-level hint promises `remuda butler <verb> --help` for every listed verb.
T.test("every listed verb answers --help with its own help", function()
  start_butler()
  local seen, verbs = {}, {}
  for line in (butler("help").stdout .. "\n"):gmatch("([^\n]*)\n") do
    local verb = line:match("^  remuda butler ([%l][%w%-]*)")
    if verb and not seen[verb] then seen[verb] = true; verbs[#verbs + 1] = verb end
  end
  T.expect(#verbs >= 25, "parsed too few verbs from help: " .. table.concat(verbs, ","))
  local report, bad = {}, {}
  for _, verb in ipairs(verbs) do
    local result = butler(verb, "--help")
    report[#report + 1] = verb .. "=" .. result.code
    if result.code ~= 0 or not result.stdout:find("remuda butler " .. verb, 1, true)
      or result.stdout:find("coordination for managed agents", 1, true) then
      bad[#bad + 1] = verb .. " (exit " .. result.code .. ")"
    end
  end
  T.eq(table.concat(bad, ", "), "", "verbs whose --help is not their own help")
  print("checked --help: " .. table.concat(report, " "))
end)


T.test("contributed verbs join their declared group, else Other commands", function()
  start_butler()
  T.eval([[
    remuda._butler_contribute("butler.command", "hello", { verb = "hello", order = 85, group = "mail",
      usage = "  remuda butler hello <name>", run = function(args) return "hello" end })
    remuda._butler_contribute("butler.command", "extra-verb", { verb = "extra-verb", order = 200,
      usage = "  remuda butler extra-verb", run = function(args) return "extra" end })
    return "ok"
  ]])
  local text = butler("help").stdout
  T.expect(text:find("  remuda butler forward <message-id> <member> [note...]\n  remuda butler hello <name>\n\nSessions", 1, true),
    "a grouped contribution lands in its section by order: " .. text)
  T.expect(text:find("\n\nOther commands:\n  remuda butler extra-verb\n\nNotes:", 1, true),
    "an ungrouped contribution lands under Other commands: " .. text)
end)

T.test("an unknown help group is logged and the verb is listed under Other commands", function()
  start_butler()
  T.eval([[
    remuda._butler_logged = {}
    remuda._butler_real_log = remuda._butler_real_log or remuda.log
    remuda.log = function(level, text) remuda._butler_logged[#remuda._butler_logged + 1] = level .. ": " .. text end
    remuda._butler_contribute("butler.command", "typo-verb", { verb = "typo-verb", order = 210, group = "mial",
      usage = "  remuda butler typo-verb", run = function(args) return "typo" end })
    return "ok"
  ]])
  local text = butler("help")
  T.eq(text.code, 0, "help still succeeds")
  T.expect(text.stdout:find("\n\nOther commands:\n[^\n]*\n?[^\n]*remuda butler typo%-verb"),
    "unknown group falls back to Other commands: " .. text.stdout)
  local logged = T.eval("return table.concat(remuda._butler_logged, '\\n')")
  T.expect(logged:find("warn: butler: command 'typo-verb' names unknown help group 'mial'", 1, true),
    "unknown group is logged: " .. logged)
  T.eval("remuda.log = remuda._butler_real_log; return 'ok'")
end)

