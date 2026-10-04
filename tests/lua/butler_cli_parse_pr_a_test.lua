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
  T.eval([=[
    local path = os.getenv("REMUDA_LUA_SCRATCH") .. "/pr-a-message.txt"
    local file = assert(io.open(path, "wb")); file:write("file-body"); file:close()
    remuda._butler_file_for_caller = function(p) return p end
    remuda._pr_a_actions = {}
    remuda._pr_a_record = function(kind, ...)
      local args = { ... }
      remuda._pr_a_actions[#remuda._pr_a_actions + 1] = { kind = kind, args = args }
      return "stub:" .. kind
    end
    remuda._butler_send = function(...) return remuda._pr_a_record("send", ...) end
    remuda._butler_reply = function(...) return remuda._pr_a_record("reply", ...) end
    remuda._butler_forward = function(...) return remuda._pr_a_record("forward", ...) end
    remuda._butler_reply_target = function() return "!room:test", "$event" end
    remuda.butler.matrix.cli = function(args)
      return remuda._pr_a_record("upload", table.concat(args, " "))
    end
    remuda._pr_a_caller = { env = { REMUDA_BUTLER_AGENT_ID = "agent-test" } }
    remuda._pr_a_path = path
  ]=])
end

local function luaq(value) return string.format("%q", value) end
local function invoke(verb, args)
  start_butler()
  local quoted = {}
  for _, word in ipairs(args) do quoted[#quoted + 1] = luaq(word) end
  return T.eval([[
    remuda._pr_a_actions = {}
    local result = remuda._butler_command_run(]] .. luaq(verb) .. [[, {]] .. table.concat(quoted, ",") .. [[}, remuda._pr_a_caller)
    local action = remuda._pr_a_actions[1]
    local out = { tostring(result), tostring(action and action.kind or "none") }
    for _, value in ipairs(action and action.args or {}) do out[#out + 1] = tostring(value) end
    return table.concat(out, "|")
  ]])
end

local function path()
  start_butler()
  return os.getenv("REMUDA_LUA_SCRATCH") .. "/pr-a-message.txt"
end

T.test("send lead --file p.txt reads the file body", function()
  local out = invoke("send", { "send", "lead", "--file", path() })
  T.eq(out, "stub:send|send|agent-test|lead|file-body", "send lead --file p.txt")
end)

T.test("send a b --file p keeps the from/to form", function()
  local out = invoke("send", { "send", "a", "b", "--file", path() })
  T.eq(out, "stub:send|send|a|b|file-body", "send a b --file p")
end)

T.test("send --file p.txt lead accepts the option first", function()
  local out = invoke("send", { "send", "--file", path(), "lead" })
  T.eq(out, "stub:send|send|agent-test|lead|file-body", "send --file p.txt lead")
end)

T.test("reply ID --attach PATH caption words uploads with caption", function()
  local out = invoke("reply", { "reply", "ID", "--attach", path(), "caption", "words" })
  local expected = "stub:upload|upload|matrix --room !room:test upload --thread $event --caption caption words " .. path()
  T.eq(out, expected, "reply ID --attach PATH caption words")
end)

T.test("reply ID --file note.txt uses file text as body", function()
  local out = invoke("reply", { "reply", "ID", "--file", path() })
  T.eq(out, "stub:reply|reply|agent-test|ID|file-body", "reply ID --file note.txt")
end)

T.test("reply help in first position returns usage", function()
  local out = invoke("reply", { "reply", "--help" })
  T.expect(out:find("Usage: remuda butler reply", 1, true) ~= nil, "reply --help first position")
end)

T.test("forward help in first position returns usage", function()
  local out = invoke("forward", { "forward", "-h" })
  T.expect(out:find("Usage: remuda butler forward", 1, true) ~= nil, "forward -h first position")
end)

T.test("reply ID -h preserves the body word", function()
  local out = invoke("reply", { "reply", "ID", "-h" })
  T.eq(out, "stub:reply|reply|agent-test|ID|-h", "reply ID -h body word")
end)

T.test("forward ID worker -h preserves the note word", function()
  local out = invoke("forward", { "forward", "ID", "worker", "-h" })
  T.eq(out, "stub:forward|forward|agent-test|ID|worker|-h", "forward ID worker -h body word")
end)

T.test("send lead -- --file x sends the text after the separator", function()
  local out = invoke("send", { "send", "lead", "--", "--file", "x" })
  T.eq(out, "stub:send|send|agent-test|lead|--file x", "send lead -- --file x")
end)

T.test("reply ID -- --file x sends the text after the separator", function()
  local out = invoke("reply", { "reply", "ID", "--", "--file", "x" })
  T.eq(out, "stub:reply|reply|agent-test|ID|--file x", "reply ID -- --file x")
end)

T.test("forward ID worker -- -h sends the note after the separator", function()
  local out = invoke("forward", { "forward", "ID", "worker", "--", "-h" })
  T.eq(out, "stub:forward|forward|agent-test|ID|worker|-h", "forward ID worker -- -h")
end)

T.test("send lead hello world --file p preserves the original positional body", function()
  local out = invoke("send", { "send", "lead", "hello", "world", "--file", "p" })
  T.eq(out, "stub:send|send|lead|hello|world --file p", "send lead hello world --file p behaves like main")
end)

T.test("send lead hello -h preserves the original body word", function()
  local out = invoke("send", { "send", "lead", "hello", "-h" })
  T.eq(out, "stub:send|send|lead|hello|-h", "send lead hello -h behaves like main")
end)
