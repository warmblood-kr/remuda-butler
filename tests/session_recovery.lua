-- Pure unit tests for the explicit session replacement decision.
-- Run from the repository root: luajit tests/session_recovery.lua
local M = assert(loadfile("packages/butler/session_recovery.lua"))()

local passed = 0
local function ok(condition, message)
  if not condition then error("FAIL: " .. message, 2) end
  passed = passed + 1
end
local function eq(actual, expected, message)
  if actual ~= expected then
    error("FAIL: " .. message .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
  passed = passed + 1
end
local function refuses(code, input, message)
  local plan, why = M.decide(input)
  ok(plan == nil, message .. ": expected a refusal")
  eq(why and why.code, code, message .. ": refusal code")
  ok(type(why and why.text) == "string" and #why.text > 0, message .. ": refusal text")
  return why
end

local function row(over)
  local value = { name = "butler", instance_id = "inst-1", alive = true,
    team = { agent_kind = "codex", model = "gpt-6.1-terra" } }
  for key, item in pairs(over or {}) do value[key] = item end
  return value
end
local function roster(over)
  local value = { alias = "butler", id = "01JROOTULID0000000000000", kind = "codex",
    model = "gpt-6.1-terra", cwd = "/home/owner/project", session_name = "butler",
    instance_id = "inst-1" }
  for key, item in pairs(over or {}) do value[key] = item end
  return value
end
local function without(value, key)
  local copy = {}
  for k, item in pairs(value) do if k ~= key then copy[k] = item end end
  return copy
end
local function input(over)
  local value = { name = "butler", instance_id = "inst-1", unreachable = true,
    rows = { row() }, roster = { roster() } }
  for key, item in pairs(over or {}) do value[key] = item end
  return value
end

-- The happy path: exact instance, declared unreachable, rebuildable roster.
local plan = assert(M.decide(input()))
eq(plan.name, "butler", "target name")
eq(plan.instance_id, "inst-1", "target instance")
eq(plan.id, "01JROOTULID0000000000000", "the logical id is reused, not minted")
eq(plan.alias, "butler", "the logical alias is unchanged")
eq(plan.agent, "codex", "agent kind from the roster")
eq(plan.model, "gpt-6.1-terra", "model from the roster")
eq(plan.cwd, "/home/owner/project", "workdir from the roster")
eq(plan.declared_unreachable, true, "the operator's declaration is recorded")
eq(plan.registry_alive, true, "the registry's alive flag is reported, not trusted")
eq(plan.registry_team, "codex/gpt-6.1-terra", "the registry team is shown")

-- A target that is not in the registry cannot be replaced.
refuses("no_session", input({ rows = {} }), "absent session")
refuses("no_session", input({ name = "other" }), "different name")

-- A duplicate name is a stop, never a pick.
refuses("duplicate_rows", input({ rows = { row(), row({ instance_id = "inst-2" }) } }),
  "two rows for one name")

-- The fence: the operator must name an exact instance.
refuses("instance_required", without(input(), "instance_id"), "no instance given")
refuses("instance_required", input({ instance_id = "" }), "empty instance")
refuses("unfenceable", input({ rows = { without(row(), "instance_id") } }),
  "a row with no instance id")
refuses("instance_mismatch", input({ instance_id = "inst-2" }),
  "a different instance than the row")

-- The declaration: Butler cannot prove a session is broken, so it must not infer it.
refuses("declaration_required", without(input(), "unreachable"), "no declaration")
refuses("declaration_required", input({ unreachable = false }), "declined declaration")

-- Never replace the caller's own session.
refuses("self_target", input({ caller = "butler" }), "the caller replaces itself")
eq(assert(M.decide(input({ caller = "worker" }))).name, "butler",
  "another caller may replace butler")

-- Rebuild needs a durable roster row bound to the same instance.
refuses("roster_missing", input({ roster = {} }), "no roster row")
refuses("roster_duplicate", input({ roster = { roster(), roster() } }), "two roster rows")
refuses("roster_identity_missing", input({ roster = { roster({ id = "" }) } }),
  "roster row without an id")
refuses("roster_mismatch", input({ roster = { roster({ instance_id = "inst-0" }) } }),
  "roster bound to another instance")
refuses("roster_mismatch", input({ roster = { without(roster(), "instance_id") } }),
  "roster row without a binding")

-- The replacement cannot be invented: workdir and agent must come from somewhere.
refuses("workdir_missing", input({ roster = { without(roster(), "cwd") } }), "no workdir")
refuses("agent_missing", input({ roster = { without(roster(), "kind") } }), "no agent kind")
eq(assert(M.decide(input({ roster = { without(roster(), "cwd") }, workdir = "/srv/x" }))).cwd,
  "/srv/x", "an explicit --workdir stands in for a missing roster cwd")
eq(assert(M.decide(input({ roster = { without(roster(), "kind") }, agent = "claude" }))).agent,
  "claude", "an explicit --agent stands in for a missing roster kind")

-- Explicit overrides win over the roster, and are marked as such.
local overridden = assert(M.decide(input({ workdir = "/srv/y", agent = "claude", model = "m2" })))
eq(overridden.cwd, "/srv/y", "workdir override")
eq(overridden.agent, "claude", "agent override")
eq(overridden.model, "m2", "model override")
eq(overridden.overrides.workdir, true, "the workdir override is recorded")
eq(overridden.overrides.agent, true, "the agent override is recorded")

-- A member keeps its leader; the root has none.
local member = assert(M.decide(input({ name = "worker", instance_id = "inst-1",
  rows = { row({ name = "worker" }) },
  roster = { roster({ alias = "worker", session_name = "worker", parent = "butler",
    parent_id = "01JROOTULID0000000000000" }) } })))
eq(member.leader, "butler", "a member keeps its leader alias")
eq(member.leader_id, "01JROOTULID0000000000000", "a member keeps its leader id")
eq(assert(M.decide(input())).leader, nil, "the root has no leader")

-- Names never carry a slash or whitespace.
refuses("bad_name", input({ name = "a/b" }), "a name with a slash")
refuses("bad_name", input({ name = "a b" }), "a name with whitespace")
refuses("usage", without(input(), "name"), "no name")

-- The rendered plan states the target, the identity it reuses, the losses and
-- the fact that it kills nothing.
local text = M.render(plan)
ok(text:find('Replace "butler"', 1, true) ~= nil, "plan names the target")
ok(text:find("explicit; the old instance is not proven dead", 1, true) ~= nil,
  "the plan does not claim the old instance is dead")
ok(text:find("instance  inst-1", 1, true) ~= nil, "plan carries the instance fence")
ok(text:find("01JROOTULID0000000000000", 1, true) ~= nil, "plan shows the reused id")
ok(text:find("memory    unchanged", 1, true) ~= nil, "plan says memory is unchanged")
ok(text:find("mail      unchanged", 1, true) ~= nil, "plan says mail is unchanged")
ok(text:find("screen and scrollback", 1, true) ~= nil, "plan names the real losses")
ok(text:find("no kill and no launch", 1, true) ~= nil, "plan performs nothing")
ok(text:find("inst-1", 1, true) ~= nil, "the instance appears once as the target")

-- The same plan renders identically twice: it is text, not a probe.
eq(M.render(plan), text, "rendering is deterministic")
ok(M.VERSION == 1, "plan version")

print(("PASS tests/session_recovery.lua (%d assertions)"):format(passed))
