-- #477 chooses the complete done-specific refusal matrix, rather than claiming
-- an admitted native MCP transport case. Native snapshots below call tool.run;
-- the real transport is separately checked for outside callers on both names.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
end, 5, "Butler root ready")

T.test("both done tools refuse stale, unbound, unknown and nonlive callers without effects", function()
  T.eq(T.eval([=[
    local bus = remuda._butler_bus
    local saved = { agents = bus.agents, tokens = bus.tokens, identities = bus.identity_ids,
      ls = remuda.ls, report = remuda._butler_report, done = remuda._butler_done,
      strict = remuda._butler_strict_instance_binding }
    local calls, cases = 0, 0
    local function normalized(value)
      if type(value) ~= "table" then return value end
      local object = remuda.json.object({})
      for key, item in pairs(value) do object[tostring(key)] = normalized(item) end
      return object
    end
    local function snapshot()
      return remuda.json.encode(normalized { messages = bus.messages, objects = bus.objects,
        inboxes = bus.inboxes, delivered = bus.mail_delivered, read = bus.mail_read,
        agents = bus.agents, tokens = bus.tokens, done = remuda._butler_done, next = bus.next })
    end
    remuda._butler_report = function() calls = calls + 1; error("report helper reached", 0) end
    local ok, err = pcall(function()
      for _, tool_name in ipairs({ "butler_send_to_leader", "butler_report" }) do
        local tool
        for key, spec in pairs(remuda.tools) do
          if key == tool_name or (type(spec) == "table" and spec.name == tool_name) then tool = spec end
        end
        assert(tool, "missing tool: " .. tool_name)
        for _, scenario in ipairs({ "outside", "unknown", "garbage-capability", "stale-id",
            "stale-generation", "ended", "missing-registration", "dead", "missing-process",
            "ls-error", "strict-capability-only", "strict-unbound", "missing-snapshot-instance",
            "stale-native-instance", "unproven-binding", "mismatched-capability-instance",
            "native-not-live" }) do
          local agent = { id = "01M47700000000000000000001", alias = "matrix-member", kind = "codex",
            parent = "butler", session_name = "matrix-member", session_start_marker = "generation",
            token = "fixture-capability", children = {} }
          local record = { id = agent.id, generation = agent.session_start_marker }
          local identity = { id = agent.id, alias = agent.alias, state = "running" }
          bus.agents = { butler = saved.agents.butler, [agent.alias] = agent }
          bus.tokens, bus.identity_ids = { [agent.token] = record }, { [agent.id] = identity }
          remuda._butler_done, remuda._butler_strict_instance_binding = {}, false
          local rows = {{ name = agent.session_name, alive = true }}
          remuda.ls = function() return rows end
          local caller = { capability = agent.token }
          if scenario == "outside" then caller.kind = "outside"
          elseif scenario == "unknown" then caller.kind = "unknown"
          elseif scenario == "garbage-capability" then caller.capability = "absent-fixture"
          elseif scenario == "stale-id" then record.id = "01M47700000000000000000002"
          elseif scenario == "stale-generation" then record.generation = "old"
          elseif scenario == "ended" then identity.state = "ended"
          elseif scenario == "missing-registration" then bus.agents[agent.alias] = nil
          elseif scenario == "dead" then rows[1].alive = false
          elseif scenario == "missing-process" then rows = {}
          elseif scenario == "ls-error" then remuda.ls = function() error("fixture unavailable", 0) end
          elseif scenario == "strict-capability-only" then remuda._butler_strict_instance_binding = true
          else
            caller.kind, caller.session, caller.instance_id = "session", agent.session_name, "BOUND"
            agent.instance_id, agent.instance_binding = "BOUND", 1
            record.instance_id, record.instance_binding = "BOUND", 1
            if scenario == "strict-unbound" then
              remuda._butler_strict_instance_binding = true
              agent.instance_id, agent.instance_binding = nil, nil
              record.instance_id, record.instance_binding = nil, nil
            elseif scenario == "missing-snapshot-instance" then caller.instance_id = nil
            elseif scenario == "stale-native-instance" then caller.instance_id = "OLD"
            elseif scenario == "unproven-binding" then
              remuda._butler_strict_instance_binding = true; agent.instance_binding = nil
            elseif scenario == "mismatched-capability-instance" then record.instance_id = "OLD"
            end
            -- native-not-live: the fake BOUND instance does not exist in the
            -- core. Its real captured _caller_live refuses or raises.
          end
          local before = snapshot()
          local admitted, why = pcall(tool.run, { text = "done refusal fixture", done = true }, caller)
          assert(not admitted and tostring(why):find("unknown caller", 1, true),
            tool_name .. "/" .. scenario .. " was admitted or refused for the wrong reason: " .. tostring(why))
          assert(calls == 0, tool_name .. "/" .. scenario .. " reached report/send")
          assert(snapshot() == before, tool_name .. "/" .. scenario .. " changed mail, roster or consent")
          cases = cases + 1
        end
      end
    end)
    bus.agents, bus.tokens, bus.identity_ids = saved.agents, saved.tokens, saved.identities
    remuda.ls, remuda._butler_report, remuda._butler_done = saved.ls, saved.report, saved.done
    remuda._butler_strict_instance_binding = saved.strict
    if not ok then error(err, 0) end
    return tostring(cases)
  ]=]), "34")
end)

T.test("real outside MCP transport refuses done on both tool names without mail or marks", function()
  local function snapshot()
    return T.eval([[
      local b, n = remuda._butler_bus, { 0, 0, 0, 0 }
      for _ in pairs(b.messages) do n[1] = n[1] + 1 end
      for _ in pairs(b.objects) do n[2] = n[2] + 1 end
      for _, inbox in pairs(b.inboxes) do n[3] = n[3] + #inbox end
      for _ in pairs(remuda._butler_done) do n[4] = n[4] + 1 end
      return table.concat(n, ":") .. ":" .. b.next
    ]])
  end
  local before = snapshot()
  for _, name in ipairs({ "butler_send_to_leader", "butler_report" }) do
    local response = T.mcp_call(name, { text = "outside done fixture", done = true })
    local text = response.error and response.error.message
      or response.result and response.result.content[1].text or ""
    T.ok(text:find("unknown caller", 1, true), name .. " admitted an outside done report")
    T.eq(snapshot(), before, name .. " changed mail or consent on refusal")
  end
end)
