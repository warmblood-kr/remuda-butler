-- Instance binding (PR B) admission modes, with a fake core. Run from the repo root:
--   luajit tests/butler_instance_binding_modes.lua
-- Enforcing = the core's `_caller_live` was present at load AND the agent is bound. Otherwise legacy-visible
-- (today's checks, no isolation claim). The strict switch refuses everything that is not enforced.
-- Every refusal must leave the bus untouched.
-- A bound row as a PR B launch leaves it: the id came from the remuda.new return (provenance marker).
local function proven(row) row.instance_binding = 1; return row end
local function load(live)
  local bus = { agents = {}, tokens = {}, identity_ids = {}, identities = {}, messages = {}, next = 0, incarnation = "T" }
  bus.agents.bound = proven({ id = "01ABCDEF0123456789ABCDEFGH", alias = "bound", session_name = "s-bound", kind = "codex", instance_id = "I-BOUND" })
  bus.agents.unbound = { id = "01ABCDEF0123456789ABCDEFGJ", alias = "unbound", session_name = "s-unbound", kind = "codex" }
  for alias, agent in pairs(bus.agents) do bus.identity_ids[agent.id] = { id = agent.id, alias = alias, state = "running" } end
  remuda = {
    _caller_live = live,
    _butler_system = {},
    _butler_caller_principal_config = { bus = bus },
    butler = { guard_policy = { append = function() return true end } },
  }
  dofile("packages/butler/caller_principal.lua")
  remuda._butler_identity_config = { bus = bus, current_agent = remuda._butler_caller_principal.current_agent,
    json_quote = function(v) return string.format("%q", v) end }
  dofile("packages/butler/identity.lua")
  return bus, remuda._butler_identity
end
local failed = {}
local function section(name, fn)
  local ok, err = pcall(fn)
  if not ok then failed[#failed + 1] = name .. ": " .. tostring(err) end
end
local function snapshot(bus) return bus.next .. ":" .. #bus.messages end
local function session(name, instance) return { kind = "session", session = "s-" .. name, instance_id = instance } end
local function admitted(identity, caller) local ok, who = pcall(identity.caller_agent, caller); return ok and who or nil end

-- Old core (no _caller_live): legacy-visible by default, but the native session branch still needs an instance id.
section('old_core', function()
  local bus, identity = load(nil)
  local before = snapshot(bus)
  assert(admitted(identity, session("unbound", "ANY")) == "unbound", "old core: legacy access by name is kept")
  assert(admitted(identity, session("bound", "I-BOUND")) == "bound")
  assert(admitted(identity, session("unbound", nil)) == nil, "old core: a session snapshot without an instance id is refused")
  assert(admitted(identity, session("bound", nil)) == nil)
  assert(snapshot(bus) == before)
end)
section('old_core_strict', function()
  local bus, identity = load(nil)
  local before = snapshot(bus)
  -- strict switch (Lua override): nothing is enforced on this core, so everything is refused
  remuda._butler_strict_instance_binding = true
  assert(admitted(identity, session("unbound", "ANY")) == nil and admitted(identity, session("bound", "I-BOUND")) == nil,
    "strict: an old core refuses every protected route")
  assert(not pcall(identity.caller_leader, session("bound", "I-BOUND")))
  assert(snapshot(bus) == before)
  remuda._butler_strict_instance_binding = false
  assert(admitted(identity, session("unbound", "ANY")) == "unbound", "strict off: legacy access returns")
end)

-- Middle core (_caller_live present, new returns only the name): members are unbound, hence legacy-visible.
section('middle_core', function()
  local calls = 0
  local bus, identity = load(function() calls = calls + 1; return true end)
  assert(admitted(identity, session("unbound", "ANY")) == "unbound", "unbound member on a middle core is legacy-visible")
  assert(calls == 0, "an unbound member is not enforced: no liveness call")
  remuda._butler_strict_instance_binding = true
  assert(admitted(identity, session("unbound", "ANY")) == nil, "strict refuses an unbound member even when the core can enforce")
end)

-- Enforcing core, bound member: the BOUND id is passed to _caller_live on mutating routes, and any raise refuses.
section('enforcing_core', function()
  local seen, live = {}, true
  local bus, identity = load(function(name, id)
    seen[#seen + 1] = tostring(name) .. "/" .. tostring(id)
    if live ~= true then error(live, 0) end
    return true
  end)
  local before = snapshot(bus)
  assert(admitted(identity, session("bound", "I-BOUND")) == "bound")
  assert(seen[#seen] == "s-bound/I-BOUND", "caller_agent must ask the core about the bound instance, got " .. tostring(seen[#seen]))
  local n = #seen
  assert(select(2, pcall(identity.caller_leader, session("bound", "I-BOUND"))) == "bound")
  assert(#seen == n + 1, "caller_leader is a mutating route too")
  assert(admitted(identity, session("bound", "I-OTHER")) == nil, "a snapshot of another instance is refused")
  live = "InstanceChanged"
  assert(admitted(identity, session("bound", "I-BOUND")) == nil, "a raising _caller_live refuses")
  assert(not pcall(identity.caller_leader, session("bound", "I-BOUND")))
  assert(snapshot(bus) == before, "refusals have zero effects")
  -- captured at load: later Lua cannot swap the check
  live = true
  remuda._caller_live = function() error("swapped", 0) end
  assert(admitted(identity, session("bound", "I-BOUND")) == "bound", "the load-time _caller_live is used, not a later replacement")
end)
-- The environment switch: REMUDA_BUTLER_STRICT_INSTANCE_BINDING=1 alone turns strict on (no Lua override set).
section('env_strict', function()
  local ffi = require("ffi")
  ffi.cdef("int setenv(const char *, const char *, int); int unsetenv(const char *);")
  local name = "REMUDA_BUTLER_STRICT_INSTANCE_BINDING"
  local ok, err = pcall(function()
    local _, identity = load(nil)
    assert(admitted(identity, session("unbound", "ANY")) == "unbound", "env unset: legacy access")
    ffi.C.setenv(name, "1", 1)
    assert(admitted(identity, session("unbound", "ANY")) == nil, "env =1: an unenforced member is refused")
    ffi.C.setenv(name, "0", 1)
    assert(admitted(identity, session("unbound", "ANY")) == "unbound", "env other than 1: not strict")
  end)
  ffi.C.unsetenv(name)
  assert(ok, err)
end)
if #failed > 0 then error(#failed .. " section(s) failed:\n" .. table.concat(failed, "\n"), 0) end
print("ok")
