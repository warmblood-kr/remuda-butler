-- remuda#606 item 2: a member that reports with --done is closed by the
-- auto-close tick once its inbox is drained and its pane is idle, by its
-- parent through the normal close path. A plain report never closes.
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

-- Every case runs in one daemon call against a stubbed roster, close, idle check
-- and process list, then restores them, so the live roster never sees the rows.
local function outcomes()
  return T.eval([=[
    local bus = remuda._butler_bus
    local saved = { agents = bus.agents, close = remuda.close, ls = remuda.ls, idle = remuda.butler.is_idle,
      fail = remuda.fail, done = remuda._butler_done }
    local closed, busy = {}, {}
    bus.agents = { butler = saved.agents.butler }
    for _, row in ipairs({ { "lead", "butler" }, { "plain", "lead" }, { "finished", "lead" }, { "unread", "lead" },
        { "busy", "lead" }, { "followup", "lead" }, { "cli", "lead" }, { "orphan" } }) do
      bus.agents[row[1]] = { id = "606done-" .. row[1], alias = row[1], kind = "codex", parent = row[2],
        session_name = row[1] }
    end
    remuda._butler_done = {}
    remuda.close = function(name) closed[#closed + 1] = name end
    remuda.ls = function() return {} end
    remuda.butler.is_idle = function(name) if busy[name] then return false, "busy" end return true end
    remuda.fail = function(message) error(message, 0) end
    local out = {}
    local function state(label, name)
      local was = false
      for _, c in ipairs(closed) do was = was or c == name end
      out[#out + 1] = label .. "=" .. (was and "closed" or "open")
    end
    local ok, err = pcall(function()
      remuda._butler_report("plain", "progress, still working")
      remuda._butler_report("finished", "all done", true)
      remuda._butler_send("lead", "unread", "a task it has not read")
      remuda._butler_report("unread", "done, but mail is waiting", true)
      busy.busy = true
      remuda._butler_report("busy", "done, pane still busy", true)
      remuda._butler_report("followup", "done", true)
      remuda._butler_send("lead", "followup", "one more thing")
      remuda._butler_inbox("followup")
      remuda._extension_commands.butler({ "send-to-leader", "--done", "cli", "done" },
        { env = { REMUDA_BUTLER_AGENT_ID = "cli" } })
      remuda._butler_done.orphan = true
      remuda._butler_done_tick()
      state("plain", "plain")
      state("finished", "finished")
      state("unread", "unread")
      state("busy", "busy")
      state("followup-mail-clears", "followup")
      state("cli-done", "cli")
      state("parentless", "orphan")
      state("root", "butler")
      remuda._butler_inbox("unread")
      busy.busy = nil
      closed = {}
      remuda._butler_done_tick()
      state("unread-after-drain", "unread")
      state("busy-after-idle", "busy")
      state("finished-only-once", "finished")
    end)
    bus.agents, remuda.close, remuda.ls, remuda.butler.is_idle, remuda.fail, remuda._butler_done =
      saved.agents, saved.close, saved.ls, saved.idle, saved.fail, saved.done
    if not ok then error(err, 0) end
    return table.concat(out, " ")
  ]=])
end

T.test("done reports auto-close once drained and idle; plain reports never", function()
  start_butler()
  T.eq(outcomes(), table.concat({
    "plain=open", "finished=closed", "unread=open", "busy=open", "followup-mail-clears=open", "cli-done=closed",
    "parentless=open", "root=open",
    "unread-after-drain=closed", "busy-after-idle=closed", "finished-only-once=open",
  }, " "), "done auto-close")
end)
