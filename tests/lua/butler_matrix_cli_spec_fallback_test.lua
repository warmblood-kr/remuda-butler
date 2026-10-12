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
      calls[#calls + 1] = "status:" .. tostring(options.json)
      callback({ user_id = "@bot:example.org", joined_rooms = remuda.json.array() })
    end
    m.rooms = function(options, callback)
      calls[#calls + 1] = "rooms:" .. tostring(options.public) .. ":" .. tostring(options.public_term)
      callback({ rooms = remuda.json.array(), mode = "allowlist" })
    end
    m.history = function(options, callback)
      calls[#calls + 1] = "history:" .. tostring(options.room) .. ":" .. tostring(options.n)
      callback({ chunk = remuda.json.array() })
    end
    local result = m.cli({ ]] .. table.concat(words, ",") .. [[ })
    local visible = type(result) == "table" and table.concat({ tostring(result.code), result.stdout or "", result.stderr or "" }, "\0") or tostring(result)
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
