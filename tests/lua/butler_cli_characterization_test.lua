-- Characterization goldens for the hand-parsed CLI families (arg-parser migration PR0).
-- Each case runs the real `remuda butler ...` front door against stubbed actions and records
-- exit status, stdout, stderr and every stub call. Current behaviour is the baseline, defects
-- included; a deliberate change must update tests/golden_cli/ in the same PR.
--   CLI_GOLDEN_UPDATE=1 tests/lua_tests.sh tests/lua/butler_cli_characterization_test.lua
local exe = assert(os.getenv("REMUDA_BIN"))
local child = assert(os.getenv("REMUDA_LUA_CHILD_SERVER"))
local repo = assert(os.getenv("REMUDA_LUA_REPO"))
local scratch = assert(os.getenv("REMUDA_LUA_SCRATCH"))
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
  T.eval([[remuda._butler_bus.agents["agent-test"] = { id = "agent-test", alias = "agent-test",
    session_name = "agent-test", children = {}, kind = "codex" }]])
  -- One shared action log: every stub appends "name(arg|arg)".
  T.eval([[
    remuda._pr0_log = {}
    function remuda._pr0_note(name, ...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
      remuda._pr0_log[#remuda._pr0_log + 1] = name .. "(" .. table.concat(parts, "|") .. ")"
    end
    return "ok"
  ]])
end

local usage -- the global usage text, substituted so a new verb does not rewrite every golden
local function normalize(text)
  text = (text or ""):gsub("\n$", "")
  if usage and usage ~= "" then
    local at, to = text:find(usage, 1, true)
    if at then text = text:sub(1, at - 1) .. "<GLOBAL-USAGE>" .. text:sub(to + 1) end
  end
  text = text:gsub("%f[%w][%d%u]+%f[%W]", function(word) return #word == 26 and "<ULID>" or word end)
  text = text:gsub("(%.lua\"%]):%d+:", "%1:<LINE>:")
  return (text:gsub("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ", "<TS>"))
end

-- A case is an argv array, or { argv = {...}, as = "agent", pre = lua, post = lua }.
-- `as = "agent"` calls the Butler front door in-process with a daemon session caller.
local function run_case(case, trace)
  local argv = case.argv or case
  T.eval("remuda._pr0_log = {}")
  if case.pre then T.eval(case.pre) end
  local code, out, err
  if case.as then
    local words = {}
    for _, word in ipairs(argv) do words[#words + 1] = string.format("%q", word) end
    local result = T.eval([[
      local real_fail = remuda.fail
      remuda.fail = function(text, code) return { failed = true, code = code, text = text } end
      local ok, value = pcall(remuda._extension_commands.butler, { ]] .. table.concat(words, ",") .. [[ },
        { kind = "session", session = "agent-test" })
      remuda.fail = real_fail
      if not ok then return "1\0\0" .. tostring(value) end
      if type(value) == "table" and value.failed then return tostring(value.code) .. "\0\0" .. tostring(value.text) end
      if type(value) == "table" then return "0\0<deferred reply>\0" end
      return "0\0" .. tostring(value) .. "\0"
    ]])
    code, out, err = result:match("^(%d+)%z(.-)%z(.*)$")
  else
    local full = { exe, "-s", child, "butler" }
    for _, word in ipairs(argv) do full[#full + 1] = word end
    local result = remuda.process.run { argv = full, timeout = 20 }
    assert(not result.timed_out, "timed out: " .. table.concat(argv, " "))
    code, out, err = tostring(result.code), result.stdout, result.stderr
  end
  local log = T.eval('return table.concat(remuda._pr0_log, "\\n")')
  if trace then log = log .. (log == "" and "" or "\n") .. "state: " .. T.eval(trace):gsub("\n", "\\n") end
  if case.post then T.eval(case.post) end
  local words = {}
  for _, word in ipairs(argv) do words[#words + 1] = string.format("%q", word) end
  return table.concat({
    "### " .. (case.as and "[agent] " or "") .. "remuda butler " .. table.concat(words, " "),
    "exit: " .. code,
    "stdout:", normalize(out),
    "stderr:", normalize(err),
    "actions:", log == "" and "(none)" or normalize(log),
    "",
  }, "\n")
end

local function check_golden(family)
  start_butler()
  if not usage then
    local helped = remuda.process.run({ argv = { exe, "-s", child, "butler", "help" }, timeout = 20 })
    usage = (helped.stdout or ""):gsub("%s+$", "")
    assert(#usage > 200, "cannot read the global usage: " .. tostring(helped.stderr))
  end
  if family.setup then T.eval(family.setup) end
  local blocks = {}
  for _, case in ipairs(family.cases) do
    if family.reset then T.eval(family.reset) end
    blocks[#blocks + 1] = run_case(case, family.trace)
  end
  local actual = table.concat(blocks, "\n")
  local path = repo .. "/tests/golden_cli/" .. family.name .. ".txt"
  if os.getenv("CLI_GOLDEN_UPDATE") == "1" then
    local out = assert(io.open(path, "wb")); out:write(actual); out:close()
    return
  end
  local file = assert(io.open(path, "rb"), "missing golden " .. path)
  local want = file:read("*a"); file:close()
  if want ~= actual then
    local saved = scratch .. "/" .. family.name .. ".actual"
    local got = assert(io.open(saved, "wb")); got:write(actual); got:close()
    error(family.name .. " golden differs; actual saved to " .. saved .. "\n--- actual\n" .. actual, 0)
  end
end

local function families(list)
  for _, family in ipairs(list) do
    T.test(family.name .. " CLI goldens", function() check_golden(family) end)
  end
end

-- bare, long and short help, and the bare word `help`, then the family's own shapes.
local function forms(verb, ...)
  local cases = { { verb }, { verb, "--help" }, { verb, "-h" }, { verb, "help" } }
  for _, extra in ipairs({ ... }) do cases[#cases + 1] = extra end
  return cases
end
local function agent(...) return { argv = { ... }, as = "agent" } end

families {
  { name = "doctor",
    setup = [[
      local d = remuda._butler_doctor
      d.probe = function() remuda._pr0_note("doctor.probe"); return {} end
      d.render = function() remuda._pr0_note("doctor.render"); return { "doctor-stub" } end
      d.permission_lines = function() return {} end
    ]],
    cases = forms("doctor", { "doctor", "extra" }, { "doctor", "--" }, { "doctor", "--json" },
      { "doctor", "--help", "extra" }, { "doctor", "extra", "--help" }, { "doctor", "--=" }) },
  { name = "sessions",
    setup = [[remuda._butler_sessions = function() remuda._pr0_note("sessions.lookup"); return "sessions-stub" end]],
    cases = forms("sessions", { "sessions", "extra" }, { "sessions", "--all" }, { "sessions", "--", "x" },
      { "sessions", "--help", "extra" }) },
  { name = "status",
    setup = [[
      remuda._pr0_state = { "up", 0 }
      remuda._butler_status = function() remuda._pr0_note("status.lookup"); return remuda._pr0_state[1], remuda._pr0_state[2] end
    ]],
    cases = forms("status", { "status", "extra" }, { "status", "--json" }, { "status", "--", "x" },
      { argv = { "status" }, pre = [[remuda._pr0_state = { "launching", 75 }]] },
      { argv = { "status" }, pre = [[remuda._pr0_state = { "failed", 1 }]] },
      { argv = { "status", "extra" }, pre = [[remuda._pr0_state = { "failed", 1 }]] }) },
  { name = "agents",
    cases = forms("agents", { "agents", "--all" }, { "agents", "--all", "--all" }, { "agents", "--all=1" },
      { "agents", "extra" }, { "agents", "--bogus" }, { "agents", "--", "--all" }, { "agents", "--all", "extra" },
      { "agents", "extra", "--all" }, { "agents", "--help", "--all" }, { "agents", "-a" }) },
  { name = "quota",
    setup = [[
      remuda._butler_quota.collect = function(callback) remuda._pr0_note("quota.collect"); callback(nil, "stubbed") end
      remuda.butler.matrix.send = function(...) remuda._pr0_note("matrix.send", ...); error("no Matrix post in tests", 0) end
    ]],
    cases = forms("quota", { "quota", "--report" }, { "quota", "--report", "--report" }, { "quota", "--report", "extra" },
      { "quota", "extra", "--report" }, { "quota", "--report=1" }, { "quota", "--bogus" }, { "quota", "extra" },
      { "quota", "--" }, { "quota", "--", "--report" }, { "quota", "--help", "--report" }, { "quota", "--report", "--help" },
      { "quota", "-r" }, { "quota", "-1" },
      agent("quota"), agent("quota", "--report"), agent("quota", "--help"), agent("quota", "--report", "extra"),
      { argv = { "quota" }, pre = [[remuda._pr0_q = remuda._butler_quota; remuda._butler_quota = nil]], post = [[remuda._butler_quota = remuda._pr0_q]] },
      { argv = { "quota", "--help" }, pre = [[remuda._pr0_q = remuda._butler_quota; remuda._butler_quota = nil]], post = [[remuda._butler_quota = remuda._pr0_q]] },
      { argv = { "quota", "--bogus" }, pre = [[remuda._pr0_q = remuda._butler_quota; remuda._butler_quota = nil]], post = [[remuda._butler_quota = remuda._pr0_q]] }) },
  { name = "close",
    setup = [[
      remuda._butler_bus.agents.worker = { id = "01SYNTHETICWORKER000000000", parent = "butler", session_name = "worker" }
      remuda._butler_bus.agents.other = { id = "01SYNTHETICOTHER00000000000", parent = "worker", session_name = "other" }
      remuda.close = function(...) remuda._pr0_note("close", ...); return true end
      remuda.butler.is_idle = function() return false, "busy" end -- deterministic: do not depend on the real is_idle for a fake session
    ]],
    cases = forms("close", { "close", "worker" }, { "close", "worker", "--force" }, { "close", "--force", "worker" },
      { "close", "--force" }, { "close", "--force", "--force", "worker" }, { "close", "worker", "--force", "--force" },
      { "close", "worker", "extra" }, { "close", "worker", "other" }, { "close", "--force=1", "worker" },
      { "close", "-f", "worker" }, { "close", "--bogus" }, { "close", "--bogus", "worker" },
      { "close", "worker", "--bogus" }, { "close", "--", "worker" }, { "close", "--force", "--", "worker" },
      { "close", "worker", "--" }, { "close", "-worker" }, { "close", "nosuch" }, { "close", "nosuch", "--force" },
      { "close", "butler", "--force" }, { "close", "other", "--force" },
      { "close", "--help", "worker" }, { "close", "worker", "--help" }, { "close", "worker", "-h" },
      { "close", "--force", "--help" }, { "close", "--help", "--force" }) },
  { name = "compact",
    setup = [[
      remuda._butler_compaction_has_session = function(name) remuda._pr0_note("compact.has_session", name); return name == "s1" end
      remuda._butler_compaction_tick = function(...) if select("#", ...) > 0 then remuda._pr0_note("compact.tick", ...) end; return "tick-stub" end
      remuda.butler.compact = function(...) remuda._pr0_note("compact", ...); return "compact-stub" end
    ]],
    cases = forms("compact", { "compact", "s1" }, { "compact", "s1", "--dry-run" }, { "compact", "s1", "--force" },
      { "compact", "s1", "--dry-run", "--force" }, { "compact", "s1", "--force", "--dry-run" },
      { "compact", "--dry-run", "s1" }, { "compact", "--force", "s1" }, { "compact", "s1", "--dry-run", "--dry-run" },
      { "compact", "s1", "--force", "--force" }, { "compact", "s1", "--bogus" }, { "compact", "s1", "extra" },
      { "compact", "s1", "--dry-run=1" }, { "compact", "s1", "--" }, { "compact", "--", "s1" },
      { "compact", "s1", "-n" }, { "compact", "s1", "-1" }, { "compact", "" },
      { "compact", "nosuch" }, { "compact", "nosuch", "--dry-run" }, { "compact", "nosuch", "--bogus" },
      { "compact", "nosuch", "--dry-run", "--force" }, { "compact", "--help", "s1" }, { "compact", "s1", "--help" },
      { "compact", "s1", "-h" }, { "compact", "--dry-run" }) },
  { name = "inbox",
    setup = [[
      remuda._pr0_inbox = { read = 0, deliveries = 0 }
      local mail = remuda._butler_mail
      local real_find = mail.find_message
      mail.find_message = function(id)
        if id == "01M49D6J4RVBW73XKFGQ6XS94J" then return { id = id } end
        if id == "01M49D6J4RVBW73XKFGQ6XS94K" then return { id = id } end
        return nil
      end
      remuda._butler_inbox_message = function(me, id)
        remuda._pr0_inbox.read = remuda._pr0_inbox.read + 1
        if id == "01M49D6J4RVBW73XKFGQ6XS94K" then
          error("message " .. id .. " was not delivered to you", 0)
        end
        return "message " .. id
      end
      remuda._butler_inbox = function(name)
        remuda._pr0_inbox.read = remuda._pr0_inbox.read + 1
        return "inbox for " .. name
      end
      remuda._pr0_inbox.restore = function() mail.find_message = real_find end
    ]],
    trace = [[return "read=" .. remuda._pr0_inbox.read .. ",deliveries=" .. remuda._pr0_inbox.deliveries]],
    cases = {
      { "inbox" }, { "inbox", "--help" }, { "inbox", "-h" }, { "inbox", "help" },
      { "inbox", "01M49D6J4RVBW73XKFGQ6XS94J" },
      agent("inbox", "01M49D6J4RVBW73XKFGQ6XS94J"),
      agent("inbox", "01M49D6J4RVBW73XKFGQ6XS94K"),
      { "inbox", "01M49D6J4RVBW73XKFGQ6XS94L" },
      { "inbox", "alice" }, { "inbox", "01M49D6J4RVBW73XKFGQ6XS94J", "extra" },
      { "inbox", "--" }, { "inbox", "-alice" }, { "inbox", "alice", "extra" },
      { "inbox", "--help", "extra" }, { "inbox", "01M49D6J4RVBW73XKFGQ6XS94J", "--help" },
    } },

  -- typed-lines, shell-lines and status-commands share one switch parser. The terminal prompt
  -- is stubbed so both valid on and off forms are captured without touching a real terminal.
  { name = "switches",
    setup = [[
      remuda._pr0_conf = os.getenv("REMUDA_LUA_SCRATCH") .. "/pr0-matrix.conf"
      remuda._butler_matrix_config = { config_path = remuda._pr0_conf }
      remuda._pr0_saved_pending = remuda.pending
      remuda.pending = function()
        return {
          prompt_line = function(_, spec) spec.callback("yes") end,
          resolve = function(_, code, stdout, stderr)
            return { code = code, stdout = stdout, stderr = stderr }
          end,
        }
      end
    ]],
    reset = [[
      local file = assert(io.open(remuda._pr0_conf, "wb"))
      file:write("https://matrix.invalid\n!room:example.org\n@bot:example.org\n@alice:example.org\nfalse\n30000\nuntrusted_per_room_hour=12\ntyped_lines=false\nshell_lines=false\napprove_text=false\n")
      file:close()
    ]],
    trace = [[local file = assert(io.open(remuda._pr0_conf, "rb")); local text = file:read("*a"); file:close(); return text]],
    cases = (function()
      local cases = {}
      for _, verb in ipairs({ "typed-lines", "shell-lines", "status-commands" }) do
        for _, rest in ipairs({
          {}, { "--help" }, { "-h" }, { "help" }, { "on", "extra" }, { "off", "extra" }, { "extra", "on" },
          { "maybe" }, { "ON" }, { "on=1" }, { "--on" }, { "--", "off" }, { "off", "--" }, { "-1" },
          { "off" }, { "off", "off" }, { "on", "off" }, { "--help", "off" }, { "off", "--help" },
        }) do
          local argv = { verb }
          for _, word in ipairs(rest) do argv[#argv + 1] = word end
          cases[#cases + 1] = argv
        end
      end
      for _, verb in ipairs({ "typed-lines", "shell-lines", "status-commands" }) do
        cases[#cases + 1] = { argv = { verb, "on" }, pre = [[
          local file = assert(io.open(remuda._pr0_conf, "wb"))
          file:write("https://matrix.invalid\n!room:example.org\n@bot:example.org\n@alice:example.org\nfalse\n30000\nuntrusted_per_room_hour=12\ntyped_lines=false\nshell_lines=true\nstatus_commands=false\napprove_text=false\n")
          file:close()
        ]] }
        cases[#cases + 1] = { argv = { verb, "off" } }
      end
      -- shell-lines on is refused before any prompt while typed-lines is off.
      cases[#cases + 1] = { "shell-lines", "on" }
      cases[#cases + 1] = agent("typed-lines", "on")
      cases[#cases + 1] = agent("typed-lines", "off")
      cases[#cases + 1] = agent("shell-lines", "off")
      cases[#cases + 1] = agent("status-commands", "off")
      cases[#cases + 1] = agent("typed-lines", "bogus")
      cases[#cases + 1] = agent("typed-lines", "--help")
      cases[#cases + 1] = { argv = { "typed-lines", "off" }, pre = [[remuda._butler_matrix_config = { config_path = "" }]],
        post = [[remuda._butler_matrix_config = { config_path = remuda._pr0_conf }]] }
      cases[#cases + 1] = { argv = { "status-commands", "off" }, post = [[remuda.pending = remuda._pr0_saved_pending]] }
      return cases
    end)() },
  { name = "schedule",
    setup = [[
      remuda._pr0_sched = os.getenv("REMUDA_LUA_SCRATCH") .. "/pr0-schedules.json"
      remuda._pr0_reset = function() os.remove(remuda._pr0_sched) end
      remuda._butler_schedule_env = {
        path = remuda._pr0_sched,
        trace = function(event, detail) remuda._pr0_note("schedule.trace", event, detail) end,
        resolve = function(target) if target ~= "s1" and target ~= "butler" then error("unknown member: " .. target, 0) end return target end,
      }
    ]],
    reset = [[remuda._pr0_reset()]],
    trace = [[local file = io.open(remuda._pr0_sched, "rb"); if not file then return "(no file)" end; local text = file:read("*a"); file:close(); return text]],
    cases = (function()
      local cases = forms("schedule", { "schedule", "list" }, { "schedule", "list", "extra" }, { "schedule", "list", "--help" },
        { "schedule", "--help", "list" }, { "schedule", "rm" }, { "schedule", "rm", "nope" }, { "schedule", "rm", "nope", "extra" },
        { "schedule", "rm", "--help" }, { "schedule", "rm", "--", "nope" }, { "schedule", "add" }, { "schedule", "add", "--help" },
        { "schedule", "add", "-h" }, { "schedule", "add", "job" }, { "schedule", "add", "job", "0 9 * * *" },
        { "schedule", "add", "job", "bad cron", "text" }, { "schedule", "add", "job", "0 9 * * *", "text" },
        { "schedule", "add", "job", "0 9 * * *", "text", "--to", "s1" }, { "schedule", "add", "job", "0 9 * * *", "text", "--to" },
        { "schedule", "add", "job", "0 9 * * *", "text", "--to", "nosuch" },
        { "schedule", "add", "job", "0 9 * * *", "text", "--to", "s1", "--to", "s1" },
        { "schedule", "add", "job", "0 9 * * *", "--to", "s1", "text" },
        { "schedule", "add", "job", "--to", "s1", "0 9 * * *", "text" },
        { "schedule", "add", "job", "0 9 * * *", "text", "--to=s1" },
        { "schedule", "add", "job", "0 9 * * *", "text", "more words" },
        { "schedule", "add", "job", "0 9 * * *", "-text" }, { "schedule", "add", "job", "0 9 * * *", "--", "-text" },
        { "schedule", "add", "job", "0 9 * * *", "--help" }, { "schedule", "add", "job", "0 9 * * *", "-" },
        { "schedule", "add", "--", "job", "0 9 * * *", "text" }, { "schedule", "add", "-1", "0 9 * * *", "text" },
        { "schedule", "bogus" }, { "schedule", "--bogus" }, { "schedule", "--" }, { "schedule", "list", "--" })
      cases[#cases + 1] = agent("schedule", "list")
      cases[#cases + 1] = agent("schedule", "add", "job", "0 9 * * *", "text")
      cases[#cases + 1] = agent("schedule", "rm", "nope")
      cases[#cases + 1] = agent("schedule", "bogus")
      cases[#cases + 1] = agent("schedule", "--help")
      return cases
    end)() },
}
