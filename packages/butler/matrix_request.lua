-- L1 Matrix request vocabulary: auth + trust + limit + allow + request.
-- All network access is delegated to the async remuda.http primitive.
local butler = remuda.butler or {}
remuda.butler = butler
local matrix = butler.matrix or {}
butler.matrix = matrix
local JSON_NULL = matrix.json_null or {}
matrix.json_null = JSON_NULL
local JSON_ARRAY = {}

function matrix.json_array(values)
  return setmetatable(values or {}, JSON_ARRAY)
end

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

local function config()
  local paths = remuda._butler_matrix_config
  if not paths or not paths.token_path or not paths.config_path then
    return nil, "Matrix is not configured"
  end
  local token, token_error = read_file(paths.token_path, "token")
  if not token then return nil, token_error end
  token = trim(token)
  if token == "" then return nil, "Matrix token is empty" end
  local contents, config_error = read_file(paths.config_path, "config")
  if not contents then return nil, config_error end
  local lines = {}
  for line in (contents .. "\n"):gmatch("([^\r\n]*)\r?\n") do lines[#lines + 1] = line end
  if #lines < 3 or trim(lines[1] or "") == "" or trim(lines[2] or "") == "" then
    return nil, "Matrix config requires homeserver, room ID, and user ID"
  end
  local opts = {}
  for i = 5, #lines do
    local key, value = lines[i]:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
    if key then opts[trim(key)] = trim(value) end
  end
  local base = trim(lines[1]):gsub("/+$", "")
  local ca_file, pin_hex = opts.ca_file, opts.pin_sha256
  if base:match("^https://") and not ca_file and not pin_hex then
    return nil, "HTTPS Matrix homeserver requires ca_file=PATH or pin_sha256=HEX"
  end
  local pin
  if pin_hex and pin_hex ~= "" then
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
  return {
    base = base, room = trim(lines[2]), token = token,
    ca_file = ca_file and ca_file ~= "" and ca_file or nil,
    pin = pin,
  }
end

local function once(callback)
  local called = false
  return function(value)
    if called then return end
    called = true
    if callback then callback(value) end
  end
end

local function percent_encode(value)
  return (tostring(value):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

local function report_error(callback, message)
  callback({ error = message })
end

local function utf8_char(codepoint)
  if codepoint <= 0x7f then return string.char(codepoint) end
  if codepoint <= 0x7ff then
    return string.char(0xc0 + math.floor(codepoint / 64), 0x80 + codepoint % 64)
  end
  if codepoint <= 0xffff then
    return string.char(0xe0 + math.floor(codepoint / 4096),
      0x80 + math.floor(codepoint / 64) % 64, 0x80 + codepoint % 64)
  end
  return string.char(0xf0 + math.floor(codepoint / 262144),
    0x80 + math.floor(codepoint / 4096) % 64,
    0x80 + math.floor(codepoint / 64) % 64, 0x80 + codepoint % 64)
end

local function decode_json(source)
  local at, length = 1, #source
  local null = JSON_NULL
  local function skip_space()
    while at <= length and source:sub(at, at):match("%s") do at = at + 1 end
  end
  local function parse_string()
    if source:sub(at, at) ~= '"' then error("expected JSON string") end
    at = at + 1
    local chunks = {}
    while at <= length do
      local byte = source:byte(at)
      if byte == 34 then at = at + 1; return table.concat(chunks) end
      if byte == 92 then
        at = at + 1
        local escape = source:sub(at, at)
        local mapped = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
          b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[escape]
        if mapped then
          chunks[#chunks + 1] = mapped
          at = at + 1
        elseif escape == "u" then
          local hex = source:sub(at + 1, at + 4)
          local codepoint = tonumber(hex, 16)
          if not codepoint or #hex ~= 4 then error("invalid JSON unicode escape") end
          at = at + 5
          if codepoint >= 0xd800 and codepoint <= 0xdbff then
            if source:sub(at, at + 1) ~= "\\u" then error("invalid JSON surrogate pair") end
            local low = tonumber(source:sub(at + 2, at + 5), 16)
            if not low or low < 0xdc00 or low > 0xdfff then error("invalid JSON surrogate pair") end
            codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + low - 0xdc00
            at = at + 6
          elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
            error("unexpected JSON low surrogate")
          end
          chunks[#chunks + 1] = utf8_char(codepoint)
        else
          error("invalid JSON escape")
        end
      else
        if byte < 32 then error("control byte in JSON string") end
        chunks[#chunks + 1] = source:sub(at, at)
        at = at + 1
      end
    end
    error("unterminated JSON string")
  end
  local parse_value
  local function parse_array()
    at = at + 1
    skip_space()
    local result = {}
    if source:sub(at, at) == "]" then at = at + 1; return setmetatable(result, JSON_ARRAY) end
    while true do
      result[#result + 1] = parse_value()
      skip_space()
      local char = source:sub(at, at)
      if char == "]" then at = at + 1; return setmetatable(result, JSON_ARRAY) end
      if char ~= "," then error("expected comma in JSON array") end
      at = at + 1
      skip_space()
    end
  end
  local function parse_object()
    at = at + 1
    skip_space()
    local result = {}
    if source:sub(at, at) == "}" then at = at + 1; return result end
    while true do
      local key = parse_string()
      skip_space()
      if source:sub(at, at) ~= ":" then error("expected colon in JSON object") end
      at = at + 1
      skip_space()
      result[key] = parse_value()
      skip_space()
      local char = source:sub(at, at)
      if char == "}" then at = at + 1; return result end
      if char ~= "," then error("expected comma in JSON object") end
      at = at + 1
      skip_space()
    end
  end
  parse_value = function()
    skip_space()
    local char = source:sub(at, at)
    if char == '"' then return parse_string() end
    if char == "{" then return parse_object() end
    if char == "[" then return parse_array() end
    if source:sub(at, at + 3) == "true" then at = at + 4; return true end
    if source:sub(at, at + 4) == "false" then at = at + 5; return false end
    if source:sub(at, at + 3) == "null" then at = at + 4; return null end
    local number = source:sub(at):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
    if number and number ~= "" and not number:match("[%.eE%+%-]$") then
      local value = tonumber(number)
      if value then at = at + #number; return value end
    end
    error("invalid JSON value")
  end
  local value = parse_value()
  skip_space()
  if at <= length then error("trailing data after JSON value") end
  return value
end

local function encode_json(value, active)
  local kind = type(value)
  if value == JSON_NULL then return "null" end
  if kind == "nil" then return "null" end
  if kind == "boolean" or kind == "number" then
    if kind == "number" and (value ~= value or value == math.huge or value == -math.huge) then
      error("cannot encode non-finite JSON number")
    end
    return tostring(value)
  end
  if kind == "string" then
    local escaped = value:gsub('["\\%z\1-\31]', function(char)
      local replacements = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b",
        ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
      return replacements[char] or string.format("\\u%04x", char:byte())
    end)
    return '"' .. escaped .. '"'
  end
  if kind ~= "table" then error("unsupported JSON value type: " .. kind) end
  active = active or {}
  if active[value] then error("cycle in JSON value") end
  active[value] = true
  local n, is_array = #value, getmetatable(value) == JSON_ARRAY
  if not is_array and n > 0 then
    is_array = true
    for key in pairs(value) do
      if type(key) ~= "number" or key < 1 or key > n or key % 1 ~= 0 then
        is_array = false
        break
      end
    end
  end
  local parts = {}
  if is_array then
    for i = 1, n do parts[i] = encode_json(value[i], active) end
    active[value] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then error("JSON object keys must be strings") end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    parts[#parts + 1] = encode_json(key, active) .. ":" .. encode_json(value[key], active)
  end
  active[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

function matrix.decode_json(source)
  if type(source) ~= "string" then return nil, "JSON input must be a byte string" end
  local ok, value = pcall(decode_json, source)
  if not ok then return nil, tostring(value) end
  return value
end

function matrix.encode_json(value)
  local ok, encoded = pcall(encode_json, value)
  if not ok then return nil, tostring(encoded) end
  return encoded
end

function matrix.request_json(args, on_done)
  local done = once(on_done)
  return matrix.request(args, function(result)
    if result.error then return done(result) end
    local value, decode_error
    if not result.body or result.body == "" then value = {}
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
      if not item.cancelled then item.dispatch(item) end
    end
    return
  end
  timer = remuda.schedule({ every = interval, run = function()
    tokens = math.min(burst, tokens + 1)
    if #queue > 0 and tokens > 0 then
      local item = table.remove(queue, 1)
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

local function enqueue(dispatch)
  local item = { dispatch = dispatch, cancelled = false }
  local handle = { cancel = function()
    item.cancelled = true
    if item.transport then item.transport:cancel() end
  end }
  item.handle = handle
  if tokens > 0 then
    tokens = tokens - 1
    dispatch(item)
  else
    queue[#queue + 1] = item
    schedule_queue()
  end
  return handle
end

function matrix.request(args, on_done)
  args = args or {}
  local done = once(on_done)
  local conf, conf_error = config()
  if not conf then report_error(done, conf_error); return { cancel = function() end } end
  if type(args.method) ~= "string" or type(args.path) ~= "string" then
    report_error(done, "Matrix request requires method and path")
    return { cancel = function() end }
  end
  if args.room ~= nil and args.room ~= conf.room then
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
  local path = args.path:sub(1, 1) == "/" and args.path or ("/" .. args.path)
  local headers = {}
  for name, value in pairs(args.headers or {}) do headers[name] = value end
  headers.Accept = "application/json"
  headers.Authorization = "Bearer " .. conf.token
  local spec = {
    method = args.method:upper(), url = conf.base .. path, headers = headers,
    body = body, timeout = timeout, connect_timeout = math.min(10, timeout),
    max_bytes = max_bytes, ca_file = conf.ca_file, pin = conf.pin,
    callback = function(result)
      if result.error then return done({ error = result.error }) end
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
  return enqueue(dispatch)
end

function matrix.same_room(room, event_id, on_done)
  local done = once(on_done)
  if room ~= (select(1, config()) or {}).room then
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
