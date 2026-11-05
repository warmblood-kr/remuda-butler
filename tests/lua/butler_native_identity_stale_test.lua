-- A native identity lookup may finish after the launch it was started for has
-- been replaced. The whole registration must abort at that fence: no parent
-- child, no legacy migration, no mailbox, no roster write, no first task and
-- no composer/PTY act into the replacement. The original task is kept only
-- when the durable write really succeeds; otherwise the report says so.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
end, 5, "root start")

T.eval([=[
  local t = {}
  remuda._stale_t = t
  t.real = { new = remuda.new, ls = remuda.ls,
    launch = remuda._butler_native_launch, send = remuda._butler_send,
    roster = remuda._butler_roster_save }
  t.rows, t.reports = {}, {}
  function t.install()
    -- A fake core registry: the old projection drops row.id and the daemon has
    -- not listed the fresh row yet, so ls must expose it from the spawn itself.
    remuda.new = function(name)
      t.rows[name] = "inst-" .. name
      return name, "inst-" .. name
    end
    remuda.ls = function(...)
      local out = {}
      for _, row in ipairs(t.real.ls(...)) do
        if not t.rows[row.name] then
          out[#out + 1] = { name = row.name, alive = row.alive,
            instance_id = row.instance_id }
        end
      end
      for name, instance in pairs(t.rows) do
        out[#out + 1] = { name = name, alive = true, instance_id = instance }
      end
      return out
    end
    local fence = {}
    fence.plan = function(name, kind)
      return { mode = "native", kind = kind, name = name,
        binding = "/private/fake/manifest.json", nonce = string.rep("a", 32),
        created_at = os.time() }
    end
    fence.env = t.real.launch.env
    fence.join = t.real.launch.join
    remuda._butler_native_launch = fence
    remuda.butler.native_launch = fence
    remuda._butler_native_identity = { resolve = function(row)
      t.probe = true
      remuda._butler_bus.agents[row.name] =
        { kind = "codex", id = "replacement-id", children = {} }
      return "core-id-stale"
    end }
    t.real_send = remuda._butler_send
    remuda._butler_send = function(from, to, text)
      t.reports[#t.reports + 1] = tostring(text)
      return t.real_send(from, to, text)
    end
    t.roster = 0
    if t.real.roster then
      remuda._butler_roster_save = function(...)
        t.roster = t.roster + 1
        return t.real.roster(...)
      end
    end
    remuda.butler.project_home(os.getenv("XDG_DATA_HOME") .. "/projects")
    remuda._butler_agent_builders.codex =
      function() return {"sh", "-c", "sleep 60"} end
  end
  function t.restore()
    remuda.new, remuda.ls = t.real.new, t.real.ls
    remuda._butler_native_launch = t.real.launch
    remuda.butler.native_launch = t.real.launch
    remuda._butler_native_identity = nil
    remuda._butler_send = t.real_send
    remuda._butler_roster_save = t.real.roster
    t.rows, t.reports, t.probe, t.roster = {}, {}, nil, 0
  end
  function t.replacement_effects(name)
    local bus = remuda._butler_bus
    local agent = bus.agents[name]
    local child = false
    for _, entry in ipairs(bus.agents.butler.children or {}) do
      if entry == name then child = true end
    end
    local failure = bus.launch_failures and bus.launch_failures[name]
    return table.concat({ tostring(agent.id), tostring(child),
      tostring(agent.native), tostring(agent.token), tostring(agent.task),
      tostring(bus.unread_seeded and bus.unread_seeded[name]),
      tostring(t.roster), tostring(t.probe),
      tostring(failure and failure.error or "none") }, "|")
  end
]=])

T.test("a stale native identity join aborts the whole registration", function()
  T.eval([[
    local t = remuda._stale_t
    t.install()
    remuda._butler_launch_impl.launch_agent("codex", "staleX", nil, nil, "butler",
      "do the thing", nil, nil, nil)
  ]])
  local result = T.eval([[
    local t = remuda._stale_t
    local report = t.replacement_effects("staleX")
    local text = t.reports[#t.reports] or ""
    t.restore()
    return report .. "\n" .. text
  ]])
  local fields, text = result:match("^(.-)\n(.*)$")
  local id, child, native, token, task, seeded, roster, probe, failure =
    fields:match("^(.-)|(%a+)|(.-)|(.-)|(.-)|(.-)|(%d+)|(%a+)|(.-)$")
  T.eq(id, "replacement-id", result)
  T.eq(child, "false", result)
  T.eq(native, "nil", result)
  T.eq(token, "nil", result)
  T.eq(task, "nil", result)
  T.eq(seeded, "nil", result)
  T.eq(roster, "0", result)
  T.eq(probe, "true", result)
  T.eq(failure, "launch replaced during native identity lookup", result)
  T.ok(text:find("was saved to your inbox", 1, true) ~= nil, text)
  T.ok(text:find("could NOT be saved", 1, true) == nil, text)
  T.ok(text:find("left untouched", 1, true) ~= nil, text)
end)

T.test("a failed durable keep is reported, never claimed", function()
  T.eval([[
    local t = remuda._stale_t
    t.install()
    t.parent_id = remuda._butler_bus.agents.butler.id
    -- A parent with no Butler ULID makes the durable write fail closed.
    remuda._butler_bus.agents.butler.id = ""
    remuda._butler_launch_impl.launch_agent("codex", "staleY", nil, nil, "butler",
      "do the failing thing", nil, nil, nil)
    remuda._butler_bus.agents.butler.id = t.parent_id
  ]])
  local result = T.eval([[
    local t = remuda._stale_t
    local report = t.replacement_effects("staleY")
    local text = t.reports[#t.reports] or ""
    t.restore()
    return report .. "\n" .. text
  ]])
  local fields, text = result:match("^(.-)\n(.*)$")
  local id, child, native, token, task, seeded, roster, probe, failure =
    fields:match("^(.-)|(%a+)|(.-)|(.-)|(.-)|(.-)|(%d+)|(%a+)|(.-)$")
  T.eq(id, "replacement-id", result)
  T.eq(child, "false", result)
  T.eq(native, "nil", result)
  T.eq(token, "nil", result)
  T.eq(task, "nil", result)
  T.eq(seeded, "nil", result)
  T.eq(roster, "0", result)
  T.eq(probe, "true", result)
  T.eq(failure, "launch replaced during native identity lookup", result)
  T.ok(text:find("could NOT be saved", 1, true) ~= nil, text)
  T.ok(text:find("recipient has no Butler ULID", 1, true) ~= nil, text)
  T.ok(text:find("was saved to your inbox", 1, true) == nil, text)
end)
