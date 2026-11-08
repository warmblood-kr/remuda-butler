-- Automatic, bounded cluster display facts for every exact live Butler
-- member. Facts are published on the local image only; an authenticated
-- cluster peer can read them through the session-facts sidecar. Never publish
-- tasks, paths, mail, capabilities, terminal text or credentials.
local config = assert(remuda._butler_session_display_config)
local bus = assert(config.bus)
local published = {}
local wall_origin, clock_origin
local TTL_MS = 10000
local MAX_TEXT = 128

local function clock()
  return (config.clock or remuda.clock)()
end

local function wall()
  return (config.now or os.time)()
end

-- One bounded scalar: no framing, control or bidi characters.
local function short(value)
  if type(value) ~= "string" or value == "" or value == "?" or #value > MAX_TEXT then return nil end
  if value:find("[%z\1-\31\127]") then return nil end
  if value:find("\194\128") or value:find("\226\128[\142-\148\174-\175]")
      or value:find("\226\129[\166-\169]") then return nil end
  return value
end

local function integer(value, maximum)
  value = tonumber(value)
  if not value or value ~= value or value < 0 or value > maximum then return nil end
  return math.floor(value)
end

local function accepted(setter, name, instance, facts)
  local ok, result = pcall(setter, name, instance, facts)
  return ok and result == true
end

-- The observation is fresh only when the payload was first seen under 60s ago;
-- republishing the same payload never renews it.
local function fresh(telemetry)
  local observed = tonumber(telemetry.observed_at)
  if not observed or observed ~= observed or observed == math.huge then return false end
  local current_wall, current_clock = wall(), clock()
  if not wall_origin then wall_origin, clock_origin = current_wall, current_clock end
  local age = wall_origin + (current_clock - clock_origin) / 1000 - observed
  return current_clock >= clock_origin and age >= 0 and age < 60
end

local function facts_for(alias, agent)
  local instance = agent.instance_id
  if agent.instance_binding ~= 1 or not short(instance) or not short(agent.id) then
    return nil, nil
  end
  local parent = agent.parent and bus.agents[agent.parent]
  -- Exact durable edge only: the recorded parent generation must still match.
  local leader_id = parent and parent.id == agent.parent_id and short(parent.id) or nil
  local facts = {
    version = 1,
    provider = "butler",
    member_id = agent.id,
    leader_id = leader_id,
    alias = short(agent.alias or alias),
    kind = short(agent.kind),
    model = short(agent.model),
  }
  local ok, telemetry = pcall(remuda._butler_telemetry_for, agent)
  if ok and type(telemetry) == "table" and fresh(telemetry) then
    facts.model = short(telemetry.model) or facts.model
    facts.context_percent = integer(telemetry.context_percent, 100)
    facts.context_used = integer(telemetry.context_used, 9007199254740991)
    facts.context_window = integer(telemetry.context_window, 9007199254740991)
    if facts.context_window == 0 then
      facts.context_used, facts.context_window, facts.context_percent = nil, nil, nil
    end
    if facts.context_used and facts.context_window
        and facts.context_used > facts.context_window then
      facts.context_used, facts.context_window, facts.context_percent = nil, nil, nil
    end
  end
  return short(agent.session_name or alias), instance, facts
end

local function tick()
  local setter = remuda.session and remuda.session.set_display
  if type(setter) ~= "function" then return end -- older core: no publisher path
  local next_published = {}
  for alias, agent in pairs(bus.agents) do
    local name, instance, facts = facts_for(alias, agent)
    if name and facts and accepted(setter, name, instance, facts) then
      next_published[name] = { instance = instance, expires = clock() + TTL_MS }
    end
  end
  for name, prior in pairs(published) do
    local current = next_published[name]
    if not current or current.instance ~= prior.instance then
      local cleared = accepted(setter, name, prior.instance, nil)
      if not cleared and not current and clock() < prior.expires then
        next_published[name] = prior -- retry only inside the native lifetime
      end
    end
  end
  published = next_published
end

local function stop()
  local setter = remuda.session and remuda.session.set_display
  if type(setter) == "function" then
    for name, prior in pairs(published) do accepted(setter, name, prior.instance, nil) end
  end
  published = {}
end

remuda._butler_session_display = { tick = tick, stop = stop }
remuda._butler_session_display_tick = tick
