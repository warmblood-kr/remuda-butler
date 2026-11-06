-- Owner-declared Codex native adoption glue.
-- The owner names an existing session alias, the local socket from a fresh
-- /status and the canonical thread UUID. Butler owns the live row/instance
-- fence, the private binding path and the never-retry rule; the core helper
-- owns the endpoint/process/socket proof and publishes the pin/manifest.
-- No socket, thread or auth material is stored on the agent or in the roster.
local M = {}

local function live_row(rows, name)
  if type(rows) ~= "table" then return nil end
  for _, row in ipairs(rows) do
    if row.name == name then return row end
  end
end

-- The live row's canonical id: the projection's id when present, else the
-- official lookup (same-daemon proof) once. No alias and no instance-as-id.
local function resolve_identity(self, row, rows)
  if type(row) ~= "table" then return nil, "missing_row_identity" end
  if type(row.id) == "string" and row.id ~= "" then return row.id end
  local identity = self.identity
  if not identity or type(identity.resolve) ~= "function" then
    return nil, "missing_row_identity"
  end
  local ok, id, why = pcall(identity.resolve, row, { rows = rows,
    list = self.list, runner = self.runner, json = self.json, remuda = self.remuda })
  if not ok then return nil, "identity_unavailable" end
  return id, why
end

-- A projected id, when present, must match the resolved id. An old projection
-- omits the field entirely; the exact instance_id remains the start identity.
local function same_identity(row, identity)
  return row ~= nil and row.alive == true
    and row.instance_id == identity.instance
    and (row.id == nil or row.id == "" or row.id == identity.id)
end

local function free_of_native(agent)
  return type(agent.native) ~= "table" or agent.native.mode ~= "native"
end

-- The helper yields. Freeze the agent's native decision (object + immutable
-- scalars) before the call; an install is valid only if the exact agent
-- object, module image and the same unchanged decision are still current. A
-- reload, an agent replacement, a concurrent binding or a NEW disabled
-- decision must never be overwritten.
local function decision_snapshot(agent)
  local native = agent.native
  if type(native) ~= "table" then return nil end
  return { ref = native, mode = native.mode, kind = native.kind,
    reason = native.reason, path = native.path, nonce = native.nonce,
    row_id = native.row_id, instance = native.instance,
    generation = native.generation, session_token = native.session_token,
    awaiting = native.awaiting_publication }
end

local function decision_unchanged(agent, snapshot)
  if snapshot == nil then return type(agent.native) ~= "table" end
  local native = agent.native
  if native ~= snapshot.ref then return false end
  return native.mode == snapshot.mode and native.kind == snapshot.kind
    and native.reason == snapshot.reason and native.path == snapshot.path
    and native.nonce == snapshot.nonce and native.row_id == snapshot.row_id
    and native.instance == snapshot.instance
    and native.generation == snapshot.generation
    and native.session_token == snapshot.session_token
    and native.awaiting_publication == snapshot.awaiting
end

-- `install` publishes the running instance under both ownership aliases
-- (`remuda.butler.native_adopt` and `remuda._butler_native_adopt`); the module
-- table itself is never the installed facade. A reload republishes the module
-- and a reinstall publishes a new instance, so either leaves an old instance
-- failing this fence instead of attaching a binding to a replaced image.
local function still_current(self, name, agent, snapshot)
  if self.bus.agents[name] ~= agent then return false end
  if not decision_unchanged(agent, snapshot) then return false end
  local installed = remuda.butler and remuda.butler.native_adopt
  return installed == self and remuda._butler_native_adopt == self
end

local function config_state(self, name, kind)
  local path = self.launch.config_path and self.launch.config_path()
  if not path then return { enabled = false, reason = "config_home_unavailable" } end
  local read = self.read or (self.launch.read_config and function(path)
    return self.launch.read_config(path)
  end)
  local values = self.config.load(path, { json = self.json, read = read })
  return self.config.kind(values, kind)
end

