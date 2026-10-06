-- Verbs migrated to declared CLI specs must behave identically with and without remuda.cli.parse
-- (an old core that predates the parser keeps the hand-parsed fallback). Stubs only; no live actions.
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
  T.eval([[
    local d = remuda._butler_doctor
    d.probe = function() return {} end
    d.render = function() return { "doctor-stub" } end
    d.permission_lines = function() return {} end
    remuda._butler_sessions = function() return "sessions-stub" end
    remuda._butler_status = function() return "up", 0 end
    return "ok"
  ]])
end

-- Runs one verb through the handler table with the parser present or removed.
-- Result: the value as text ("nil" when the verb declines, so the caller prints global usage).
local function run(parser, verb, args)
  start_butler()
  local words = {}
  for _, word in ipairs(args) do words[#words + 1] = string.format("%q", word) end
  return T.eval([[
    local saved = remuda.cli
    if not ]] .. tostring(parser) .. [[ then remuda.cli = nil end
    local ok, result = pcall(remuda._butler_command_run, ]] .. string.format("%q", verb) .. [[, { ]] .. table.concat(words, ",") .. [[ }, nil)
    remuda.cli = saved
    return tostring(ok) .. "|" .. tostring(result)
  ]])
end

local function both(verb, args, want)
  for _, parser in ipairs({ true, false }) do
    T.eq(run(parser, verb, args), want, verb .. " " .. table.concat(args, " ") .. " parser=" .. tostring(parser))
  end
end

T.test("zero-arg verbs run with and without the parser", function()
  both("doctor", { "doctor" }, "true|doctor-stub")
  both("sessions", { "sessions" }, "true|sessions-stub")
  both("status", { "status" }, "true|up")
end)

T.test("zero-arg verbs decline anything else (global usage)", function()
  for _, verb in ipairs({ "doctor", "sessions", "status" }) do
    for _, extra in ipairs({ "extra", "--help", "-h", "help", "--json", "--" }) do
      both(verb, { verb, extra }, "true|nil")
    end
  end
end)

T.test("agents takes only a single --all, with and without the parser", function()
  for _, args in ipairs({ { "agents" }, { "agents", "--all" } }) do
    local with = run(true, "agents", args)
    T.ok(with:match("^true|ID\tALIAS"), "listing for " .. table.concat(args, " "))
    T.eq(run(false, "agents", args), with, "same listing without the parser")
  end
  for _, bad in ipairs({ { "--all", "--all" }, { "--all=1" }, { "extra" }, { "--bogus" }, { "--" },
    { "--", "--all" }, { "--all", "extra" }, { "extra", "--all" }, { "--help" }, { "-h" }, { "help" },
    { "--help", "--all" }, { "-a" } }) do
    local args = { "agents" }
    for _, word in ipairs(bad) do args[#args + 1] = word end
    for _, parser in ipairs({ true, false }) do
      T.eq(run(parser, "agents", args), "true|nil", table.concat(args, " ") .. " parser=" .. tostring(parser))
    end
  end
end)

T.test("the agents spec reports --all as a flag value", function()
  start_butler()
  T.eq(T.eval([[
    local r = remuda.cli.parse({ name = "remuda butler", verbs = { agents = { about = "x", next = "y",
      options = { { long = "all", help = "z" } } } } }, { "agents", "--all" })
    return tostring(r.ok) .. "|" .. tostring(r.values.all)
  ]]), "true|true")
end)
