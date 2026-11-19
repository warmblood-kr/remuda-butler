-- Explicit replacement of an unreachable Butler session (recovery).
-- Design and limits: docs/concepts/butler-session-recovery.md.
--
-- Pure: the caller passes the registry rows, the roster rows and the operator's
-- declaration; this module decides whether that exact instance may be replaced
-- and renders the plan. It never kills, starts, reads or writes anything.
--
-- Three rules carry the safety, and none of them is a liveness claim:
--   1. the operator names the exact instance id (the fence). A row that carries
--      no instance id is refused, never guessed, so a name reused by a live
--      session can never be the target of the previous operator's decision;
--   2. the operator must declare the session unreachable. Core `remuda.ls` does
--      not expose the registry's `unavailable` flag, so Butler cannot prove a
--      session is broken and must not pretend to;
--   3. the replacement keeps the SAME logical identity (alias, ULID, memory,
--      mailbox) and is rebuilt only from durable roster fields. No environment
--      value is copied or persisted, so no secret travels through the plan.

local M = {}
M.VERSION = 1

local function refuse(code, text) return { code = code, text = text } end
M.refuse = refuse

-- Every registry row for this name. After a crash the same name can appear
-- twice; a duplicate is not a target, it is a stop: the operator must resolve
-- which row they mean first.
function M.rows_for(rows, name)
  local found = {}
  for _, row in ipairs(rows or {}) do
    if type(row) == "table" and row.name == name then found[#found + 1] = row end
  end
  return found
end

-- The one roster row for this alias, or nil. A roster is a snapshot: several
-- rows for one alias mean somebody wrote it by hand, and we refuse rather than
-- pick.
function M.roster_row(roster_rows, alias)
  local found
  for _, row in ipairs(roster_rows or {}) do
    if type(row) == "table" and row.alias == alias then
      if found then return nil, "duplicate roster rows" end
      found = row
    end
  end
  return found
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

local function team_text(row)
  local team = type(row.team) == "table" and row.team or {}
  local kind = team.agent_kind or "?"
  local model = team.model and ("/" .. team.model) or ""
  return kind .. model
end

-- input = {
--   name, instance_id,          -- the operator's target (both required)
--   unreachable = true,         -- the operator's declaration, never inferred
--   rows,                       -- remuda.ls()
--   roster,                     -- roster.load() rows
--   caller,                     -- the calling alias, for the self check
--   workdir, agent, model,      -- optional explicit replacements
-- }
-- Returns plan, nil on success; nil, refusal { code, text } otherwise.
function M.decide(input)
  input = type(input) == "table" and input or {}
  local name = input.name
  if not nonempty(name) then
    return nil, refuse("usage", "name a session: remuda butler replace NAME --instance ID --unreachable")
  end
  if name:find("/", 1, true) or name:find("%s") then
    return nil, refuse("bad_name", "session names never contain a slash or whitespace: " .. tostring(name))
  end
  local rows = M.rows_for(input.rows, name)
  if #rows == 0 then
    return nil, refuse("no_session", "no session named " .. name .. " in the registry")
  end
  if #rows > 1 then
    return nil, refuse("duplicate_rows", (#rows) .. " registry rows carry the name " .. name
      .. "; resolve the duplicate before replacing anything")
  end
  local row = rows[1]
  local wanted = input.instance_id
  if not nonempty(wanted) then
    return nil, refuse("instance_required",
      "the exact instance id is required (--instance ID); a name alone cannot fence a replacement")
  end
  if not nonempty(row.instance_id) then
    return nil, refuse("unfenceable",
      name .. " has no instance id in the registry, so the exact instance cannot be named")
  end
  if row.instance_id ~= wanted then
    return nil, refuse("instance_mismatch",
      name .. " runs as instance " .. row.instance_id .. ", not " .. wanted
        .. "; refusing to replace a session the operator did not name")
  end
  if input.unreachable ~= true then
    return nil, refuse("declaration_required",
      "declare --unreachable: the registry does not prove a session is broken,"
        .. " and a working session must be closed, not replaced")
  end
  if input.caller and input.caller == name then
    return nil, refuse("self_target",
      "refusing to replace the session that asked: run this from another session or the CLI")
  end
  local roster, dup = M.roster_row(input.roster, name) -- luacheck: ignore
  if dup then
    return nil, refuse("roster_duplicate", "roster.json carries more than one row for " .. name)
  end
  if not roster then
    return nil, refuse("roster_missing",
      "no durable roster row for " .. name .. ", so the replacement cannot be rebuilt"
        .. " from what Butler recorded")
  end
  if not nonempty(roster.id) then
    return nil, refuse("roster_identity_missing", "the roster row for " .. name .. " carries no agent id")
  end
  if roster.instance_id ~= row.instance_id then
    return nil, refuse("roster_mismatch",
      "the roster binds " .. name .. " to instance " .. tostring(roster.instance_id)
        .. ", the registry to " .. row.instance_id .. "; refusing to rebuild from a stale binding")
  end
  local workdir = nonempty(input.workdir) and input.workdir or roster.cwd
  if not nonempty(workdir) then
    return nil, refuse("workdir_missing",
      "the roster row for " .. name .. " carries no working directory; pass --workdir DIR")
  end
  local kind = nonempty(input.agent) and input.agent or roster.kind
  if not nonempty(kind) then
    return nil, refuse("agent_missing",
      "the roster row for " .. name .. " carries no agent kind; pass --agent KIND")
  end
  local model = nonempty(input.model) and input.model or roster.model
  return {
    version = M.VERSION,
    name = name,
    instance_id = row.instance_id,
    registry_alive = row.alive == true,
    registry_team = team_text(row),
    declared_unreachable = true,
    alias = name,
    id = roster.id,
    session_name = roster.session_name or name,
    agent = kind,
    model = model,
    cwd = workdir,
    writable = roster.writable,
    sandbox = roster.sandbox,
    leader = roster.parent,
    leader_id = roster.parent_id,
    overrides = {
      workdir = nonempty(input.workdir),
      agent = nonempty(input.agent),
      model = nonempty(input.model),
    },
  }
end

-- The losses are fixed by the architecture, not by this command: the old
-- screen and scrollback are the host's only copy, a killed child loses its
-- memory, and nothing here can restore either.
function M.render(plan)
  local out = {}
  local function line(text) out[#out + 1] = text end
  line(('Replace "%s" (explicit; the old instance is not proven dead)'):format(plan.name))
  line("")
  line("Target")
  line("  name      " .. plan.name)
  line("  instance  " .. plan.instance_id)
  line(("  registry  alive=%s, team=%s"):format(tostring(plan.registry_alive), plan.registry_team))
  line("  declared  unreachable by the operator; the core does not report it")
  line("")
  line("Replacement (not started)")
  line("  alias     " .. plan.alias .. " (logical identity preserved)")
  line("  id        " .. plan.id)
  line("  name      " .. plan.session_name)
  line(("  agent     %s%s"):format(plan.agent,
    plan.model and (" (" .. plan.model .. ")") or ""))
  line("  cwd       " .. plan.cwd)
  line("  leader    " .. (plan.leader and (plan.leader .. (plan.leader_id and (" (" .. plan.leader_id .. ")") or ""))
    or "(none: this is the root)"))
  if plan.writable and #plan.writable > 0 then
    line("  writable  " .. table.concat(plan.writable, ", "))
  end
  line("  memory    unchanged (keyed to the logical alias; no copy)")
  line("  mail      unchanged (same alias and id; undelivered mail stays unread)")
  line("")
  line("Losses")
  line("  the old screen and scrollback; child process memory; anything not on disk")
  line("")
  line("Not done by this command")
  line("  no kill and no launch: --apply needs an instance-fenced kill in the core")
  line("  (`remuda.close` takes no instance and does not retire a poisoned host's row).")
  return table.concat(out, "\n")
end

-- Export through the image when loaded by the daemon; the pure unit test loads
-- this file with no `remuda` global and must keep working.
if type(remuda) == "table" then remuda._butler_session_recovery = M end

return M
