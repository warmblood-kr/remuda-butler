-- L1 Matrix request vocabulary: auth + trust + limit + allow + request.
-- All network access is delegated to the async remuda.http primitive.
local butler = remuda.butler or {}
remuda.butler = butler
local matrix = butler.matrix or {}
butler.matrix = matrix
local json = assert(remuda.json, "Matrix requires core remuda.json")
matrix.json_null = json.null
matrix.json_array = json.array

local MiB = 1024 * 1024
local MAX_REQUEST_BYTES = 20 * MiB
local DEFAULT_RESPONSE_BYTES = MiB
local queue, timer = {}, nil
local tokens, burst = 1, 1
local interval = tonumber(os.getenv("REMUDA_BUTLER_MATRIX_RATE_INTERVAL")) or 0.25
if interval < 0 then interval = 0 end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path, what)
  local file, err = io.open(path, "rb")
  if not file then return nil, "cannot read Matrix " .. what .. ": " .. tostring(err) end
  local value = file:read("*a")
  file:close()
  return value
end

-- The request client and inbound relay must interpret the same on-disk
-- settings. Normalize every line here so CRLF and surrounding whitespace do
-- not change room or sender authorization decisions.
function matrix.read_config(path)
  local contents, err = read_file(path, "config")
  if not contents then return nil, err end
  local lines = {}
  for line in (contents .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    lines[#lines + 1] = trim(line)
  end
  if #lines < 3 or lines[1] == "" or lines[2] == "" or lines[3] == "" then
    return nil, "Matrix config requires homeserver, room ID, and user ID"
  end
  local base = lines[1]:gsub("/+$", "")
  if not base:match("^https?://") then return nil, "Matrix homeserver must use http:// or https://" end
  local allowed = {}
  for sender in (lines[4] or ""):gmatch("[^,]+") do
    sender = trim(sender)
    if sender ~= "" then allowed[sender] = true end
  end
  local opts = {}
  for i = 5, #lines do
    local key, value = lines[i]:match("^([^=]+)=(.*)$")
    if key then opts[trim(key)] = trim(value) end
  end
  local mode = (lines[5] or ""):lower()
  local timeout = tonumber(lines[6]) or 30000
  local ca_file, pin_hex = opts.ca_file, opts.pin_sha256
  if ca_file == "" then ca_file = nil end
  if pin_hex == "" then pin_hex = nil end
  local pin
  if pin_hex then
    local hex = pin_hex:gsub(":", ""):lower()
    if #hex ~= 64 or not hex:match("^%x+$") then
      return nil, "Matrix pin_sha256 must be 64 hexadecimal characters"
    end
    local binary = hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local encoded = {}
    for i = 1, #binary, 3 do
      local a, b, c = binary:byte(i, i + 2)
      b, c = b or 0, c or 0
      local n = a * 65536 + b * 256 + c
      encoded[#encoded + 1] = alphabet:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        .. alphabet:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        .. (i + 1 <= #binary and alphabet:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
        .. (i + 2 <= #binary and alphabet:sub(n % 64 + 1, n % 64 + 1) or "=")
    end
    pin = "sha256/" .. table.concat(encoded)
  end
  local butler_senders = {}
  for sender in ((opts.butler_senders or "") .. ","):gmatch("([^,]*),") do
    sender = trim(sender)
    if sender ~= "" then butler_senders[sender] = true end
  end
  local all_room = opts.all_room
  if all_room == "" then all_room = nil end
  if all_room == lines[2] then return nil, "HOME and ALL-BUTLERS rooms must be different" end
  local rooms = { [lines[2]] = "home" }
  if all_room then
    if mode == "1" or mode == "true" or mode == "messages" or mode == "fallback" then
      return nil, "ALL-BUTLERS room requires /sync; messages fallback supports HOME only"
    end
    rooms[all_room] = "all"
  end
  return {
    base = base, room = lines[2], home_room = lines[2], all_room = all_room,
    rooms = rooms,
    self_mxid = lines[3], allowed_senders = allowed,
    butler_senders = butler_senders,
    use_messages = mode == "1" or mode == "true" or mode == "messages" or mode == "fallback",
    timeout_ms = math.max(1, timeout), ca_file = ca_file, pin = pin,
  }
end

local function config()
  local paths = remuda._butler_matrix_config
  if not paths or not paths.token_path or not paths.config_path then
    return nil, "Matrix is not configured"
  end
  local token, token_error = read_file(paths.token_path, "token")
  if not token then return nil, token_error end
  token = trim(token)
  if token == "" then return nil, "Matrix token is empty" end
  local parsed, config_error = matrix.read_config(paths.config_path)
  if not parsed then return nil, config_error end
  if parsed.base:match("^https://") and not parsed.ca_file and not parsed.pin then
    return nil, "HTTPS Matrix homeserver requires ca_file=PATH or pin_sha256=HEX"
  end
  parsed.token = token
  return parsed
end

-- Read composites use the configured room when --room is omitted. Expose only
-- the allowlisted room, never the token or transport settings.
function matrix.configured_room()
  local conf, err = config()
  if not conf then return nil, err end
  return conf.room
end

function matrix.room_allowed(room)
  local conf, err = config()
  if not conf then return false, err end
  return room == conf.home_room or (conf.all_room ~= nil and room == conf.all_room)
end

function matrix.room_kind(room)
  local conf, err = config()
  if not conf then return nil, err end
  return conf.rooms[room]
end

function matrix.is_agent_mxid(mxid)
  local localpart = type(mxid) == "string" and mxid:match("^@([^:]+):")
  if localpart and (localpart:match("^agent%-") or localpart:match("^butler%-")) then return true end
  local conf = config()
  return conf ~= nil and (mxid == conf.self_mxid or conf.butler_senders[mxid] == true)
end

matrix.once = matrix.once or function(callback)
  local called = false
  return function(value)
    if called then return end
    called = true
    if callback then callback(value) end
  end
end
local once = matrix.once

matrix.path_component = matrix.path_component or function(value)
  return (tostring(value):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", char:byte())
  end))
end
local percent_encode = matrix.path_component

local function percent_decode(value)
  local remainder = value:gsub("%%[%x][%x]", "")
  if remainder:find("%%") then return nil end
  local decoded = value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  return decoded
end

local function report_error(callback, message)
  callback({ error = message })
end

-- Keep the Matrix result convention while delegating the actual codec to core.
matrix.decode_json = json.decode
matrix.encode_json = function(value)
  local ok, encoded = pcall(json.encode, value)
  if not ok then return nil, tostring(encoded) end
  return encoded
end

function matrix.request_json(args, on_done)
  local done = once(on_done)
  return matrix.request(args, function(result)
    if result.error then return done(result) end
    local value, decode_error
    if not result.body or result.body == "" then value = json.object({})
    else value, decode_error = matrix.decode_json(result.body) end
    if value == nil and decode_error then
      return done({ error = "invalid Matrix JSON response: " .. decode_error,
        status = result.status, headers = result.headers, body = result.body })
    end
    result.json = value
    done(result)
  end)
end

local function schedule_queue()
  if timer or #queue == 0 then return end
  if interval == 0 then
    while #queue > 0 do
      local item = table.remove(queue, 1)
      item.in_queue = false
      if not item.cancelled then item.dispatch(item) end
    end
    return
  end
  timer = remuda.schedule({ every = interval, run = function()
    tokens = math.min(burst, tokens + 1)
    if #queue > 0 and tokens > 0 then
      local item = table.remove(queue, 1)
      item.in_queue = false
      tokens = tokens - 1
      if not item.cancelled then item.dispatch(item) end
    end
    if #queue == 0 then
      local current = timer
      timer = nil
      if current then remuda.cancel(current) end
      return
    end
  end })
end

local function enqueue(dispatch, done)
  local item = { dispatch = dispatch, cancelled = false }
  local handle = { cancel = function()
    if item.cancelled or item.completed then return end
    item.cancelled = true
    if item.in_queue then
      for index, queued in ipairs(queue) do
        if queued == item then table.remove(queue, index); break end
      end
      item.in_queue = false
      item.completed = true
      done({ error = "cancelled" })
      return
    end
    if item.transport then item.transport:cancel() end
  end }
  item.handle = handle
  if tokens > 0 then
    tokens = tokens - 1
    dispatch(item)
  else
    item.in_queue = true
    queue[#queue + 1] = item
    schedule_queue()
  end
  return handle
end

function matrix.request(args, on_done)
  args = args or {}
  local done = once(on_done)
  if type(args) ~= "table" then
    report_error(done, "Matrix request options must be a table")
    return { cancel = function() end }
  end
  local conf, conf_error = config()
  if not conf then report_error(done, conf_error); return { cancel = function() end } end
  if type(args.method) ~= "string" or type(args.path) ~= "string" then
    report_error(done, "Matrix request requires method and path")
    return { cancel = function() end }
  end
  local method = args.method:upper()
  if method ~= "GET" and method ~= "PUT" and method ~= "POST" then
    report_error(done, "Matrix request method must be GET, PUT, or POST")
    return { cancel = function() end }
  end
  local path = args.path:sub(1, 1) == "/" and args.path or ("/" .. args.path)
  local encoded_room = path:match("/rooms/([^/?]+)")
  if encoded_room then
    local path_room = percent_decode(encoded_room)
    if not path_room or (path_room ~= conf.home_room and path_room ~= conf.all_room) then
      report_error(done, "room is outside the configured Matrix allowlist")
      return { cancel = function() end }
    end
  end
  if args.room ~= nil and args.room ~= conf.home_room and args.room ~= conf.all_room then
    report_error(done, "room is outside the configured Matrix allowlist")
    return { cancel = function() end }
  end
  local body = args.body
  if body ~= nil and type(body) ~= "string" then
    report_error(done, "Matrix request body must be a byte string")
    return { cancel = function() end }
  end
  if body and #body > MAX_REQUEST_BYTES then
    report_error(done, "Matrix request body exceeds 20 MiB")
    return { cancel = function() end }
  end
  local timeout = tonumber(args.timeout) or 15
  local max_bytes = tonumber(args.max_bytes) or DEFAULT_RESPONSE_BYTES
  if timeout <= 0 or max_bytes <= 0 then
    report_error(done, "Matrix timeout and max_bytes must be positive")
    return { cancel = function() end }
  end
  local headers = {}
  if args.headers ~= nil and type(args.headers) ~= "table" then
    report_error(done, "Matrix request headers must be a table")
    return { cancel = function() end }
  end
  for name, value in pairs(args.headers or {}) do
    if type(name) ~= "string" or type(value) ~= "string" then
      report_error(done, "Matrix request header names and values must be strings")
      return { cancel = function() end }
    end
    local lower = name:lower()
    if lower ~= "authorization" and lower ~= "host"
      and lower ~= "content-length" and lower ~= "transfer-encoding" then
      headers[name] = value
    end
  end
  if not headers.Accept and not headers.accept then headers.Accept = "application/json" end
  headers.Authorization = "Bearer " .. conf.token
  local spec = {
    method = method, url = conf.base .. path, headers = headers,
    body = body, timeout = timeout, connect_timeout = math.min(10, timeout),
    max_bytes = max_bytes, ca_file = conf.ca_file, pin = conf.pin,
    callback = function(result)
      if result.error then return done({ error = result.error }) end
      result.headers = json.object(type(result.headers) == "table" and result.headers or {})
      if result.status and (result.status < 200 or result.status >= 300) then
        return done({ error = "Matrix HTTP " .. result.status, status = result.status,
          headers = result.headers, body = result.body })
      end
      done(result)
    end,
  }
  local dispatch = function(item)
    if item and item.cancelled then return end
    item.transport = remuda.http.request(spec)
  end
  return enqueue(dispatch, done)
end

function matrix.same_room(room, event_id, on_done)
  local done = once(on_done)
  if type(room) ~= "string" or type(event_id) ~= "string" or event_id == "" then
    report_error(done, "same_room requires room and event_id")
    return { cancel = function() end }
  end
  local conf, conf_error = config()
  if not conf then
    report_error(done, conf_error)
    return { cancel = function() end }
  end
  if room ~= conf.room then
    report_error(done, "room is outside the configured Matrix allowlist")
    return { cancel = function() end }
  end
  local path = "/_matrix/client/v3/rooms/" .. percent_encode(room)
    .. "/context/" .. percent_encode(event_id)
  return matrix.request({ method = "GET", path = path, room = room,
    timeout = 15, max_bytes = DEFAULT_RESPONSE_BYTES }, function(result)
      if result.error then return done(result) end
      local response, decode_error = matrix.decode_json(result.body or "")
      if not response and decode_error then
        return done({ error = "invalid Matrix context JSON: " .. decode_error })
      end
      local event = type(response) == "table" and response.event or nil
      done(type(event) == "table" and event.room_id == room)
    end)
end

return matrix
