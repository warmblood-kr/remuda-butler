-- A host-backed session refuses an input act over 8 KiB, while a delegated
-- task can be up to 64 KiB. A longer task is mailed to the member from its
-- leader and a short pointer is typed instead; a short task is typed as is.
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
  remuda._butler_agent_startup.codex = { ready = function() return true end }
  remuda._butler_notify_policy = function() return true end
  remuda._t = { typed = {} }
  remuda.session = function() return { is_busy = false } end
  remuda.capture = function() return "› " end
  remuda.type_text = function(name, text) remuda._t.typed[name] = text end
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

local function typed(name)
  T.wait_until(function()
    return T.eval("return remuda._t.typed[" .. string.format("%q", name) .. "] ~= nil"):match("true") ~= nil
  end, 10, name .. " typed")
  return T.eval("return remuda._t.typed[" .. string.format("%q", name) .. "]")
end

T.test("a_task_over_one_input_act_is_mailed_and_a_pointer_is_typed", function()
  T.eval([[remuda._butler_topic_delegate('t-long', string.rep("x", 8192) .. "END", nil, 'codex', 'butler')]])
  local line = typed("t-long")
  T.ok(#line < 300 and line:find("too long to type here", 1, true) and line:find("remuda butler inbox", 1, true),
    "a short pointer was typed: " .. line:sub(1, 200))
  local id = line:match("message (%S+) in your inbox")
  T.ok(id, "the pointer names the message: " .. line)
  local inbox = T.eval("return remuda._butler_inbox('t-long')")
  T.ok(inbox:find(id, 1, true) and inbox:find("from local/butler", 1, true) and inbox:find("xxxxEND", 1, true),
    "the whole task is in the inbox from the leader")
end)

T.test("a_task_that_fits_is_typed_unchanged", function()
  local task = string.rep("y", 8192)
  T.eval("remuda._butler_topic_delegate('t-fits', string.rep('y', 8192), nil, 'codex', 'butler')")
  T.eq(typed("t-fits"), task, "an 8 KiB task is typed as is")
end)
