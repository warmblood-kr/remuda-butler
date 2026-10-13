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

T.test("Matrix declared parser and legacy fallback agree on safe forms", function()
  for _, argv in ipairs({
    { "matrix", "status" }, { "matrix", "--json", "status" },
    { "matrix", "rooms" }, { "matrix", "rooms", "--public", "science" },
    { "matrix", "--room", "!room:example.org", "-n", "8", "history" },
    { "matrix", "event", "$event" }, { "matrix", "follow", "$event" },
  }) do
    local current, old = run(true, argv), run(false, argv)
    T.eq(current:gsub("parses=%d+", "parses=N"), old:gsub("parses=%d+", "parses=N"), table.concat(argv, " "))
    T.ok(current:match("parses=[1-9]%d*$"), "current core must consult the declared spec")
    T.ok(old:match("parses=0$"), "old core must use the legacy path")
  end
end)

-- Differential parity: the spec path may only ever accept what the legacy parser accepts and
-- must route identically (same stub fields, same visible reply). Thread is excluded: it
-- always used its declared spec (see the next test). Boundary shapes from SEC #497.
T.test("Matrix declared parser accepts and routes exactly like the legacy parser", function()
  local R, E = "!room:example.org", "$event"
  local cases = {
    -- forbidden root -n / -o outside history / download
    { "matrix", "-n", "8", "status" }, { "matrix", "-o", "/tmp/out", "rooms" },
    { "matrix", "-n", "8", "event", E }, { "matrix", "-o", "/tmp/out", "history" },
    { "matrix", "-n", "8", "get", E }, { "matrix", "-n", "8", "follow", E },
    { "matrix", "-o", "/tmp/out", "unfollow", E }, { "matrix", "-n", "8", "-o", "/tmp/out", "status" },
    { "matrix", "-n", "8", "history" }, { "matrix", "history", "-n", "8" },
    { "matrix", "-o", "/tmp/out", "history", "-n", "3" }, { "matrix", "history", "-o", "/tmp/out" },
    -- rooms TERM without --public, and extra positionals
    { "matrix", "rooms", "science" }, { "matrix", "rooms", "--public" },
    { "matrix", "rooms", "--public", "a", "b" }, { "matrix", "rooms", "science", "--public" },
    { "matrix", "rooms", "science", "--json" }, { "matrix", "--json", "rooms", "--public", "x" },
    -- empty / extra history positionals
    { "matrix", "history", "" }, { "matrix", "history", "words" }, { "matrix", "history", "a", "b" },
    { "matrix", "history", "-n" }, { "matrix", "history", "--room" },
    -- options after the first positional / event id
    { "matrix", "event", E, "--json" }, { "matrix", "event", E, "--room", R },
    { "matrix", "get", E, "--json" }, { "matrix", "follow", E, "--json" },
    { "matrix", "unfollow", E, "--room", R }, { "matrix", "event", "--json", E },
    { "matrix", "event", "--room", R, E }, { "matrix", "--room", R, "event", E },
    { "matrix", "event", E, E }, { "matrix", "event" }, { "matrix", "follow" }, { "matrix", "follow", "nodollar" },
    -- spellings the legacy parser does not know
    { "matrix", "--room=" .. R, "event", E }, { "matrix", "event", "--room=" .. R, E },
    { "matrix", "--n=8", "history" }, { "matrix", "--o=/tmp/out", "download", "mxc://x/y" },
    { "matrix", "-n8", "history" }, { "matrix", "-o/tmp/out", "download", "mxc://x/y" },
    { "matrix", "history", "--n", "8" }, { "matrix", "history", "-n8" },
    { "matrix", "--json=true", "status" }, { "matrix", "--public", "rooms" },
    -- missing values, duplicates, help, unknown flags, empties
    { "matrix", "--room" }, { "matrix", "-n" }, { "matrix", "-o" }, { "matrix", "status", "--room" },
    { "matrix", "--room", R, "--room", "!other:example.org", "event", E },
    { "matrix", "--json", "--json", "status" }, { "matrix", "status", "--help" },
    { "matrix", "history", "--help" }, { "matrix", "status", "--bogus" }, { "matrix", "--bogus", "status" },
    { "matrix", "status", "" }, { "matrix", "event", "" }, { "matrix", "--room", "", "event", E },
    -- verbs with a room option the legacy parser refuses
    { "matrix", "--room", R, "status" }, { "matrix", "--room", R, "rooms" },
    { "matrix", "status", "--room", R }, { "matrix", "--room", R, "history" },
    { "matrix", "--id", E, "status" }, { "matrix", "quarantine", "--id", E },
  }
  for _, argv in ipairs(cases) do
    local current, old = run(true, argv), run(false, argv)
    T.eq((current:gsub("parses=%d+", "parses=N")), (old:gsub("parses=%d+", "parses=N")), table.concat(argv, " "))
  end
end)

-- Thread keeps its pre-existing declared grammar: only --room/--json, no root -n/-o.
T.test("Matrix thread rejects root -n/-o and does not suggest them (no dispatch)", function()
  for _, argv in ipairs({
    { "matrix", "-n", "8", "thread", "$event" }, { "matrix", "-o", "/tmp/out", "thread", "$event" },
    { "matrix", "--n=8", "thread", "$event" }, { "matrix", "-n8", "thread", "$event" },
  }) do
    local out = run(true, argv)
    T.ok(not out:find("thread:", 1, true), "thread must not dispatch: " .. out)
  end
  T.ok(not run(true, { "matrix", "thread", "$event", "--nn" }):find("--n", 5, true), "no --n suggestion")
end)
