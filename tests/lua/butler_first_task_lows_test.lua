-- #324: first-task failure mail for a replaced launch, and the Codex inline
-- path's Return cap against a stale screen.
local function start_butler()
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
    remuda._butler_task_retry_delays = {}
    remuda._t = { keys = 0, types = 0, screen = "› " }
    remuda.key = function(_, key) if key == "RET" then remuda._t.keys = remuda._t.keys + 1 end end
    remuda.session = function() return { is_busy = false } end
  ]], os.getenv("XDG_DATA_HOME") .. "/projects"))
end

-- Reading the inbox marks it read, so accumulate what each read returns.
local seen = ""
local function leader_mail()
  seen = seen .. T.eval("return remuda._butler_inbox('butler')")
  return seen
end

T.test("replaced launch mail and the stale-screen Return cap", function()
  start_butler()
  T.eval([[remuda.capture = function() return remuda._t.screen end
    remuda.type_text = function() remuda._t.types = remuda._t.types + 1 end]])
  -- The task carries a bidi override and an apostrophe; the command keeps the
  -- apostrophe quoted and drops the override.
  T.eval([[remuda._butler_topic_delegate('t-rep', "do \226\128\174it 'now'", nil, 'codex', 'butler')
    remuda._butler_bus.agents['t-rep'].session_start_marker = 'replaced']])
  T.wait_until(function() return leader_mail():find("t-rep", 1, true) ~= nil end, 10, "replaced-launch mail")
  local mail = leader_mail()
  T.expect(mail:find("was not delivered: its launch was replaced", 1, true), "no replaced notice: " .. mail,
    "ok - replaced launch reaches the leader")
  T.expect(mail:find("POSIX shell", 1, true), "mail omits POSIX shell: " .. mail)
  T.expect(mail:find("remuda butler send 't-rep' 'do it '\\''now'\\'''", 1, true), "command altered: " .. mail)
  T.expect(not mail:find("`", 1, true) and not mail:find("\226\128\174", 1, true),
    "mail kept a backtick or bidi character: " .. mail, "ok - no backtick or bidi in the resend mail")
  T.eq(T.eval("return tostring(remuda._t.types)"), "0", "a replaced launch typed the task")

  -- Same daemon: a second exec would reload the mod under the mocks.
  T.eval([[remuda._butler_task_poke_deferrals = 18
    remuda.capture = function() return remuda._t.screen end
    remuda.type_text = function(name, text)
      if name == "t-stale" then remuda._t.types = remuda._t.types + 1; remuda._t.screen = "› " .. text end
    end
    remuda._butler_topic_delegate('t-stale', 'stale task', nil, 'codex', 'butler')]])
  T.wait_until(function() return leader_mail():find("t-stale", 1, true) ~= nil end, 20, "not-submitted mail")
  T.expect(leader_mail():find("it was typed but not submitted", 1, true), "wrong failure: " .. leader_mail())
  T.eq(T.eval("return tostring(remuda._t.keys)"), "3", "Return resends were not capped at three")
  T.eq(T.eval("return tostring(remuda._t.types)"), "1", "the task was typed more than once")
end)
