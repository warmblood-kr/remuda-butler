-- Durable agent identities: ULIDs, the agents.jsonl record, alias/ULID
-- resolution and caller identity. main.lua passes its locals in (the mail.lua
-- pattern) after mail.lua is loaded, and rebinds the exported ones.
local config = assert(remuda._butler_identity_config)
local bus = assert(config.bus)
local current_agent = assert(config.current_agent)
local json_quote = assert(config.json_quote)
local data_home = config.data_home
local system = assert(remuda._butler_system)

-- ULIDs are durable public identities; session names remain the mutable,
-- human-friendly keys used by the mailbox and the in-memory team tree.
local alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local function crockford_ulid()
  local second = os.time()
  local millis = math.floor(second * 1000)
  local bytes = {}
  for i = 6, 1, -1 do bytes[i] = millis % 256; millis = math.floor(millis / 256) end
  local entropy
  if bus.previous_ulid_second == second then
    local bytes = { bus.previous_ulid_random:byte(1, 10) }
    local carry = 1
    for i = 10, 1, -1 do
      local value = bytes[i] + carry
      bytes[i] = value % 256
      carry = math.floor(value / 256)
    end
    if carry ~= 0 then error("ULID random component overflow", 0) end
    local out = {}
    for i = 1, 10 do out[i] = string.char(bytes[i]) end
    entropy = table.concat(out)
  else
    if type(remuda.random_bytes) == "function" then
      local ok, random_bytes = pcall(remuda.random_bytes, 10)
      if ok and type(random_bytes) == "string" and #random_bytes >= 10 then
        entropy = random_bytes:sub(1, 10)
      end
    end
    if not entropy then
      local opened, random = pcall(io.open, "/dev/urandom", "rb")
      if opened and random then
        local read_ok, value = pcall(random.read, random, 10)
        if read_ok and type(value) == "string" and #value == 10 then entropy = value end
        pcall(random.close, random)
      end
    end
    if not entropy then error("secure random source unavailable for ULID entropy", 0) end
  end
  bus.previous_ulid_second, bus.previous_ulid_random = second, entropy
  for i = 1, 10 do bytes[i + 6] = entropy:byte(i) end
  local bits, out = { 0, 0 }, {}
  for _, byte in ipairs(bytes) do
    for bit = 7, 0, -1 do bits[#bits + 1] = math.floor(byte / (2 ^ bit)) % 2 end
  end
  -- ULIDs have two zero padding bits before the 128-bit payload.
  for group = 0, 25 do
    local n = 0
    for j = 1, 5 do n = n * 2 + bits[group * 5 + j] end
    out[#out + 1] = alphabet:sub(n + 1, n + 1)
  end
  return table.concat(out)
end
local function is_ulid(value)
  return type(value) == "string" and #value == 26
    and value:match("^[0-9A-HJKMNP-TV-Z]+$") ~= nil
end
local identity_path = data_home and data_home .. "/remuda/butler/agents.jsonl"
bus.identities = bus.identities or {}
bus.identity_ids = bus.identity_ids or {}
remuda._butler_new_ulid = crockford_ulid
local function identity_record(record)
  if not identity_path then return end
  local dir = identity_path:match("^(.*)/[^/]+$")
  if dir then system.mkdir_p(dir) end
  local row = '{"id":' .. json_quote(record.id) .. ',"alias":' .. json_quote(record.alias)
    .. ',"kind":' .. json_quote(record.kind or "") .. ',"leader_id":' .. json_quote(record.leader_id or "")
  if record.created_at and not record.created_at_unknown then
    row = row .. ',"created_at":' .. json_quote(record.created_at)
  elseif record.created_at_unknown then
    row = row .. ',"created_at_unknown":true'
  end
  row = row .. ',"state":' .. json_quote(record.state or "running")
  if record.reason then row = row .. ',"reason":' .. json_quote(record.reason) end
  if record.ended_at then row = row .. ',"ended_at":' .. json_quote(record.ended_at) end
  if record.ended_at_estimate then row = row .. ',"ended_at_estimate":true' end
  remuda._butler_mail.append(identity_path, row .. "}\n")
end
local function json_field(line, key)
  local quoted = line:match('"' .. key .. '":(".-")')
  if not quoted then return nil end
  local value = quoted:sub(2, -2)
  return (value:gsub('\\(.)', function(c)
    if c == "n" then return "\n" elseif c == "r" then return "\r"
    elseif c == "t" then return "\t" else return c end
  end))
end
if identity_path and not bus.identities_loaded then
  local f = io.open(identity_path, "r")
  if f then
    for line in f:lines() do
      local id, alias = json_field(line, "id"), json_field(line, "alias")
      if id and alias then
        local created_at, ended_at = json_field(line, "created_at"), json_field(line, "ended_at")
        local state = json_field(line, "state")
        local created_at_unknown = line:match('"created_at_unknown":true') ~= nil
          or (not state and ended_at and created_at == ended_at)
        local record = { id = id, alias = alias, kind = json_field(line, "kind"),
          leader_id = json_field(line, "leader_id"), created_at = created_at,
          created_at_unknown = created_at_unknown, ended_at = ended_at,
          state = state or (ended_at and "ended" or "running"),
          reason = json_field(line, "reason"),
          ended_at_estimate = line:match('"ended_at_estimate":true') ~= nil }
        bus.identity_ids[id] = record
        bus.identities[alias] = record
      end
    end
    f:close()
  end
  -- A fresh image after `stop -f`: its agents died with the daemon and no
  -- `session_exited` recorded them, so end each identity with no live session
  -- (#24). The root keeps its identity across daemons and is never ended.
  local live = {}
  for _, session in ipairs(remuda.ls()) do
    if session.alive then live[session.name] = true end
  end
  for id, record in pairs(bus.identity_ids) do
    if not record.ended_at and record.alias ~= "butler" and not live[record.alias] then
      record.state, record.reason = "ended", "daemon_restart"
      record.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      record.ended_at_estimate = true
      identity_record(record)
    end
  end
  bus.identities_loaded = true
end
local function register_identity(alias, kind, leader_id, id)
  id = id or crockford_ulid()
  local record = { id = id, alias = alias, kind = kind, leader_id = leader_id or "",
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), state = "running" }
  bus.identities[alias], bus.identity_ids[id] = record, record
  identity_record(record)
  return record
end
local function resolve(ref)
  if is_ulid(ref) then
    local record = bus.identity_ids[ref]
    if record and bus.agents[record.alias] and bus.agents[record.alias].id == ref then return record.alias end
    error("no live Butler agent with id " .. ref, 0)
  end
  local live = bus.agents[ref]
  if live then return ref end
  error("unknown member: " .. tostring(ref) .. "; run `remuda butler agents` to list live members", 0)
end
local function mail_address(alias)
  local agent = bus.agents[alias]
  if not agent then
    return { host = "local", id = "", alias = alias or "outside", session = alias or "outside", kind = "", leader = "" }
  end
  local parent = agent.parent and bus.agents[agent.parent]
  return { host = "local", id = agent.id or "", alias = agent.alias or alias,
    session = agent.alias or alias, kind = agent.kind or "", leader = parent and parent.id or "" }
end
local function mail_id(ref, allow_ended)
  if is_ulid(ref) then
    local record = bus.identity_ids[ref]
    if not record then error("no Butler agent with id " .. tostring(ref), 0) end
    local live = bus.agents[record.alias]
    if live and live.id == ref then return ref, live end
    if allow_ended then return ref, nil end
    error("agent " .. ref .. " (alias " .. tostring(record.alias) .. ") has ended", 0)
  end
  -- An ended alias's mail is still worth reading (#23): an inbox read falls
  -- back to the alias's last identity instead of demanding its ULID.
  local last = bus.identities[ref]
  if allow_ended and not bus.agents[ref] and last then return last.id, nil end
  local alias = resolve(ref)
  local agent = bus.agents[alias]
  return agent.id, agent
end
remuda._butler_resolve = resolve
local function next_token(name)
  bus.next = bus.next + 1
  return name .. "-" .. os.time() .. "-" .. bus.next
end
local function caller_name(caller)
  -- A native principal, including unknown and service callers, takes
  -- precedence over the older capability-only compatibility path.
  if caller and caller.kind ~= nil then
    if caller.kind ~= "session" then return nil end
    local native_session = caller.session
    if native_session ~= nil and native_session ~= "" then
      local ok, alias = pcall(resolve, native_session)
      return ok and alias or nil
    end
    return nil
  end
  local token = caller and caller.capability
  local capability = token and bus.tokens[token]
  -- During a live upgrade, an older image may still have alias-valued entries.
  -- Bind one only when the live row proves it owns that exact token.
  if type(capability) == "string" then
    local legacy_agent = bus.agents[capability]
    if not legacy_agent or legacy_agent.token ~= token or not legacy_agent.id
        or not legacy_agent.session_start_marker then return nil end
    capability = { id = legacy_agent.id, generation = legacy_agent.session_start_marker }
    bus.tokens[token] = capability
  end
  if type(capability) ~= "table" then return nil end
  local identity = bus.identity_ids[capability.id]
  local alias = identity and identity.alias
  local agent = alias and bus.agents[alias]
  if identity and identity.state == "running" and agent
      and agent.id == capability.id and agent.session_start_marker == capability.generation then
    return alias
  end
  return nil
end
-- An MCP caller that acts on mail must be a known agent: an unknown or garbage
-- capability is refused, never treated as the operator (review of #39).
local function caller_agent(caller)
  local name = caller_name(caller)
  if not name or not bus.agents[name] then
    error("unknown caller: run from a Butler session (its MCP config carries the capability)", 0)
  end
  return name
end
-- A child's leader is the calling agent, never a guess: an unidentified
-- caller silently became `butler`'s child and reported to root (#24).
local function caller_leader(caller)
  local parent = caller_name(caller)
  if not parent or not bus.agents[parent] then
    error("unknown caller: run from a Butler session, or pass an explicit leader"
      .. " with `remuda butler topic delegate --leader NAME`", 0)
  end
  return parent
end

remuda._butler_identity = {
  is_ulid = is_ulid,
  identity_path = identity_path,
  identity_record = identity_record,
  json_field = json_field,
  register_identity = register_identity,
  resolve = resolve,
  mail_address = mail_address,
  mail_id = mail_id,
  next_token = next_token,
  caller_name = caller_name,
  caller_agent = caller_agent,
  caller_leader = caller_leader,
}
