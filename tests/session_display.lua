-- Pure publisher contract; no daemon or live Butler state.
local enabled, wall, clock = false, 1000, 0
local calls, fail_clear, result = {}, false, true
local agent = { id = "member-id", alias = "worker", session_name = "wire-worker",
  instance_id = "instance-1", instance_binding = 1, kind = "codex", model = "configured",
  parent = "lead", parent_id = "lead-id" }
local bus = { agents = { worker = agent, lead = { id = "lead-id", alias = "lead" } } }
local telemetry = { model = "observed", observed_at = 1000, context_used = 42,
  context_window = 100, context_percent = 42 }
remuda = {
  _butler_session_display_config = { bus = bus, enabled = function() return enabled end,
    now = function() return wall end, clock = function() return clock end },
  _butler_telemetry_for = function() return telemetry end,
  session = { set_display = function(name, instance, facts)
    if facts == nil and fail_clear then return false end
    calls[#calls + 1] = { name = name, instance = instance, facts = facts }
    return result
  end },
}
dofile("packages/butler/session_display.lua")
local publisher = remuda._butler_session_display
publisher.tick()
assert(#calls == 0, "default opt-out publishes nothing")
enabled = true
publisher.tick()
local row = calls[#calls]
assert(row.name == "wire-worker" and row.instance == "instance-1")
assert(row.facts.leader == "lead" and row.facts.kind == "codex")
assert(row.facts.model == "observed" and row.facts.context_percent == 42)
for _, field in ipairs({ "task", "cwd", "status_path", "token", "member_id", "leader_id" }) do
  assert(row.facts[field] == nil, "private field was published: " .. field)
end
-- Parent aliases alone do not establish a relationship after reuse.
bus.agents.lead.id = "replacement-id"
publisher.tick()
assert(calls[#calls].facts.leader == nil)
-- Expire source telemetry, then roll wall clock back and replay A -> B -> A.
clock = 61000
publisher.tick()
assert(calls[#calls].facts.model == "configured" and calls[#calls].facts.context_percent == nil)
wall = 1000
telemetry.observed_at = 999
publisher.tick()
telemetry.observed_at = 1000
publisher.tick()
assert(calls[#calls].facts.context_percent == nil, "rollback/replay revived stale observation")
-- Fresh new source sample, impossible/unknown readings omitted honestly.
telemetry = { observed_at = 1061, model = "new-model", context_percent = 0, context_used = 0, context_window = 100 }
publisher.tick()
assert(calls[#calls].facts.context_percent == 0, "observed zero is not missing")
telemetry.context_window = 0
publisher.tick()
assert(calls[#calls].facts.context_percent == nil)
telemetry.context_used, telemetry.context_window, telemetry.context_percent = 101, 100, 101
publisher.tick()
assert(calls[#calls].facts.context_used == nil and calls[#calls].facts.context_percent == nil)
telemetry.context_percent = math.huge
publisher.tick()
assert(calls[#calls].facts.context_percent == nil)
-- Opt-out retries failed revocation. It never silently re-enables publication.
enabled, fail_clear = false, true
local before = #calls
publisher.tick()
assert(#calls == before)
fail_clear = false
publisher.tick()
assert(calls[#calls].facts == nil)
before = #calls
publisher.tick()
assert(#calls == before)
-- Exception and false/nil setter results are not successful publications.
enabled, result = true, false
publisher.tick()
enabled, result = false, true
before = #calls
publisher.tick()
assert(#calls == before)
-- Replacement retains new instance bookkeeping even when old clear rejects.
enabled = true
publisher.tick()
agent.instance_id = "instance-2"
publisher.tick()
publisher.stop()
assert(calls[#calls].instance == "instance-2" and calls[#calls].facts == nil)
-- Old core feature-detects without calling any Lua/Eval fallback.
remuda.session.set_display = nil
publisher.tick()
publisher.stop()
print("session display publisher: ok")
