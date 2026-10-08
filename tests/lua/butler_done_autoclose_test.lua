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
      fail = remuda.fail, done = remuda._butler_done, tokens = bus.tokens }
    local closed, busy = {}, {}
    bus.agents = { butler = saved.agents.butler }
    for _, row in ipairs({ { "lead", "butler" }, { "plain", "lead" }, { "finished", "lead" }, { "unread", "lead" },
        { "busy", "lead" }, { "followup", "lead" }, { "cli", "lead" }, { "orphan" },
        { "mcp-bool", "lead" }, { "mcp-string", "lead" }, { "mcp-false", "lead" }, { "mcp-omitted", "lead" },
        { "mcp-invalid", "lead" }, { "stale", "lead" } }) do
      bus.agents[row[1]] = { id = "606done-" .. row[1], alias = row[1], kind = "codex", parent = row[2],
        session_name = row[1], token = "606done-token-" .. row[1] }
    end
    remuda._butler_done = {}
    -- A retained edge from before an alias was reused: close_member refuses it as not owned.
    bus.agents.stale.parent_id = "606done-an-earlier-lead"
    bus.tokens = setmetatable({}, { __index = saved.tokens })
    for alias, agent in pairs(bus.agents) do if agent.token then bus.tokens[agent.token] = alias end end
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
      local function mcp(name, args)
        args.text = name .. " reports"
        return pcall(remuda._call, "butler_send_to_leader", args, { capability = "606done-token-" .. name })
      end
      mcp("mcp-bool", { done = true })
      mcp("mcp-string", { done = "true" })
      mcp("mcp-false", { done = "false" })
      mcp("mcp-omitted", {})
      local invalid_ok, invalid_error = mcp("mcp-invalid", { done = "yes" })
      out[#out + 1] = "mcp-invalid-refused=" .. tostring(not invalid_ok
        and tostring(invalid_error):find("done must be a boolean.", 1, true) ~= nil
        and remuda._butler_done["mcp-invalid"] == nil)
      remuda._butler_report("stale", "done under a reused leader alias", true)
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
      state("mcp-done-true", "mcp-bool")
      state("mcp-done-string-true", "mcp-string")
      state("mcp-done-string-false", "mcp-false")
      state("mcp-done-omitted", "mcp-omitted")
      state("mcp-done-invalid", "mcp-invalid")
      state("stale-generation", "stale")
      out[#out + 1] = "stale-mark-cleared=" .. tostring(remuda._butler_done.stale == nil)
      out[#out + 1] = "busy-mark-kept=" .. tostring(remuda._butler_done.busy == true)
      remuda._butler_inbox("unread")
      busy.busy = nil
      closed = {}
      remuda._butler_done_tick()
      state("unread-after-drain", "unread")
      state("busy-after-idle", "busy")
      state("finished-only-once", "finished")
    end)
    bus.agents, remuda.close, remuda.ls, remuda.butler.is_idle, remuda.fail, remuda._butler_done, bus.tokens =
      saved.agents, saved.close, saved.ls, saved.idle, saved.fail, saved.done, saved.tokens
    if not ok then error(err, 0) end
    return table.concat(out, " ")
  ]=])
end

T.test("done reports auto-close once drained and idle; plain reports never", function()
  start_butler()
  T.eq(outcomes(), table.concat({
    "mcp-invalid-refused=true",
    "plain=open", "finished=closed", "unread=open", "busy=open", "followup-mail-clears=open", "cli-done=closed",
    "parentless=open", "root=open",
    "mcp-done-true=closed", "mcp-done-string-true=closed", "mcp-done-string-false=open", "mcp-done-omitted=open",
    "mcp-done-invalid=open", "stale-generation=open", "stale-mark-cleared=true", "busy-mark-kept=true",
    "unread-after-drain=closed", "busy-after-idle=closed", "finished-only-once=open",
  }, " "), "done auto-close")
end)
