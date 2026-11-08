-- Owner-side runtime contract for the automatic session display publisher.
-- No daemon: a fake setter records exactly what the publisher would send.
local now_wall = 1000
local now_ms = 5000
local telemetry = {}

local bus = { agents = {
  butler = { id = "ROOT", kind = "codex", session_name = "butler", alias = "butler",
    instance_id = "i-root", instance_binding = 1, model = "configured-model" },
  child = { id = "CHILD", kind = "codex", session_name = "child", alias = "child",
    instance_id = "i-child", instance_binding = 1, parent = "butler", parent_id = "ROOT",
    model = "child-model" },
  unbound = { id = "UNBOUND", kind = "codex", session_name = "unbound",
    instance_id = "i-unbound", model = "unbound-model" },
} }

local published, cleared = {}, {}
remuda = {
  _butler_session_display_config = {
    bus = bus,
    now = function() return now_wall end,
    clock = function() return now_ms end,
  },
  session = {
    set_display = function(name, instance, facts)
      if facts == nil then
        cleared[#cleared + 1] = name .. ":" .. instance
        if published[name] and published[name].instance == instance then published[name] = nil end
        return true
      end
      for key in pairs(facts) do
        assert(key ~= "task" and key ~= "path" and key ~= "mail" and key ~= "cwd",
          "publisher leaked private field " .. key)
      end
      published[name] = { instance = instance, facts = facts }
      return true
    end,
  },
  _butler_telemetry_for = function(agent) return telemetry[agent.id] or {} end,
}

dofile("packages/butler/session_display.lua")
local display = assert(remuda._butler_session_display)
local function tick() display.tick() end

-- Automatic first tick: no enable flag and no prior publication.
telemetry = {
  ROOT = { model = "telemetry-model", context_used = 42000, context_window = 100000,
    context_percent = 42, observed_at = now_wall },
  CHILD = { model = "child-telemetry", context_used = 0, context_window = 100000,
    context_percent = 0, observed_at = now_wall },
}
tick()
assert(published.butler, "root member was not published on the first tick")
assert(published.butler.facts.member_id == "ROOT", "member_id missing")
assert(published.butler.facts.leader_id == nil, "root must not publish a leader")
assert(published.child, "child member was not published")
assert(published.child.facts.leader_id == "ROOT", "leader_id missing or not durable")
assert(published.child.facts.alias == "child", "alias missing")
assert(published.child.facts.kind == "codex", "kind missing")
assert(published.child.facts.model == "child-telemetry", "telemetry model missing")
assert(published.child.facts.context_used == 0 and published.child.facts.context_percent == 0,
  "fresh zero context must stay a value")
assert(published.unbound == nil, "an unbound member must not be published")

-- A rebound name clears the old instance and publishes only the new one.
bus.agents.child.instance_id = "i-child-2"
tick()
assert(cleared[#cleared] == "child:i-child", "rebound instance was not cleared")
assert(published.child.instance == "i-child-2", "new instance was not published")

-- A stale observation keeps the configured model but drops context values.
telemetry.CHILD = { model = "stale-model", context_used = 42000, context_window = 100000,
  context_percent = 42, observed_at = now_wall - 61 }
tick()
assert(published.child.facts.model == "child-model", "configured model should survive stale telemetry")
assert(published.child.facts.context_used == nil, "stale context must not be published")
assert(published.child.facts.context_percent == nil, "stale percent must not be published")

-- Stop clears every publication.
display.stop()
assert(published.butler == nil and published.child == nil, "stop left a publication")
assert(#cleared >= 2, "stop did not clear both instances")

-- An older core without the setter is a silent no-op, not an error.
remuda.session = nil
tick()
assert(display.tick ~= nil)
print("PASS automatic publisher, exact durable IDs, bounded telemetry, rebound clear and stop")
