-- Matrix's declared CLI spec is used on current cores for safe, simple forms; older cores
-- keep the legacy parser. These calls compare their visible replies and dispatched options.
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
end

local function run(parser, argv)
  start_butler()
  local words = {}
  for _, word in ipairs(argv) do words[#words + 1] = string.format("%q", word) end
  return T.eval([[
    local m = remuda.butler.matrix
    local saved_cli, saved_pending = remuda.cli, remuda.pending
    local saved_guidance, saved_status, saved_rooms, saved_history = m.configuration_guidance,
      m.status, m.rooms, m.history
    local calls, parses = {}, 0
    local parse = saved_cli and saved_cli.parse
    if not ]] .. tostring(parser) .. [[ then
      remuda.cli = nil
    elseif type(parse) == "function" then
      remuda.cli = setmetatable({ parse = function(spec, args)
        parses = parses + 1
        return parse(spec, args)
      end }, { __index = saved_cli })
    end
    remuda.pending = function()
      return { resolve = function(_, code, stdout, stderr)
        return { code = code, stdout = stdout, stderr = stderr }
      end }
    end
    m.configuration_guidance = function() return nil end
    m.configured_room = function() return "!room:example.org" end
    m.status = function(options, callback)
      calls[#calls + 1] = "status:" .. tostring(options.json) .. ":" .. tostring(options.room)
        .. ":" .. tostring(options.n) .. ":" .. tostring(options.output)
      callback({ user_id = "@bot:example.org", joined_rooms = remuda.json.array() })
    end
    m.rooms = function(options, callback)
      calls[#calls + 1] = "rooms:" .. tostring(options.public) .. ":" .. tostring(options.public_term)
        .. ":" .. tostring(options.room) .. ":" .. tostring(options.n) .. ":" .. tostring(options.output)
        .. ":" .. tostring(options.json)
        .. ":" .. tostring(options.room) .. ":" .. tostring(options.n) .. ":" .. tostring(options.output)
        .. ":" .. tostring(options.json)
      callback({ rooms = remuda.json.array(), mode = "allowlist" })
    end
    m.history = function(options, callback)
      calls[#calls + 1] = "history:" .. tostring(options.room) .. ":" .. tostring(options.n)
        .. ":" .. tostring(options.output) .. ":" .. tostring(options.json)
      callback({ chunk = remuda.json.array() })
    end
    for _, name in ipairs({ "event", "thread" }) do
      m[name] = function(options, callback)
        calls[#calls + 1] = name .. ":" .. tostring(options.room) .. ":" .. tostring(options.event_id)
          .. ":" .. tostring(options.json) .. ":" .. tostring(options.n) .. ":" .. tostring(options.output)
        callback({ sender = "@a:example.org", content = { body = "hi" }, chunk = remuda.json.array() })
      end
    end
    local called, result = pcall(m.cli, { ]] .. table.concat(words, ",") .. [[ })
    local visible = not called and ("error:" .. tostring(result)) or type(result) == "table" and table.concat({ tostring(result.code), result.stdout or "", result.stderr or "" }, "\0") or tostring(result)
    m.configuration_guidance, m.status, m.rooms, m.history = saved_guidance, saved_status, saved_rooms, saved_history
    remuda.cli, remuda.pending = saved_cli, saved_pending
    return visible .. "\n" .. table.concat(calls, "\n") .. "\nparses=" .. parses
  ]])
end

T.test("Matrix safe forms dispatch through the shared parser", function()
  local cases = {
    {{"matrix", "status"}, "status:nil"},
    {{"matrix", "--json", "status"}, "status:true"},
    {{"matrix", "rooms", "--public", "science"}, "rooms:true:science"},
    {{"matrix", "--room", "!room:example.org", "-n", "8", "history"}, "history:!room:example.org:8"},
    {{"matrix", "history", "-n", "8"}, "history:nil:8"},
    {{"matrix", "event", "$event"}, "event:nil:$event"},
  }
  for _, case in ipairs(cases) do
    local out = run(true, case[1])
    T.ok(out:find(case[2], 1, true), out)
    T.ok(out:find("parses=1", 1, true), out)
  end
end)

T.test("Matrix refuses an unavailable parser instead of using legacy grammar", function()
  local out = run(false, {"matrix", "status"})
  T.ok(out:find("Matrix CLI requires remuda.cli.parse; upgrade Remuda core", 1, true), out)
  T.ok(not out:find("\nstatus:", 1, true), out)
end)

T.test("Matrix invalid options and arity never dispatch an action", function()
  for _, argv in ipairs({
    {"matrix", "-n", "8", "status"}, {"matrix", "-o", "/tmp/out", "rooms"},
    {"matrix", "-n", "8", "thread", "$event"},
    {"matrix", "rooms", "science"}, {"matrix", "event"},
    {"matrix", "history", "extra"}, {"matrix", "--json", "--json", "status"},
    {"matrix", "status", "--bogus"}, {"matrix", "history", "-n"},
  }) do
    local out = run(true, argv)
    T.ok(not out:find("\nstatus:", 1, true) and not out:find("\nhistory:", 1, true)
      and not out:find("\nrooms:", 1, true) and not out:find("\nevent:", 1, true)
      and not out:find("\nthread:", 1, true), out)
  end
end)
