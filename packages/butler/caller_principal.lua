-- Resolve CLI caller identity from the core's daemon-derived kind/session only.
local config = assert(remuda._butler_caller_principal_config)
local bus = assert(config.bus)

local M = {}
local OUTSIDE_POLICY = "outside_is_operator_transitional"
-- Captured once at load so later Lua cannot swap them (advisory only: same-user Lua is not isolated).
local caller_live = remuda._caller_live
M.caller = remuda.caller
-- Instance binding: a member launched through a core that returns the instance id (#654) is bound to
-- that id. Admission compares the snapshot's id and asks the core (observed-death admission; core
-- close/alive stay name-based). Unbound members, or a core without `_caller_live`, stay legacy-visible
-- (name checks only) unless the strict switch is on.
function M.strict()
  local override = remuda._butler_strict_instance_binding
  if override ~= nil then return override == true end
  return os.getenv("REMUDA_BUTLER_STRICT_INSTANCE_BINDING") == "1"
end
function M.enforcing(agent)
  return type(caller_live) == "function" and type(agent) == "table"
    and type(agent.instance_id) == "string" and agent.instance_id ~= ""
end
function M.legacy_core() return type(caller_live) ~= "function" end
-- True when the core confirms the BOUND instance is live; always true where not enforcing.
function M.live(agent)
  if not M.enforcing(agent) then return true end
  local ok, live = pcall(caller_live, agent.session_name, agent.instance_id)
  return ok and live ~= nil and live ~= false
end

local function unidentified(reason)
  return { tag = "unidentified", reason = reason }
end

function M.resolve(caller)
  if type(caller) ~= "table" then return unidentified("caller context unavailable") end
  if caller.kind == "outside" then
    -- The guard audit sink exists on pinned and older cores, including those
    -- without remuda.log. Record only constants, never caller metadata or text.
    local policy = remuda.butler and remuda.butler.guard_policy
    local ok, written = pcall(function()
      return assert(policy).append({ session = "operator", kind = "outside", event = "caller_policy",
        class = "identity", summary = OUTSIDE_POLICY .. ": outside caller mapped to operator" })
    end)
    if not ok or not written then return unidentified("outside operator policy audit unavailable") end
    return { tag = "operator", policy = OUTSIDE_POLICY }
  end
  if caller.kind == "service" then return { tag = "service", service = caller.service } end
  if caller.kind ~= "session" or type(caller.session) ~= "string" or caller.session == "" then
    return unidentified("caller kind or session is unavailable")
  end

  local found, matches = nil, 0
  for alias, agent in pairs(bus.agents or {}) do
    if type(agent) == "table" and agent.session_name == caller.session then
      found, matches = { alias = alias, agent = agent }, matches + 1
    end
  end
  if matches ~= 1 or not found or type(found.agent.id) ~= "string" or found.agent.id == "" then
    return unidentified("managed session has no unique Butler registration")
  end
  if M.enforcing(found.agent) then
    if caller.instance_id ~= found.agent.instance_id then return unidentified("session instance is not the bound instance") end
  elseif M.strict() then
    return unidentified("strict instance binding: this member is not enforced")
  end
  return {
    tag = "member",
    id = found.agent.id,
    alias = found.agent.alias or found.alias,
    kind = found.agent.kind,
    session_name = found.agent.session_name,
    status_path = type(found.agent.telemetry) == "table" and found.agent.telemetry.status_path or nil,
  }
end

function M.current_agent(caller)
  local principal = M.resolve(caller)
  if principal.tag == "member" then return principal.id end
  if principal.tag == "operator" then return nil end
  error("Butler cannot identify this caller. Next: run from a registered Butler session or upgrade Remuda core.", 0)
end

M.outside_policy = OUTSIDE_POLICY
remuda._butler_caller_principal = M