-- One adoption attempt. `unavailable`/`uncertain` are returned to the owner;
-- they never create a half-binding and never become an automatic retry.
function M.codex(self, name, socket, thread)
  if type(name) ~= "string" or name == "" then return nil, "missing_session" end
  local agent = self.bus.agents[name]
  if type(agent) ~= "table" then return nil, "unknown_session" end
  if agent.kind ~= "codex" then return nil, "not_a_codex_session" end
  if not free_of_native(agent) then return nil, "session_already_native" end
  local decision = decision_snapshot(agent)
  local state = config_state(self, name, "codex")
  if state.enabled ~= true then
    return nil, "codex_not_opted_in: " .. tostring(state.reason or "disabled")
  end
  local rows = self.list()
  local row = live_row(rows, name)
  if not row or row.alive ~= true then return nil, "session_not_live" end
  if type(row.instance_id) ~= "string" or row.instance_id == "" then
    return nil, "missing_row_identity"
  end
  local id, id_why = resolve_identity(self, row, rows)
  if not id then return nil, id_why end
  local identity = { id = id, instance = row.instance_id }
  -- A replacement during the first listing must not even reach the helper.
  if not still_current(self, name, agent, decision) then
    return nil, "session_replaced_during_adopt"
  end
  local binding, nonce, why = self.launch.prepare(name, "codex")
  if not binding then return nil, "binding_failed: " .. tostring(why) end
  local result = self.codex.adopt({ binding = binding, nonce = nonce,
    session = id, socket = socket, thread = thread },
    { json = self.json, runner = self.runner, remuda = self.remuda })
  -- Adoption yields in the helper. Never attach a binding to a replaced row,
  -- a replaced agent object/module or a decision another adoption already made.
  if not same_identity(live_row(self.list(), name), identity)
      or not still_current(self, name, agent, decision) then
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
    -- Adoption is a publication event: flush mail already waiting for this
    -- session through the same immediate native path.
    if remuda._butler_notice
        and type(remuda._butler_notice.native_publication) == "function" then
      pcall(remuda._butler_notice.native_publication, name)
    end
    return { generation = result.generation }
  end
  if result.outcome == "unavailable" then
    return nil, "unavailable: " .. tostring(result.reason)
  end
  return nil, "uncertain: " .. tostring(result.reason or "unknown")
end

-- One adoption of an explicit, already-running OpenCode server. The owner
-- declares the loopback endpoint and conversation; the helper proves them with
-- the credential and the local pid/start. Endpoint, conversation and password
-- stay on the request/manifest and are never stored on the agent or roster.
function M.opencode(self, name, endpoint, conversation, password)
  if type(name) ~= "string" or name == "" then return nil, "missing_session" end
  local agent = self.bus.agents[name]
  if type(agent) ~= "table" then return nil, "unknown_session" end
  if agent.kind ~= "opencode" then return nil, "not_an_opencode_session" end
  if not free_of_native(agent) then return nil, "session_already_native" end
  local decision = decision_snapshot(agent)
  local state = config_state(self, name, "opencode")
  if state.enabled ~= true then
    return nil, "opencode_not_opted_in: " .. tostring(state.reason or "disabled")
  end
  local rows = self.list()
  local row = live_row(rows, name)
  if not row or row.alive ~= true then return nil, "session_not_live" end
  if type(row.instance_id) ~= "string" or row.instance_id == "" then
    return nil, "missing_row_identity"
  end
  local id, id_why = resolve_identity(self, row, rows)
  if not id then return nil, id_why end
  local identity = { id = id, instance = row.instance_id }
  -- A replacement during the first listing must not even reach the helper.
  if not still_current(self, name, agent, decision) then
    return nil, "session_replaced_during_adopt"
  end
  local binding, nonce, why = self.launch.prepare(name, "opencode")
  if not binding then return nil, "binding_failed: " .. tostring(why) end
  local result = self.opencode.adopt({ binding = binding, nonce = nonce,
    session = id, endpoint = endpoint, conversation = conversation,
    password = password },
    { json = self.json, runner = self.runner, remuda = self.remuda })
  -- Adoption yields in the helper. Never attach a binding to a replaced row,
  -- a replaced agent object/module or a decision another adoption already made.
  if not same_identity(live_row(self.list(), name), identity)
      or not still_current(self, name, agent, decision) then
    return nil, "session_replaced_during_adopt"
  end
  if type(result) ~= "table" then return nil, "uncertain: helper_failed" end
  if result.outcome == "adopted" then
    agent.native = { mode = "native", kind = "opencode", path = binding, nonce = nonce,
      row_id = identity.id, instance = identity.instance,
      session_token = identity.id, generation = result.generation,
      awaiting_publication = false }
    if self.trace then
      pcall(self.trace, "native_adopted", name .. " kind=opencode generation="
        .. tostring(result.generation):sub(1, 12))
    end
    if self.roster_save then pcall(self.roster_save) end
    if remuda._butler_notice
        and type(remuda._butler_notice.native_publication) == "function" then
      pcall(remuda._butler_notice.native_publication, name)
    end
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
    opencode = assert(options.opencode, "adoption needs the OpenCode helper client"),
    identity = options.identity or (remuda.butler and remuda.butler.native_identity),
    json = options.json or (remuda and remuda.json),
    read = options.read,
    runner = options.runner or (remuda and remuda.process and remuda.process.run),
    remuda = options.remuda or "remuda",
    roster_save = options.roster_save,
    trace = options.trace or remuda._butler_session_trace,
  }
  self.adopt_codex = function(name, socket, thread) return M.codex(self, name, socket, thread) end
  self.adopt_opencode = function(name, endpoint, conversation, password)
    return M.opencode(self, name, endpoint, conversation, password)
  end
  remuda._butler_native_adopt = self
  remuda.butler = remuda.butler or {}
  remuda.butler.native_adopt = self
  return self
end

remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_adopt = M
return M
