-- Optional public display facts, consumed locally and by authenticated List
-- readers. Never publish tasks, paths, mail, capabilities or terminal contents.
local config = assert(remuda._butler_session_display_config)
local bus = assert(config.bus)
local published = {}
local wall_origin, clock_origin
local function short(value)
  if type(value) ~= "string" or value == "" or value == "?" or #value > 128 then return nil end
  if value:find("[%z\1-\31\127]") then return nil end
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
local function fresh(_, telemetry)
  local observed = tonumber(telemetry.observed_at)
  if not observed or observed ~= observed or observed == math.huge then return false end
  local clock = (config.clock or remuda.clock)()
  if not wall_origin then wall_origin, clock_origin = (config.now or os.time)(), clock end
  -- Anchor wall time once; subsequent wall-clock jumps cannot revive replayed
  -- samples. A new image must establish a new origin (no telemetry persisted).
  local age = wall_origin + (clock - clock_origin) / 1000 - observed
  return clock >= clock_origin and age >= 0 and age < 60
end

local function tick()
  local setter = remuda.session and remuda.session.set_display
  if type(setter) ~= "function" then return end -- older core
  local enabled = config.enabled()
  local next_published = {}
  if enabled then
    for alias, agent in pairs(bus.agents) do
      local name = agent.session_name or alias
      local instance = agent.instance_id
      if agent.instance_binding == 1 and short(instance) and short(agent.id) then
        local parent = agent.parent and bus.agents[agent.parent]
        local leader = parent and parent.id == agent.parent_id and short(parent.alias or agent.parent) or nil
        local facts = { version = 1, provider = "butler", alias = short(agent.alias or alias),
          leader = leader, kind = short(agent.kind), model = short(agent.model) }
        local ok, telemetry = pcall(remuda._butler_telemetry_for, agent)
        if ok and type(telemetry) == "table" and fresh(agent, telemetry) then
          facts.model = short(telemetry.model) or facts.model
          facts.context_percent = integer(telemetry.context_percent, 100)
          facts.context_used = integer(telemetry.context_used, 9007199254740991)
          facts.context_window = integer(telemetry.context_window, 9007199254740991)
          if facts.context_window == 0 then
            facts.context_used, facts.context_window, facts.context_percent = nil, nil, nil
          end
          if facts.context_used and facts.context_window and facts.context_used > facts.context_window then
            facts.context_used, facts.context_window, facts.context_percent = nil, nil, nil
          end
        end
        if accepted(setter, name, instance, facts) then
          next_published[name] = { instance = instance, expires = (config.clock or remuda.clock)() + 10000 }
        end
      end
    end
  end
  for name, prior in pairs(published) do
    local current = next_published[name]
    if not current or current.instance ~= prior.instance then
      local cleared = accepted(setter, name, prior.instance, nil)
      if not cleared and not current and (config.clock or remuda.clock)() < prior.expires then
        next_published[name] = prior -- retry only within the native publication lifetime
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
