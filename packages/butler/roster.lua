-- The live roster on disk, so a fresh Lua image can take back sessions that
-- outlived it (`remuda reload`, remuda#713: host-backed sessions keep their
-- names, processes and instance ids; the image starts empty).
--
-- One private (0600) JSON file next to agents.jsonl. It holds who is who and
-- where: alias, durable id, kind, leader, cwd, sandbox, instance id. Never a
-- capability token, a task or any message text.
local config = assert(remuda._butler_roster_config)
local bus = assert(config.bus)
local M = {}
M.path = config.data_home and (config.data_home .. "/remuda/butler/roster.json") or nil
M.VERSION = 1

local function json() return type(remuda.json) == "table" and remuda.json or nil end
local function list(value)
  if type(value) ~= "table" then return nil end
  local out = {}
  for _, item in ipairs(value) do if type(item) == "string" then out[#out + 1] = item end end
  return out
end

-- The rows worth keeping: proven-bound rows only, since adoption matches on
-- the instance id and an unbound row could not be told from a reused name.
function M.rows()
  local rows = {}
  for alias, agent in pairs(bus.agents) do
    if type(agent) == "table" and type(agent.id) == "string" and agent.id ~= ""
        and agent.instance_binding == 1 and type(agent.instance_id) == "string" and agent.instance_id ~= "" then
      rows[#rows + 1] = { alias = alias, id = agent.id, kind = agent.kind, model = agent.model,
        session_name = agent.session_name or alias, parent = agent.parent, parent_id = agent.parent_id,
        cwd = agent.cwd, sandbox = agent.sandbox, writable = list(agent.writable),
        instance_id = agent.instance_id,
        status_path = type(agent.telemetry) == "table" and agent.telemetry.status_path or nil }
    end
  end
  table.sort(rows, function(a, b) return a.alias < b.alias end)
  return rows
end

local last_text
-- Write the roster when it changed. Errors are returned, never raised: a
-- failed write only costs adoption after a reload.
function M.save()
  local codec = json()
  if not M.path or not codec or not (remuda.fs and type(remuda.fs.write_atomic) == "function") then
    return nil, "roster unavailable on this core"
  end
  local rows = M.rows()
  local ok, text = pcall(codec.encode, { version = M.VERSION,
    rows = type(codec.array) == "function" and codec.array(rows) or rows })
  if not ok then return nil, tostring(text) end
  if text == last_text then return true end
  local dir = M.path:match("^(.*)/[^/]+$")
  if dir then pcall(remuda.mkdir, dir) end
  local wrote, why = remuda.fs.write_atomic(M.path, text, { private = true })
  if not wrote then return nil, tostring(why) end
  last_text = text
  return true
end

function M.load()
  local codec = json()
  if not M.path or not codec then return {} end
  local file = io.open(M.path, "rb")
  if not file then return {} end
  local text = file:read("a") or ""
  file:close()
  local ok, value = pcall(codec.decode, text)
  if not ok or type(value) ~= "table" or value.version ~= M.VERSION or type(value.rows) ~= "table" then return {} end
  local rows = {}
  for _, row in ipairs(value.rows) do
    if type(row) == "table" and type(row.alias) == "string" and type(row.id) == "string"
        and type(row.instance_id) == "string" and row.instance_id ~= "" then
      rows[#rows + 1] = row
    end
  end
  return rows
end

-- Rebuild bus.agents from the roster for every session that is still the same
-- live instance and whose identity is still running. Only on a fresh image
-- (an empty roster in memory). Returns the adopted aliases, sorted.
-- Each adopted row gets a fresh capability record that no bridge holds: an
-- old MCP bridge's token died with the old image, while CLI callers are
-- attributed by session and instance (remuda#800).
function M.adopt(sessions)
  for alias in pairs(bus.agents) do
    if alias ~= "butler" or bus.agents.butler.instance_id then return {} end
  end
  local live = {}
  for _, session in ipairs(type(sessions) == "table" and sessions or {}) do
    if session.alive and type(session.name) == "string" and type(session.instance_id) == "string" then
      live[session.name] = session.instance_id
    end
  end
  local adopted = {}
  for _, row in ipairs(M.load()) do
    local name = row.session_name or row.alias
    local identity = bus.identity_ids[row.id]
    if live[name] == row.instance_id and identity and identity.state == "running"
        and identity.alias == row.alias and not (bus.agents[row.alias] and bus.agents[row.alias].instance_id) then
      local agent = { kind = row.kind, model = row.model, parent = row.parent, parent_id = row.parent_id,
        children = {}, id = row.id, alias = row.alias, session_name = name,
        session_start_marker = config.new_ulid(), cwd = row.cwd, sandbox = row.sandbox,
        writable = list(row.writable), instance_id = row.instance_id, instance_binding = 1,
        telemetry = row.status_path and { status_path = row.status_path } or nil, adopted = true }
      if row.alias == "butler" then
        -- main.lua finishes the root row (telemetry, token, marker) from here.
        local root = bus.agents.butler or {}
        for key, value in pairs(agent) do if key ~= "telemetry" then root[key] = value end end
        agent = root
      end
      local token = config.next_token(row.alias)
      agent.token = token
      bus.tokens[token] = { id = row.id, generation = agent.session_start_marker,
        instance_id = row.instance_id, instance_binding = 1 }
      bus.agents[row.alias] = agent
      adopted[#adopted + 1] = row.alias
    end
  end
  table.sort(adopted)
  return adopted
end

-- After main.lua has the root row: rebuild each leader's children. A member
-- whose leader did not come back goes to the root, as when a lead exits (#230).
function M.link_children(adopted)
  local root = bus.agents.butler
  for _, alias in ipairs(adopted or {}) do
    local agent = bus.agents[alias]
    if agent and alias ~= "butler" and agent.parent then
      local parent = bus.agents[agent.parent]
      if not (parent and (agent.parent_id == nil or agent.parent_id == parent.id)) then
        agent.parent, agent.parent_id, parent = root and "butler" or nil, root and root.id or nil, root
      end
      if parent then
        parent.children = parent.children or {}
        local present = false
        for _, child in ipairs(parent.children) do present = present or child == alias end
        if not present then parent.children[#parent.children + 1] = alias end
      end
    end
  end
end

remuda._butler_roster = M
