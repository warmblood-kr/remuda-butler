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
      fail = remuda.fail, done = remuda._butler_done, tokens = bus.tokens, identity_ids = bus.identity_ids,
      identities = bus.identities, emit = remuda.emit }
    local closed, busy = {}, {}
    bus.agents = { butler = saved.agents.butler }
    local ids = {}
    for _, row in ipairs({ { "lead", "butler" }, { "plain", "lead" }, { "finished", "lead" }, { "unread", "lead" },
        { "busy", "lead" }, { "followup", "lead" }, { "cli", "lead" }, { "orphan" },
        { "mcp-bool", "lead" }, { "mcp-string", "lead" }, { "mcp-false", "lead" }, { "mcp-omitted", "lead" },
        { "mcp-invalid", "lead" }, { "stale", "lead" }, { "replaced", "lead" }, { "relaunched", "lead" },
        { "inst", "lead" }, { "legacy", "lead" }, { "exiter", "lead" }, { "hooked", "lead" } }) do
      ids[#ids + 1] = string.format("01M606D0NE%016d", #ids + 1)
      bus.agents[row[1]] = { id = ids[#ids], alias = row[1], kind = "codex", parent = row[2],
        session_name = row[1], token = "606done-token-" .. row[1], session_start_marker = "606done-gen-" .. row[1], children = {} }
    end
    remuda._butler_done = {}
    -- A retained edge from before an alias was reused: close_member refuses it as not owned.
    bus.agents.stale.parent_id = "606done-an-earlier-lead"
    bus.tokens = setmetatable({}, { __index = saved.tokens })
    bus.identity_ids = setmetatable({}, { __index = saved.identity_ids })
    bus.identities = setmetatable({}, { __index = saved.identities })
    bus.agents.inst.instance_id, bus.agents.inst.instance_binding = "606done-instance-1", 1
    -- What main's capability admission checks (identity.lua caller_name): a token record bound to the
    -- row's id and generation, a running identity record, and a live session for the row.
    for alias, agent in pairs(bus.agents) do
      if alias ~= "butler" then
        bus.tokens[agent.token] = { id = agent.id, generation = agent.session_start_marker }
        bus.identity_ids[agent.id] = { id = agent.id, alias = alias, state = "running" }
      end
    end
    remuda.close = function(name) closed[#closed + 1] = name end
    remuda.ls = function()
      local rows = {}
      for alias in pairs(bus.agents) do
        if alias:match("^mcp%-") then rows[#rows + 1] = { name = alias, alive = true } end
      end
      return rows
    end
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
        { kind = "session", session = "cli" })
      -- Tool-level: remuda._call now replaces the caller, so call the tool's run with the capability.
      -- Admission itself is covered by the capability lifecycle, instance binding and caller principal suites.
      local tool
      for k, v in pairs(remuda.tools) do
        if k == "butler_send_to_leader" or (type(v) == "table" and v.name == "butler_send_to_leader") then tool = v end
      end
      local function mcp(name, args)
        args.text = name .. " reports"
        return pcall(tool.run, args, { capability = "606done-token-" .. name })
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
      -- remuda#606 SEC MUST 1: the mark belongs to the reporting incarnation only.
      remuda._butler_report("replaced", "done", true)
      local fresh = { id = "01M606D0NE9999999999999999", alias = "replaced", kind = "codex", parent = "lead",
        session_name = "replaced", token = "606done-token-replaced-2", session_start_marker = "606done-gen-replaced-2" }
      bus.agents.replaced, bus.identity_ids[fresh.id] = fresh, { id = fresh.id, alias = "replaced", state = "running" }
      remuda._butler_report("relaunched", "done", true)
      bus.agents.relaunched.session_start_marker = "606done-gen-relaunched-2"
      remuda._butler_report("inst", "done", true)
      bus.agents.inst.instance_id = "606done-instance-2"
      remuda._butler_done.legacy = true -- a mark left by an older image across a reload
      remuda._butler_report("exiter", "done", true)
      remuda._butler_session_exited("exiter", nil)
      out[#out + 1] = "exit-clears-mark=" .. tostring(remuda._butler_done.exiter == nil)
      -- A synchronous report hook that mails the member back must still cancel the request.
      remuda.emit = function(event, from, ...)
        if event == "butler/report" and from == "hooked" then remuda._butler_send("lead", "hooked", "hook reply") end
        return saved.emit(event, from, ...)
      end
      remuda._butler_report("hooked", "done", true)
      remuda.emit = saved.emit
      out[#out + 1] = "hook-mail-clears-mark=" .. tostring(remuda._butler_done.hooked == nil)
      remuda._butler_inbox("hooked") -- drained: only the cleared mark keeps it open now
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
      out[#out + 1] = "busy-mark-kept=" .. tostring(remuda._butler_done.busy ~= nil)
      state("replacement", "replaced")
      out[#out + 1] = "replacement-mark-dropped=" .. tostring(remuda._butler_done.replaced == nil)
      state("relaunch", "relaunched")
      state("instance-mismatch", "inst")
      state("legacy-mark", "legacy")
      out[#out + 1] = "legacy-mark-dropped=" .. tostring(remuda._butler_done.legacy == nil)
      state("hook-mail-clears", "hooked")
      remuda._butler_inbox("unread")
      busy.busy = nil
      closed = {}
      remuda._butler_done_tick()
      state("unread-after-drain", "unread")
      state("busy-after-idle", "busy")
      state("finished-only-once", "finished")
    end)
    bus.agents, remuda.close, remuda.ls, remuda.butler.is_idle, remuda.fail, remuda._butler_done, bus.tokens,
      bus.identity_ids = saved.agents, saved.close, saved.ls, saved.idle, saved.fail, saved.done, saved.tokens,
      saved.identity_ids
    bus.identities, remuda.emit = saved.identities, saved.emit
    if not ok then error(err, 0) end
    return table.concat(out, " ")
  ]=])
end

T.test("done reports auto-close once drained and idle; plain reports never", function()
  start_butler()
  T.eq(outcomes(), table.concat({
    "mcp-invalid-refused=true", "exit-clears-mark=true", "hook-mail-clears-mark=true",
    "plain=open", "finished=closed", "unread=open", "busy=open", "followup-mail-clears=open", "cli-done=closed",
    "parentless=open", "root=open",
    "mcp-done-true=closed", "mcp-done-string-true=closed", "mcp-done-string-false=open", "mcp-done-omitted=open",
    "mcp-done-invalid=open", "stale-generation=open", "stale-mark-cleared=true", "busy-mark-kept=true",
    "replacement=open", "replacement-mark-dropped=true", "relaunch=open", "instance-mismatch=open",
    "legacy-mark=open", "legacy-mark-dropped=true", "hook-mail-clears=open",
    "unread-after-drain=closed", "busy-after-idle=closed", "finished-only-once=open",
  }, " "), "done auto-close")
end)

-- A new registration under an alias drops any mark an earlier member left there.
T.test("a new registration clears a leftover done mark for its alias", function()
  start_butler()
  T.eq(T.eval([=[
    remuda._butler_agent_builders.fake606 = remuda._butler_agent_builders.fake606
      or function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_done["reg606"] = { id = "01M606D0NE0000000000000EARLY", generation = "earlier" }
    remuda._butler_launch("fake606", "reg606")
    local cleared = remuda._butler_done["reg606"] == nil and remuda._butler_bus.agents.reg606 ~= nil
    pcall(remuda.close, "reg606")
    return tostring(cleared)
  ]=]), "true", "registration clears the alias's done mark")
end)

-- Route level: the MCP bridge is an outside caller, so its capability is not admitted and no mark is set.
T.test("the MCP route refuses an unadmitted done report without marking", function()
  start_butler()
  local token = T.eval([=[
    remuda._butler_agent_builders.fake606 = remuda._butler_agent_builders.fake606
      or function() return { "sh", "-c", "sleep 60" } end
    remuda._butler_launch("fake606", "route606")
    return remuda._butler_bus.agents.route606.token
  ]=])
  local reply = T.mcp_call("butler_send_to_leader", { text = "done over the bridge", done = true }, token)
  local text = tostring(reply.error and reply.error.message
    or (reply.result and reply.result.content and reply.result.content[1] and reply.result.content[1].text))
  local marked = T.eval('local m = remuda._butler_done["route606"]; pcall(remuda.close, "route606"); return tostring(m ~= nil)')
  T.expect(text:find("unknown caller", 1, true) ~= nil, "outside bridge must be refused: " .. text)
  T.eq(marked, "false", "a refused route must not mark the member done")
end)
