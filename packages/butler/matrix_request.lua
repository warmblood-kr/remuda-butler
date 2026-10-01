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

local function file_readable(path)
  if type(path) ~= "string" or path == "" then return false end
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end
matrix.shell_quote = shell_quote

local function format_character(cp)
  return cp == 0x00ad or cp == 0x061c or (cp >= 0x0600 and cp <= 0x0605)
    or cp == 0x06dd or cp == 0x070f or (cp >= 0x0890 and cp <= 0x0891)
    or cp == 0x08e2 or cp == 0x180e or (cp >= 0x200b and cp <= 0x200f)
    or (cp >= 0x202a and cp <= 0x202e) or cp == 0x2028 or cp == 0x2029
    or cp == 0x2060 or (cp >= 0x2061 and cp <= 0x206f) or cp == 0xfeff
    or (cp >= 0xfff9 and cp <= 0xfffb) or cp == 0x110bd or cp == 0x110cd
    or (cp >= 0x13430 and cp <= 0x1343f) or (cp >= 0x1bca0 and cp <= 0x1bca3)
    or (cp >= 0x1d173 and cp <= 0x1d17a) or cp == 0xe0001
    or (cp >= 0xe0020 and cp <= 0xe007f)
end

local function sanitize_directory_text(value, limit)
  if type(value) ~= "string" then value = tostring(value or "") end
  limit = limit or 128
  local out, count, at = {}, 0, 1
  while at <= #value and count < limit do
    local first = value:byte(at)
    local width, cp
    if first < 0x80 then width, cp = 1, first
    elseif first >= 0xc2 and first <= 0xdf then width, cp = 2, first - 0xc0
    elseif first >= 0xe0 and first <= 0xef then width, cp = 3, first - 0xe0
    elseif first >= 0xf0 and first <= 0xf4 then width, cp = 4, first - 0xf0
    else width, cp = 1, 0xfffd end
    if width > 1 then
      if at + width - 1 > #value then width, cp = 1, 0xfffd
      else
        for offset = 1, width - 1 do
          local byte = value:byte(at + offset)
          if byte < 0x80 or byte > 0xbf then width, cp = 1, 0xfffd; break end
          cp = cp * 64 + byte - 0x80
        end
        if (width == 2 and cp < 0x80) or (width == 3 and cp < 0x800)
          or (width == 4 and (cp < 0x10000 or cp > 0x10ffff))
          or (cp >= 0xd800 and cp <= 0xdfff) then
          width, cp = 1, 0xfffd
        end
      end
    end
    if not (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or format_character(cp)) then
      out[#out + 1] = value:sub(at, at + width - 1)
      count = count + 1
    end
    at = at + width
  end
  return table.concat(out)
end
matrix.sanitize_directory_text = sanitize_directory_text

local function shown_path(path, override)
  if type(path) == "string" and path ~= "" then return path end
  return "<unresolved; set " .. override .. " or HOME/XDG_CONFIG_HOME>"
end

function matrix.configuration_guidance()
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  local token_path, config_path = paths.token_path, paths.config_path
  local missing = {}
  if not file_readable(token_path) then
    missing[#missing + 1] = "  Missing token file: " .. shown_path(token_path, "REMUDA_BUTLER_TOKEN")
  end
  if not file_readable(config_path) then
    missing[#missing + 1] = "  Missing config file: " .. shown_path(config_path, "REMUDA_BUTLER_CONFIG")
  end
  if #missing == 0 then return nil end

  local token_display = type(token_path) == "string" and token_path ~= "" and shell_quote(token_path) or "<token-path>"
  local config_display = type(config_path) == "string" and config_path ~= "" and shell_quote(config_path) or "<config-path>"
  local lines = {
    "Matrix setup is incomplete; resolved paths use REMUDA_BUTLER_TOKEN/REMUDA_BUTLER_CONFIG or the XDG default:",
    table.concat(missing, "\n"),
    "Minimal config example (one item per line):",
    "  https://<homeserver-url>",
    "  !<room-id>:<server-name>",
    "  @<your-user>:<server-name>",
    "  @<allowed-sender>:<server-name>",
    "Lines 1-4 are homeserver URL, room ID, own MXID, and comma-separated allowed senders.",
    "Further config lines are optional; see docs/butler.md.",
    "Protect both files: chmod 600 " .. token_display .. " " .. config_display,
    "Next: remuda butler matrix setup",
  }
  return table.concat(lines, "\n")
end

-- The request client and inbound relay must interpret the same on-disk
-- settings. Normalize every line here so CRLF and surrounding whitespace do
-- not change room or sender authorization decisions.
local warned_config_lines = {}
local function warn_invalid_config_line(path, line_number, key, value)
  local warning_key = tostring(path) .. "\0" .. tostring(line_number) .. "\0" .. key .. "\0" .. value
  if warned_config_lines[warning_key] then return end
  warned_config_lines[warning_key] = true
  local safe_value = sanitize_directory_text(value, 128)
  pcall(function()
    io.stderr:write("butler ignored invalid Matrix config line " .. tostring(line_number)
      .. " (" .. key .. "=" .. safe_value .. ")\n")
  end)
end

local function config_valid_room_id(value)
  return type(value) == "string" and value:match("^!%S+:%S+$") ~= nil
end

local function config_valid_room_alias(value)
  if type(value) ~= "string" or #value > 255 or value:find("[%c%s/]") then return false end
  local localpart, server = value:match("^#([^:]+):(.+)$")
  return localpart ~= nil and localpart ~= "" and server ~= nil and server ~= ""
end

local function config_valid_server(value)
  if type(value) ~= "string" or value == "" or #value > 260 or value:find("[%c%s/@#?]") then return false end
  local address, port = value:match("^%[([%x:]+)%]:(%d+)$")
  if not address then address = value:match("^%[([%x:]+)%]$") end
  if address then
    if not address:find(":", 1, true) then return false end
    if port and (tonumber(port) < 1 or tonumber(port) > 65535) then return false end
    return true
  end
  local host, numeric_port = value:match("^([^:]+):(%d+)$")
  if not host then
    host = value:match("^([^:]+)$")
    numeric_port = ""
  end
  if not host or host == "" or #host > 253 or host:find("%.%.") then return false end
  if host:sub(1, 1) == "." or host:sub(-1) == "." then return false end
  if numeric_port ~= "" and (tonumber(numeric_port) < 1 or tonumber(numeric_port) > 65535) then return false end
  for label in host:gmatch("[^.]+") do
    if #label > 63 or (not label:match("^[A-Za-z0-9][A-Za-z0-9%-]*[A-Za-z0-9]$")
      and not label:match("^[A-Za-z0-9]$")) then return false end
  end
  return true
end

local function normalize_server_name(value)
  if type(value) ~= "string" then return value end
  local host, port
  if value:sub(1, 1) == "[" then
    host, port = value:match("^(%b[]):(%d+)$")
    if not host then host = value end
  else
    host, port = value:match("^([^:]+):(%d+)$")
    if not host then host = value end
  end
  host = host:lower()
  if host:sub(-1) == "." then host = host:sub(1, -2) end
  -- IPv6 literals are compared textually after lowercasing; equivalent spellings are not canonicalized.
  return port and (host .. ":" .. port) or host
end
local function config_valid_mxid(value)
  if type(value) ~= "string" or #value > 512 then return false end
  local localpart, server = value:match("^@([^:%s]+):([^%s]+)$")
  return localpart ~= nil and localpart ~= "" and server ~= nil and config_valid_server(server)
end
matrix.valid_server_name = config_valid_server

local function read_config(path)
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
  local opts, extra_rooms, deny_room_ids, deny_room_aliases, deny_servers = {}, {}, {}, {}, {}
  local room_mode = "allowlist"
  for i = 5, #lines do
    local key, value = lines[i]:match("^([^=]+)=(.*)$")
    if key then
      key, value = trim(key), trim(value)
      if key == "room" then
        local room = value:match("^(%S+)")
        local how = value:match("%s+how=(%S+)") or "operator"
        local alias = value:match("%s+alias=(%S+)")
        local inviter = value:match("%s+inviter=(%S+)")
        if inviter then inviter = sanitize_directory_text(inviter, 128) end
        if inviter and not config_valid_mxid(inviter) then inviter = nil end
        if room and config_valid_room_id(room) then
          extra_rooms[#extra_rooms + 1] = { room = room, how = how, alias = alias, inviter = inviter }
        end
      elseif key == "rooms" then
        if value == "open" or value == "allowlist" then
          room_mode = value
        else
          warn_invalid_config_line(path, i, key, value)
        end
      elseif key == "deny_room" then
        if config_valid_room_id(value) then
          deny_room_ids[value] = true
        elseif config_valid_room_alias(value) then
          deny_room_aliases[value] = true
        else
          warn_invalid_config_line(path, i, key, value)
        end
      elseif key == "deny_server" then
        local server = normalize_server_name(value)
        if config_valid_server(server) then
          deny_servers[server] = true
        else
          warn_invalid_config_line(path, i, key, value)
        end
      else
        opts[key] = value
      end
    end
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
  local room_how, room_aliases, room_inviters = {}, {}, {}
  if all_room then
    if mode == "1" or mode == "true" or mode == "messages" or mode == "fallback" then
      return nil, "ALL-BUTLERS room requires /sync; messages fallback supports HOME only"
    end
    rooms[all_room] = "all"
  end
  for _, extra in ipairs(extra_rooms) do
    if extra.room ~= lines[2] and extra.room ~= all_room then
      rooms[extra.room] = "joined"
      room_how[extra.room] = extra.how
      room_inviters[extra.room] = extra.inviter
      if extra.alias and type(matrix.valid_room_alias) == "function" and matrix.valid_room_alias(extra.alias) then
        room_aliases[extra.room] = extra.alias
      end
    end
  end
  return {
    base = base, room = lines[2], home_room = lines[2], all_room = all_room,
    rooms = rooms, room_how = room_how, room_aliases = room_aliases, room_inviters = room_inviters,
    rooms_mode = room_mode, deny_room_ids = deny_room_ids,
    deny_room_aliases = deny_room_aliases, deny_servers = deny_servers,
    self_mxid = lines[3], allowed_senders = allowed,
    butler_senders = butler_senders,
    use_messages = mode == "1" or mode == "true" or mode == "messages" or mode == "fallback",
    timeout_ms = math.max(1, timeout), ca_file = ca_file, pin = pin,
  }
end
matrix.read_config = read_config

local function valid_room_id(room)
  return type(room) == "string" and room:match("^!%S+:%S+$") ~= nil
end
matrix.valid_room_id = valid_room_id

local function valid_room_alias(alias)
  if type(alias) ~= "string" or #alias > 255 or alias:find("[%c%s/]" ) then return false end
  local localpart, server = alias:match("^#([^:]+):(.+)$")
  return localpart ~= nil and localpart ~= "" and server ~= nil and server ~= ""
end
matrix.valid_room_alias = valid_room_alias

local function server_parts(value, prefix)
  if type(value) ~= "string" then return nil end
  local server = value:match("^" .. prefix .. "[^:]+:(.+)$")
  if not server or server == "" then return nil end
  local host
  if server:sub(1, 1) == "[" then
    host = server:match("^(%b[]):%d+$") or server
  else
    host = server:match("^([^:]+):%d+$") or server
  end
  return normalize_server_name(server), normalize_server_name(host)
end

function matrix.invite_is_denied(conf, room_id, alias, inviter)
  if type(conf) ~= "table" then return false end
  local deny_room_ids = type(conf.deny_room_ids) == "table" and conf.deny_room_ids or {}
  local deny_room_aliases = type(conf.deny_room_aliases) == "table" and conf.deny_room_aliases or {}
  local deny_servers = type(conf.deny_servers) == "table" and conf.deny_servers or {}
  if type(room_id) == "string" and deny_room_ids[room_id] then return true end
  if type(alias) == "string" and deny_room_aliases[alias] then return true end
  if type(alias) == "string" then
    local alias_localpart, alias_server = alias:match("^#([^:]+):(.+)$")
    if alias_localpart and alias_server then
      for denied_alias in pairs(deny_room_aliases) do
        local denied_localpart, denied_server = denied_alias:match("^#([^:]+):(.+)$")
        if denied_localpart == alias_localpart and denied_server
          and normalize_server_name(denied_server) == normalize_server_name(alias_server) then
          return true
        end
      end
    end
  end
  local room_server, room_host = server_parts(room_id, "!")
  local inviter_server, inviter_host = server_parts(inviter, "@")
  local alias_server, alias_host = server_parts(alias, "#")
  if (room_server and (deny_servers[room_server] or deny_servers[room_host]))
    or (inviter_server and (deny_servers[inviter_server] or deny_servers[inviter_host]))
    or (alias_server and (deny_servers[alias_server] or deny_servers[alias_host])) then return true end
  return false
end

local function write_config_text(path, text)
  if not remuda.fs or type(remuda.fs.write_atomic) ~= "function" then
    return nil, "atomic Matrix config writes are unavailable"
  end
  local ok, wrote, err = pcall(remuda.fs.write_atomic, path, text, { private = true })
  if not ok then return nil, tostring(wrote) end
  if not wrote then return nil, tostring(err or "could not write Matrix config") end
  return true
end

local function each_raw_line(contents, visit)
  local start = 1
  while start <= #contents do
    local newline = contents:find("\n", start, true)
    local finish = newline or (#contents + 1)
    local raw = contents:sub(start, finish - 1)
    local line = raw:gsub("\r$", "")
    visit(raw, line, newline and "\n" or "")
    start = finish + 1
  end
end

local function room_line_id(line)
  return line:match("^%s*room=(%S+)")
end

function matrix.config_add_room(path, room, how, alias, inviter)
  if not valid_room_id(room) then
    return nil, "invalid Matrix room ID: room IDs start with ! (Element: Room settings > Advanced tab (not General) > Internal room ID. Element X may not show it; use the #alias instead.)."
  end
  if alias ~= nil and not valid_room_alias(alias) then return nil, "invalid Matrix room alias" end
  if inviter ~= nil then
    inviter = sanitize_directory_text(inviter, 128)
    if not config_valid_mxid(inviter) then return nil, "invalid Matrix inviter ID" end
  end
  local conf, err = read_config(path)
  if not conf then return nil, err end
  if room == conf.home_room or room == conf.all_room then
    return nil, "HOME and ALL rooms can't be added"
  end
  if how ~= "owner-invite" and how ~= "operator" and how ~= "invite" and how ~= "approved" then how = nil end
  local new_how = how or "operator"
  if conf.rooms[room] ~= nil then
    if conf.rooms[room] == "joined" and ((alias and conf.room_aliases[room] ~= alias)
      or (inviter and conf.room_inviters[room] ~= inviter)) then
      local contents
      contents, err = read_file(path, "config")
      if not contents then return nil, err end
      local kept = {}
      each_raw_line(contents, function(raw, line, ending)
        if room_line_id(line) == room then
          local current_how = line:match("%s+how=(%S+)") or conf.room_how[room] or "operator"
          local current_alias = alias or conf.room_aliases[room]
          local current_inviter = inviter or conf.room_inviters[room]
          local label = current_alias and (" alias=" .. current_alias) or ""
          local inviter_field = current_inviter and (" inviter=" .. current_inviter) or ""
          kept[#kept + 1] = "room=" .. room .. " how=" .. current_how .. label .. inviter_field .. ending
        else
          kept[#kept + 1] = raw .. ending
        end
      end)
      local wrote, write_error = write_config_text(path, table.concat(kept))
      if not wrote then return nil, write_error end
    end
    return true, false
  end
  local contents
  contents, err = read_file(path, "config")
  if not contents then return nil, err end
  local suffix = (#contents > 0 and contents:sub(-1) ~= "\n") and "\n" or ""
  local padded = contents .. suffix
  local line_count = 0
  for _ in contents:gmatch("\n") do line_count = line_count + 1 end
  if #contents > 0 and contents:sub(-1) ~= "\n" then line_count = line_count + 1 end
  while line_count < 6 do
    padded = padded .. "\n"
    line_count = line_count + 1
  end
  local label = alias and (" alias=" .. alias) or ""
  local inviter_field = inviter and (" inviter=" .. inviter) or ""
  local wrote, write_error = write_config_text(path,
    padded .. "room=" .. room .. " how=" .. new_how .. label .. inviter_field .. "\n")
  if not wrote then return nil, write_error end
  return true, true
end

function matrix.config_remove_room(path, room)
  local conf, err = read_config(path)
  if not conf then return nil, err end
  if room == conf.home_room or room == conf.all_room then
    return nil, "HOME and ALL rooms can't be removed"
  end
  local contents
  contents, err = read_file(path, "config")
  if not contents then return nil, err end
  local kept, removed = {}, false
  each_raw_line(contents, function(raw, line, ending)
    if room_line_id(line) == room then
      removed = true
    else
      kept[#kept + 1] = raw .. ending
    end
  end)
  if not removed then return true end
  return write_config_text(path, table.concat(kept))
end

-- Core's stable TLS reason for a wrong pin (remuda net/http_client.rs tls_failure_reason).
matrix.PIN_MISMATCH = "SPKI pin mismatch"

local function config()
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths
  local guidance = matrix.configuration_guidance()
  if guidance then return nil, guidance end
  if not paths or not paths.token_path or not paths.config_path then return nil, "Matrix is not configured" end
  local token, token_error = read_file(paths.token_path, "token")
  if not token then return nil, token_error end
  token = trim(token)
  if token == "" then return nil, "Matrix token is empty" end
  local parsed, config_error = read_config(paths.config_path)
  if not parsed then return nil, config_error end
  if parsed.base:match("^http://") and (parsed.ca_file or parsed.pin) then
    return nil, "Matrix pin_sha256 and ca_file are only valid with an https:// homeserver.\n"
      .. "Next: remove pin_sha256/ca_file from " .. paths.config_path .. " or switch its homeserver to https://"
  end
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
  return conf.rooms[room] ~= nil
end

function matrix.room_kind(room)
  local conf, err = config()
  if not conf then return nil, err end
  return conf.rooms[room]
end

local function is_agent_mxid(mxid)
  local localpart = type(mxid) == "string" and mxid:match("^@([^:]+):")
  if localpart and (localpart:sub(1, 6):lower() == "agent-"
    or localpart:sub(1, 7):lower() == "butler-") then return true end
  local conf = config()
  if not conf then return nil end
  return type(mxid) == "string" and (mxid == conf.self_mxid or conf.butler_senders[mxid] == true)
end
matrix.is_agent_mxid = is_agent_mxid

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

local ERR_HINTS = {
  M_FORBIDDEN = "check --password-file",
  M_LIMIT_EXCEEDED = "wait before retrying",
  M_USER_IN_USE = "choose a different --bot MXID",
  M_UNKNOWN_TOKEN = "rerun setup with a valid --password-file",
  M_MISSING_TOKEN = "rerun setup with a valid --password-file",
  M_NOT_FOUND = "check the room or event ID",
  M_INVALID_PARAM = "check the command arguments",
  M_UNRECOGNIZED = "check that the homeserver supports this Matrix API",
}

local function matrix_http_error(status, body)
  local errcode
  if type(body) == "string" and body ~= "" then
    local ok, response = pcall(json.decode, body)
    if ok and type(response) == "table" and type(response.errcode) == "string"
      and response.errcode:match("^M_[A-Z0-9_]+$") then
      errcode = response.errcode
    end
  end
  local message = "Matrix HTTP " .. tostring(status)
  if errcode then message = message .. " (" .. errcode .. ")" end
  local hint = errcode and ERR_HINTS[errcode] or "check the homeserver settings and retry"
  return message .. "\nNext: " .. hint
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
    if not path_room or conf.rooms[path_room] == nil then
      report_error(done, "room is outside the configured Matrix allowlist.\n"
        .. "Next: remuda butler matrix rooms lists allowed rooms; the owner adds one with remuda butler matrix join ROOM")
      return { cancel = function() end }
    end
  end
  if args.room ~= nil and conf.rooms[args.room] == nil then
    report_error(done, "room is outside the configured Matrix allowlist.\n"
      .. "Next: remuda butler matrix rooms lists allowed rooms; the owner adds one with remuda butler matrix join ROOM")
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
    max_bytes = max_bytes, ca_file = conf.ca_file, pin = conf.pin, pin_only = conf.pin ~= nil,
    callback = function(result)
      if result.error and conf.pin and result.error:find(matrix.PIN_MISMATCH, 1, true) then
        return done({ error = result.error .. "\nNext: recompute pin_sha256 as the server key's SPKI SHA-256"
          .. " (see docs/butler.md) or use ca_file=PATH" })
      end
      if result.error then return done({ error = result.error }) end
      result.headers = json.object(type(result.headers) == "table" and result.headers or {})
      if result.status and (result.status < 200 or result.status >= 300) then
        return done({ error = matrix_http_error(result.status, result.body), status = result.status,
          headers = result.headers })
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
  if conf.rooms[room] == nil then
    report_error(done, "room is outside the configured Matrix allowlist.\n"
      .. "Next: remuda butler matrix rooms lists allowed rooms; the owner adds one with remuda butler matrix join ROOM")
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
