-- The structured team producer (#941). Run from the repo root:
--   luajit tests/session_team.lua
--
-- The fixture uses the real sessions.lua and a fake core setter that enforces
-- the same instance boundary: a write is accepted only for the live instance
-- the producer named, so stale metadata can never be published. The setter is
-- only ever reached through the producer, never called by the test.

local bus = { agents = {}, identities = {}, tokens = {}, close_requested = {} }
local remuda = {
  _butler_sessions_config = {
    bus = bus,
    mail = { unread = function() return 0 end },
    json_field = function() return nil end,
    registered_agent_kind = function() return nil end,
    call_callback = function(fn, ...) return pcall(fn, remuda, ...) end,
    load_status_detector = function() error("no status detectors in this fixture") end,
  },
  _butler_sandbox = { of = function() return nil end, summary = function() return nil end },
}
_G.remuda = remuda

local now = 100
remuda.clock = function() return now end
local models = {}
remuda._butler_telemetry_for = function(agent)
  return { model = models[agent] or agent.model or "?" }
end

local live = {} -- name -> the instance the daemon currently holds
local calls = {}
remuda.session = {
  team = function(name, instance, team)
    calls[#calls + 1] = {
      name = name, instance = instance, team = team, ok = live[name] == instance,
    }
    if live[name] ~= instance then return nil, "stale session instance" end
    return true
  end,
}

dofile("packages/butler/sessions.lua")

local function agent(name, kind, instance, parent, model, id)
  local row = {
    id = id or ("id-" .. name),
    alias = name, session_name = name, kind = kind, parent = parent,
    instance_id = instance, instance_binding = instance and 1 or nil,
    children = {}, model = model,
  }
  row.parent_id = parent and bus.agents[parent] and bus.agents[parent].id or nil
  bus.agents[name] = row
  if instance then live[name] = instance end
  if parent and bus.agents[parent] then
    local children = bus.agents[parent].children
    children[#children + 1] = name
  end
  return row
end

local function last_call(name)
  for index = #calls, 1, -1 do
    if calls[index].name == name then return calls[index] end
  end
end
local function check(got, want, what)
  assert(got == want, what .. ": expected " .. tostring(want) .. ", got " .. tostring(got))
end

agent("butler", "claude", "i-root", nil, "opus")
agent("lead", "codex", "i-lead", "butler", "gpt-6.1")
agent("worker", "codex", "i-worker", "lead")
agent("orphan", "claude", "i-orphan", "gone")
agent("unbound", "codex", nil, "butler", "gpt-6.1")

remuda._butler_sync_team(true)

local root = last_call("butler")
check(root.team.agent_kind, "claude", "root kind")
check(root.team.model, "opus", "root model")
check(root.team.depth, 0, "root depth")
check(root.team.leader, nil, "root has no leader")

local lead = last_call("lead")
check(lead.team.depth, 1, "lead depth")
check(lead.team.leader.name, "butler", "lead leader name")
check(lead.team.leader.instance_id, "i-root", "lead leader instance")

local worker = last_call("worker")
check(worker.team.depth, 2, "worker depth")
check(worker.team.leader.instance_id, "i-lead", "worker leader instance")

local orphan = last_call("orphan")
check(orphan.team.depth, 0, "orphan depth")
check(orphan.team.leader, nil, "an absent leader is omitted, not invented")
check(last_call("unbound"), nil, "an unbound agent has no instance to write")

-- A parent that is still named but has no bound instance also omits the leader.
agent("unbound-leader", "claude", nil, nil)
bus.agents.worker.parent = "unbound-leader"
bus.agents.worker.parent_id = bus.agents["unbound-leader"].id
remuda._butler_sync_team(true)
worker = last_call("worker")
check(worker.team.leader, nil, "a leader without an instance is omitted")
check(worker.team.depth, 1, "the rest of the team survives an unknown leader")

-- Reparenting is a roster event, so the next force sync rewrites the relation.
bus.agents.worker.parent = "butler"
bus.agents.worker.parent_id = bus.agents.butler.id
remuda._butler_sync_team(true)
worker = last_call("worker")
check(worker.team.leader.instance_id, "i-root", "reparented worker follows its new leader")
check(worker.team.depth, 1, "reparented worker is one step from the root")

-- Back under its original lead for the replacement case.
bus.agents.worker.parent = "lead"
bus.agents.worker.parent_id = bus.agents.lead.id
remuda._butler_sync_team(true)
check(last_call("worker").team.leader.instance_id, "i-lead", "worker returns under its lead")

-- A model change has no roster event; the throttled reconcile sync refreshes it.
models[bus.agents.worker] = "gpt-6.2"
now = now + 10
remuda._butler_sync_team()
check(last_call("worker").team.model, "gpt-6.2", "model change is refreshed")

-- A replaced instance is not silently kept: the old instance is attempted as a
-- clear and the new instance is written under its own id.
bus.agents.lead.instance_id = "i-lead-2"
live.lead = "i-lead-2"
remuda._butler_sync_team(true)
check(last_call("lead").instance, "i-lead-2", "replaced instance is rewritten")
check(last_call("worker").team.leader.instance_id, "i-lead-2", "worker follows the new instance")

-- Exit: adoption moves the child to the root and the producer drops the dead
-- instance (the daemon's registry already refuses the old id).
local exited = bus.agents.lead
bus.agents.lead = nil
live.lead = nil
remuda._butler_adopt_members("lead", exited)
worker = last_call("worker")
check(worker.team.leader.name, "butler", "adoption reparents the child")
check(worker.team.leader.instance_id, "i-root", "adopted child follows the root instance")
local lead_clear = last_call("lead")
check(lead_clear.team, nil, "the exited instance is cleared, not left with an old relation")
check(lead_clear.ok, false, "the fake core refuses an exited instance")

-- Alias reuse: a new incarnation under the same parent name is not the leader
-- of a child whose recorded generation names the old identity.
agent("reuse-lead", "codex", "i-reuse-old", "butler", nil, "id-reuse-old")
agent("reuse-child", "codex", "i-reuse-child", "reuse-lead")
remuda._butler_sync_team(true)
check(last_call("reuse-child").team.leader.instance_id, "i-reuse-old", "original leader")
agent("reuse-lead", "codex", "i-reuse-new", "butler", nil, "id-reuse-new")
remuda._butler_sync_team(true)
check(last_call("reuse-child").team.leader, nil, "a reused parent alias is not a leader")

-- A parent whose binding is unknown cannot be a leader, even when the
-- recorded generation id still matches.
agent("loose-lead", "claude", "i-loose", nil, nil, "id-loose")
agent("loose-child", "claude", "i-loose-child", "loose-lead")
bus.agents["loose-lead"].instance_binding = nil
remuda._butler_sync_team(true)
check(last_call("loose-child").team.leader, nil, "a leader without a binding is omitted")

-- A child with no recorded generation is uncertain: do not guess from the
-- current alias occupant.
agent("nil-lead", "claude", "i-nil-lead", nil, nil, "id-nil-lead")
agent("nil-child", "claude", "i-nil-child", "nil-lead")
bus.agents["nil-child"].parent_id = nil
remuda._butler_sync_team(true)
check(last_call("nil-child").team.leader, nil, "an unknown parent generation is omitted")

-- Depth is bounded like the view policy: deeper relations clamp to the contract
-- limit instead of failing the whole write.
agent("deep0", "claude", "i-deep0", nil)
local parent = "deep0"
for index = 1, 21 do
  local name = "deep" .. index
  agent(name, "claude", "i-" .. name, parent)
  parent = name
end
remuda._butler_sync_team(true)
check(last_call("deep21").team.depth, 20, "depth is clamped to the contract limit")

-- Without a core setter (an older core) the producer is a no-op, not an error.
remuda.session.team = nil
remuda._butler_sync_team(true)

print("ok - structured team metadata is instance-bound, refreshed and cleaned up")
