-- Decide inbox activation and open options for every open site.
--
-- The marker is read once at startup. A process that has seen `present` never
-- goes back to the create path, and an unknown marker refuses. An active inbox
-- requires remuda.db.capabilities().must_exist; one capability read per process
-- decides between must_exist options and refusal, never create-capable options.
local M = {}
-- A butler re-execution reloads this module in the same process. Keep the
-- activation latch and the capability answer on the remuda table so a marker
-- that vanished between loads does not look like a fresh install.
local state = remuda._butler_inbox_activation
if type(state) ~= "table" then
  state = { active = false, unknown = nil, protection = "uninitialized",
    capability_checked = false, capability_supported = false }
  remuda._butler_inbox_activation = state
end

local UPGRADE = "SQLite inbox unavailable: this core does not report "
  .. "remuda.db.capabilities().must_exist, so an active inbox cannot be opened "
  .. "without risking an empty recreate. Upgrade remuda to a core that "
  .. "supports must_exist; the inbox was not opened or created."

local function reports_must_exist(core)
  if type(core) ~= "table" or type(core.capabilities) ~= "function" then
    return false
  end
  local ok, value = pcall(core.capabilities)
  return ok and type(value) == "table" and value.must_exist == true
end

local function supported(core)
  if not state.capability_checked then
    state.capability_checked = true
    state.capability_supported = reports_must_exist(core)
  end
  return state.capability_supported
end

-- `kind` is "present", "absent", or anything else with a reason. The caller
-- gets the state from the same metadata check it already applies to the
-- database file.
function M.observe(kind, reason)
  if kind == "present" then
    state.active = true
    state.unknown = nil
  elseif kind == "absent" then
    -- Once active or unknown, an absence is not a fresh install and must not
    -- clear the earlier state.
  else
    state.unknown = tostring(reason or "cannot determine the inbox marker")
  end
end

-- The simple inbox writes the marker after a successful first import.
function M.activate()
  state.active = true
  state.unknown = nil
end

-- One decision for an open site: options, or nil and a refusal. An active
-- inbox never receives create-capable options.
function M.prepare(core)
  if state.unknown then
    state.protection = "refused"
    return nil, "SQLite inbox unavailable: " .. state.unknown
      .. "; refusing to open without a known activation state."
  end
  if not state.active then
    state.protection = "precheck"
    return { migrations = true, timeout_ms = 200 }
  end
  if not supported(core) then
    state.protection = "refused"
    return nil, UPGRADE
  end
  state.protection = "must_exist"
  return { migrations = true, timeout_ms = 200, must_exist = true }
end

function M.status()
  return { active = state.active, protection = state.protection, unknown = state.unknown }
end

remuda._butler_inbox_open = M
return M
