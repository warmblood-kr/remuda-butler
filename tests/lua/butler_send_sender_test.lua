T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_launch("codex", "alice")
  remuda._butler_launch("codex", "bob")
  local path = os.getenv("REMUDA_LUA_SCRATCH") .. "/butler-send-file.txt"
  local file = assert(io.open(path, "wb")); file:write("file body"); file:close()
  remuda._butler_file_for_caller = function(p) return p end
  remuda._send_sender_path = path
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

local function quote(value) return string.format("%q", value) end
local setup = T.eval([=[
  local bus = remuda._butler_bus
  return bus.agents.alice.id .. "\n" .. bus.agents.bob.id
]=])
local alice_id, bob_id = setup:match("([^\n]+)\n([^\n]+)")
assert(alice_id and bob_id, "agent setup failed")

local function call(args, agent_id, stdin)
  local encoded = {}
  for _, value in ipairs(args) do encoded[#encoded + 1] = quote(value) end
  local caller = agent_id and string.format("{ kind = 'session', session = %q, instance_id = _inst(%q), stdin = %s }", agent_id, agent_id,
    stdin and quote(stdin) or "nil") or string.format("{ kind = 'outside', stdin = %s }", stdin and quote(stdin) or "nil")
  return T.eval([[
    local ok, result = pcall(remuda._butler_command_run, "send", {]] .. table.concat(encoded, ",")
    .. [[}, ]] .. caller .. [[)
    return (ok and "ok\0" or "error\0") .. tostring(result)
  ]])
end

local function snapshot()
  return T.eval([=[
    local bus = remuda._butler_bus
    local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
    local bob = bus.agents.bob.id
    return table.concat({ tostring(count(bus.messages)), tostring(count(bus.objects)),
      tostring(count(bus.mail_delivered[bob] or {})), tostring(#(bus.inboxes[bob] or {})) }, ":")
  ]=])
end

T.test("an_agent_cannot_choose_another_explicit_sender_in_any_body_form", function()
  local before = snapshot()
  local positional = call({ "send", "bob", "bob", "positional body" }, "alice")
  local stdin = call({ "send", "bob", "bob", "-" }, "alice", "stdin body")
  local path = T.eval("return remuda._send_sender_path")
  local file = call({ "send", "bob", "bob", "--file", path }, "alice")
  local file_option_first = call({ "send", "--file", path, "bob", "bob" }, "alice")
  for _, result in ipairs({ positional, stdin, file, file_option_first }) do
    T.ok(result:match("^error\0"), "mismatched sender must be refused: " .. result)
    T.ok(result:find("sender", 1, true) or result:find("from", 1, true), "short sender refusal missing: " .. result)
  end
  T.eq(snapshot(), before, "refusal must not add mail, deliveries, objects, or counters")
end)

T.test("sender_refusal_is_identical_for_existing_and_unknown_recipients", function()
  local existing = call({ "send", "bob", "bob", "secret" }, "alice")
  local missing = call({ "send", "bob", "missing-member", "secret" }, "alice")
  T.eq(existing:match("^error\0(.*)$"), missing:match("^error\0(.*)$"), "recipient existence must not affect refusal")
end)

T.test("an_agent_can_send_as_itself_and_operator_can_choose_a_sender", function()
  local own = call({ "send", "alice", "alice", "own body" }, "alice")
  T.ok(own:match("^ok\0"), "agent sending as its own alias should work: " .. own)
  local own_id = call({ "send", alice_id, "alice", "own id body" }, "alice")
  T.ok(own_id:match("^ok\0"), "agent sending as its own id should work: " .. own_id)
  local operator = call({ "send", "bob", "alice", "operator body" })
  T.ok(operator:match("^ok\0"), "operator explicit sender should work: " .. operator)
  local inbox = T.eval("return remuda._butler_inbox('alice')")
  T.ok(inbox:find("own body", 1, true) and inbox:find("own id body", 1, true)
    and inbox:find("operator body", 1, true), "accepted mail missing")
end)
