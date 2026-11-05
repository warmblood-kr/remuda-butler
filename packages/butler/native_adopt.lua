-- Owner-declared Codex native adoption glue.
-- The owner names an existing session alias, the local socket from a fresh
-- /status and the canonical thread UUID. Butler owns the live row/instance
-- fence, the private binding path and the never-retry rule; the core helper
-- owns the endpoint/process/socket proof and publishes the pin/manifest.
-- No socket, thread or auth material is stored on the agent or in the roster.
local M = {}

local function live_row(list, name)
  local ok, rows = pcall(list)
  if not ok or type(rows) ~= "table" then return nil end
  for _, row in ipairs(rows) do
    if row.name == name then return row end
  end
end

local function same_identity(row, identity)
  return row ~= nil and row.alive == true and row.id == identity.id
    and row.instance_id == identity.instance
end

local function free_of_native(agent)
  return type(agent.native) ~= "table" or agent.native.mode ~= "native"
end

local function config_state(self, name)
  local path = self.launch.config_path and self.launch.config_path()
  if not path then return { enabled = false, reason = "config_home_unavailable" } end
  local read = self.read or (self.launch.read_config and function(path)
    return self.launch.read_config(path)
  end)
  local values = self.config.load(path, { json = self.json, read = read })
  return self.config.kind(values, "codex")
end

-- One adoption attempt. `unavailable`/`uncertain` are returned to the owner;
-- they never create a half-binding and never become an automatic retry.
function M.codex(self, name, socket, thread)
  if type(name) ~= "string" or name == "" then return nil, "missing_session" end
  local agent = self.bus.agents[name]
  if type(agent) ~= "table" then return nil, "unknown_session" end
  if agent.kind ~= "codex" then return nil, "not_a_codex_session" end
  if not free_of_native(agent) then return nil, "session_already_native" end
  local state = config_state(self, name)
  if state.enabled ~= true then
    return nil, "codex_not_opted_in: " .. tostring(state.reason or "disabled")
  end
  local row = live_row(self.list, name)
  if not row or row.alive ~= true then return nil, "session_not_live" end
  if type(row.id) ~= "string" or row.id == ""
      or type(row.instance_id) ~= "string" or row.instance_id == "" then
    return nil, "missing_row_identity"
  end
  local identity = { id = row.id, instance = row.instance_id }
  local binding, nonce, why = self.launch.prepare(name)
  if not binding then return nil, "binding_failed: " .. tostring(why) end
  local result = self.codex.adopt({ binding = binding, nonce = nonce,
    session = row.id, socket = socket, thread = thread },
    { json = self.json, runner = self.runner, remuda = self.remuda })
  -- Adoption yields in the helper. Never attach a binding to a replaced row.
  if not same_identity(live_row(self.list, name), identity) then
    return nil, "session_replaced_during_adopt"
  end
  if type(result) ~= "table" then return nil, "uncertain: helper_failed" end
  if result.outcome == "adopted" then
    agent.native = { mode = "native", kind = "codex", path = binding, nonce = nonce,
      row_id = identity.id, instance = identity.instance,
      generation = result.generation, awaiting_publication = false }
    if self.trace then
      pcall(self.trace, "native_adopted", name .. " kind=codex generation="
        .. tostring(result.generation):sub(1, 12))
    end
    if self.roster_save then pcall(self.roster_save) end
    return { generation = result.generation }
  end
  if result.outcome == "unavailable" then
    return nil, "unavailable: " .. tostring(result.reason)
  end
  return nil, "uncertain: " .. tostring(result.reason or "unknown")
end

function M.install(options)
  options = options or {}
  local self = {
    bus = assert(options.bus, "adoption needs the Butler bus"),
    list = assert(options.list or remuda.ls, "adoption needs remuda.ls"),
    launch = assert(options.launch, "adoption needs the native launch glue"),
    config = assert(options.config, "adoption needs the native config"),
    codex = assert(options.codex, "adoption needs the Codex helper client"),
    json = options.json or (remuda and remuda.json),
    read = options.read,
    runner = options.runner or (remuda and remuda.process and remuda.process.run),
    remuda = options.remuda or "remuda",
    roster_save = options.roster_save,
    trace = options.trace or remuda._butler_session_trace,
  }
  self.adopt_codex = function(name, socket, thread) return M.codex(self, name, socket, thread) end
  remuda._butler_native_adopt = self
  remuda.butler = remuda.butler or {}
  remuda.butler.native_adopt = self
  return self
end

remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_adopt = M
return M
