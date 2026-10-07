-- Durable, bounded exit history. Each session has its own private atomic file;
-- a small index lets the CLI show recently exited sessions after restart.
local config = assert(remuda._butler_exit_ring_config)
local root = config.data_home and (config.data_home .. "/remuda/butler/exits")
local LIMIT, INDEX_LIMIT = 20, 100
local cache, names = {}, nil

local function safe_name(name)
  return type(name) == "string" and #name > 0 and #name <= 200 and not name:find("[%c\0]")
end
local function component(name)
  return (name:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end
local function path(name) return root and (root .. "/" .. component(name) .. ".json") end
local function read(name)
  if cache[name] then return cache[name] end
  local file = path(name) and io.open(path(name), "rb")
  local entries = {}
  if file then
    local text = file:read("*a"); file:close()
    local ok, decoded = pcall(remuda.json.decode, text)
    if ok and type(decoded) == "table" then
      for _, row in ipairs(decoded) do
        if type(row) == "table" and type(row.time) == "number" then entries[#entries + 1] = row end
      end
    end
  end
  while #entries > LIMIT do table.remove(entries, 1) end
  cache[name] = entries
  return entries
end
local function load_names()
  if names then return names end
  names = {}
  local file = root and io.open(root .. "/index.json", "rb")
  if file then
    local text = file:read("*a"); file:close()
    local ok, decoded = pcall(remuda.json.decode, text)
    if ok and type(decoded) == "table" then
      for _, name in ipairs(decoded) do if safe_name(name) then names[#names + 1] = name end end
    end
  end
  return names
end
local function persist(name)
  if not root then return end
  pcall(remuda.mkdir, root:match("^(.*)/[^/]+$"))
  if remuda.fs and type(remuda.fs.mkdir_new) == "function" then
    pcall(remuda.fs.mkdir_new, root)
  else
    pcall(remuda.mkdir, root)
  end
  local encoded = remuda.json.encode(remuda.json.array(cache[name]))
  if encoded and remuda.fs and type(remuda.fs.write_atomic) == "function" then
    pcall(remuda.fs.write_atomic, path(name), encoded, { private = true })
  end
  local current, found = load_names(), false
  for i, value in ipairs(current) do
    if value == name then table.remove(current, i); found = true; break end
  end
  current[#current + 1] = name
  while #current > INDEX_LIMIT do table.remove(current, 1) end
  local index = remuda.json.encode(remuda.json.array(current))
  if index and remuda.fs and type(remuda.fs.write_atomic) == "function" then
    pcall(remuda.fs.write_atomic, root .. "/index.json", index, { private = true })
  end
end
local M = {}
function M.record(name, info)
  if not safe_name(name) then return false end
  info = type(info) == "table" and info or {}
  local entries = read(name)
  local row = { time = (config.now or os.time)() }
  for _, key in ipairs({ "reason", "exit_code", "signal", "signal_name", "instance_id" }) do
    local value = info[key]
    if key == "exit_code" or key == "signal" then value = tonumber(value) end
    if type(value) == "string" or type(value) == "number" then row[key] = value end
  end
  entries[#entries + 1] = row
  while #entries > LIMIT do table.remove(entries, 1) end
  persist(name)
  return true
end
function M.list(name)
  if not safe_name(name) then return {} end
  local out = {}
  for i, row in ipairs(read(name)) do out[i] = row end
  return out
end
function M.all()
  local out = {}
  for _, name in ipairs(load_names()) do
    local entries = read(name)
    if #entries > 0 then out[#out + 1] = { name = name, entry = entries[#entries] } end
  end
  return out
end
function M.recent(limit)
  local out = {}
  for _, name in ipairs(load_names()) do
    for _, entry in ipairs(read(name)) do out[#out + 1] = { name = name, entry = entry } end
  end
  table.sort(out, function(a, b) return a.entry.time > b.entry.time end)
  while #out > (tonumber(limit) or 5) do table.remove(out) end
  return out
end
function M.age(at)
  local seconds = math.max(0, (config.now or os.time)() - (tonumber(at) or (config.now or os.time)()))
  if seconds < 60 then return seconds .. "s ago" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
  return math.floor(seconds / 86400) .. "d ago"
end
remuda._butler_exit_ring = M
return M
