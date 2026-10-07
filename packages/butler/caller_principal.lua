-- Resolve CLI caller identity from the core's daemon-derived kind/session only.
local config = assert(remuda._butler_caller_principal_config)
local bus = assert(config.bus)

local M = {}
local OUTSIDE_POLICY = "outside_is_operator_transitional"

local function unidentified(reason)
  return { tag = "unidentified", reason = reason }
end

function M.resolve(caller)
  if type(caller) ~= "table" then return unidentified("caller context unavailable") end
  if caller.kind == "outside" then
    if type(remuda.log) == "function" then
      pcall(remuda.log, "warn", "Butler caller policy " .. OUTSIDE_POLICY .. ": outside caller mapped to operator")
    end
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
  return {
    tag = "member",
    id = found.agent.id,
    alias = found.agent.alias or found.alias,
    kind = found.agent.kind,
    session_name = found.agent.session_name,
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
