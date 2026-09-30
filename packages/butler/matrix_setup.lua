-- Matrix setup argument parsing and staged setup actions.
local matrix = assert(remuda.butler and remuda.butler.matrix, "Matrix request word is unavailable")

local USAGE = [[Usage: remuda butler matrix setup [OPTIONS]
  --homeserver URL       Your Matrix server address, like https://matrix.example.org.
  --owner ID             Your Matrix user ID, like @alice:example.org (in Element: click your avatar, top left).
  --password-file PATH   Read the bot account password from this file.
  --bot ID               The bot's Matrix user ID, like @butler-home:example.org (the account setup logs in as).
  --token-file PATH      Use an existing access token from this file instead of a password.
  --dir PATH             Save the private token and config files in this directory.
  --default              Save to the default live Butler config directory.
  --force                Replace existing token or config files.
  --all                  Also create the optional ALL-BUTLERS room.
  --pin SHA256HEX         Trust this HTTPS certificate fingerprint.
  --ca-file PATH         Trust the HTTPS certificate authority in this file.

Example: remuda butler matrix setup --homeserver https://matrix.example.org --owner @alice:example.org --bot @butler-home:example.org --password-file /path/to/password --dir /path/to/private/butler --pin <64-hex-sha256>]]

local function absolute(path)
  return type(path) == "string" and (path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil)
end

local function no_dot_segments(path)
  for segment in path:gmatch("[^/\\]+") do
    if segment == "." or segment == ".." then return false end
  end
  return true
end

local function default_paths()
  local home = os.getenv("XDG_CONFIG_HOME")
  if not home or home == "" then
    local user_home = os.getenv("HOME")
    if not user_home or user_home == "" then return nil end
    home = user_home .. "/.config"
  end
  local dir = home .. "/remuda/butler"
  return { token_path = dir .. "/token", config_path = dir .. "/config" }, dir
end

local function valid_url(value)
  if type(value) ~= "string" or value == "" or value:find("[%s%c]") then
    return nil, "--homeserver must be an http:// or https:// URL"
  end
  local scheme, authority, suffix = value:match("^(https?)://([^/%?#]+)(.*)$")
  if not scheme or not authority or authority == "" or authority:find("@", 1, true)
    or authority:find("[^%w%.%-%[%]:]") then
    return nil, "--homeserver must be an absolute http:// or https:// URL without credentials"
  end
  if authority:sub(1, 1) == "[" then
    if not authority:match("^%[[%x:]+%](:%d+)?$") then
      return nil, "--homeserver has an invalid host or port"
    end
  else
    local host, port = authority:match("^([^:]+):(%d+)$")
    if not host then host = authority end
    if host == "" or (authority:find(":", 1, true) and not port)
      or host:find("[^%w%.%-]") then
      return nil, "--homeserver has an invalid host or port"
    end
  end
  if suffix:find("[?#]") or suffix:find("\\", 1, true) then
    return nil, "--homeserver must not include a query, fragment, or backslash"
  end
  return value:gsub("/+$", ""), scheme
end

local function safe_user_id_echo(value)
  return (value:gsub("[%c]", "?"):sub(1, 64))
end

local function invalid_user_id(value, option)
  local echo = safe_user_id_echo(value)
  if echo:find("%s") then
    return option .. " '" .. echo .. "' contains spaces. It should look like @alice:example.org: an @, your name, a colon, your server."
  end
  if echo:sub(1, 1) ~= "@" then
    local corrected = "@" .. echo
    if not corrected:find(":", 2, true) then corrected = corrected .. ":example.org" end
    return option .. " '" .. echo .. "' is not a Matrix user ID. It looks like " .. corrected
      .. ": an @, your name, a colon, your server."
  end
  local localpart, server = echo:match("^@([^:]+):(.+)$")
  if not localpart or server == "" then
    local localpart_hint = echo:match("^@([^:]+)") or "alice"
    return option .. " '" .. echo .. "' is missing :server. It should look like @"
      .. localpart_hint .. ":example.org."
  end
  return option .. " '" .. echo .. "' is not a Matrix user ID. It should look like @alice:example.org: an @, your name, a colon, your server."
end

local function valid_mxid(value, option)
  if type(value) ~= "string" or value == "" then
    return nil, option .. " is required. Enter a Matrix user ID, like @alice:example.org."
  end
  local localpart, server = value:match("^@([^:]+):(.+)$")
  if not localpart or localpart:find("[%s%c/@]") or server == ""
    or server:find("[%s%c/#?]") then
    return nil, invalid_user_id(value, option)
  end
  return value
end

local function readable_file(path)
  if not absolute(path) then return false end
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function setup_command(options, destination)
  local parts = { "remuda butler matrix setup" }
  local function add(flag, value)
    parts[#parts + 1] = flag .. " " .. shell_quote(value)
  end
  add("--homeserver", options.homeserver)
  add("--owner", options.owner_mxid)
  if options.secret_kind == "registration" then
    parts[#parts + 1] = "--register"
    add("--registration-token-file", options.secret_path)
    add("--bot", options.bot_mxid)
  elseif options.secret_kind == "password" then
    add("--password-file", options.secret_path)
    add("--bot", options.bot_mxid)
  else
    add("--token-file", options.secret_path)
    if options.bot_mxid then add("--bot", options.bot_mxid) end
  end
  if options.force then parts[#parts + 1] = "--force" end
  if options.create_all then parts[#parts + 1] = "--all" end
  if options.pin then add("--pin", options.pin) end
  if options.ca_file then add("--ca-file", options.ca_file) end
  if destination == "default" then
    parts[#parts + 1] = "--default"
  else
    parts[#parts + 1] = '--dir "$HOME/.config/remuda/matrix-test"'
  end
  return table.concat(parts, " ")
end

local function validate_secret(path, kind)
  local option = kind == "registration" and "--registration-token-file"
    or "--" .. kind .. "-file"
  if not absolute(path) then return nil, option .. " must be an absolute path" end
  if not readable_file(path) then
    return nil, "cannot read secret input file: " .. path
  end
  local file = io.open(path, "rb")
  if not file then return nil, "cannot read secret input file: " .. path end
  local contents = file:read(4097) or ""
  file:close()
  if #contents > 4096 then return nil, "secret input file exceeds 4 KiB: " .. path end
  local first_line = contents:match("^([^\r\n]*)") or ""
  first_line = first_line:gsub("^%s+", ""):gsub("%s+$", "")
  if first_line == "" then return nil, "secret input file is empty: " .. path end
  return first_line
end

local function transport_pin(hex)
  if type(hex) ~= "string" then return nil end
  local binary = hex:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local encoded = {}
  for index = 1, #binary, 3 do
    local a, b, c = binary:byte(index, index + 2)
    b, c = b or 0, c or 0
    local value = a * 65536 + b * 256 + c
    encoded[#encoded + 1] = alphabet:sub(math.floor(value / 262144) % 64 + 1, math.floor(value / 262144) % 64 + 1)
      .. alphabet:sub(math.floor(value / 4096) % 64 + 1, math.floor(value / 4096) % 64 + 1)
      .. (index + 1 <= #binary and alphabet:sub(math.floor(value / 64) % 64 + 1, math.floor(value / 64) % 64 + 1) or "=")
      .. (index + 2 <= #binary and alphabet:sub(value % 64 + 1, value % 64 + 1) or "=")
  end
  return "sha256/" .. table.concat(encoded)
end

local function base64url(bytes)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local encoded = {}
  for index = 1, #bytes, 3 do
    local a, b, c = bytes:byte(index, index + 2)
    b, c = b or 0, c or 0
    local value = a * 65536 + b * 256 + c
    encoded[#encoded + 1] = alphabet:sub(math.floor(value / 262144) % 64 + 1,
      math.floor(value / 262144) % 64 + 1)
      .. alphabet:sub(math.floor(value / 4096) % 64 + 1,
        math.floor(value / 4096) % 64 + 1)
    if index + 1 <= #bytes then
      encoded[#encoded + 1] = alphabet:sub(math.floor(value / 64) % 64 + 1,
        math.floor(value / 64) % 64 + 1)
    end
    if index + 2 <= #bytes then
      encoded[#encoded + 1] = alphabet:sub(value % 64 + 1, value % 64 + 1)
    end
  end
  return table.concat(encoded)
end

local function new_password()
  local ok, file = pcall(io.open, "/dev/urandom", "rb")
  if not ok or not file then return nil end
  local read_ok, bytes = pcall(file.read, file, 32)
  pcall(file.close, file)
  if not read_ok or type(bytes) ~= "string" or #bytes ~= 32 then return nil end
  return base64url(bytes)
end

local function resolve_outputs(options)
  local resolved = default_paths()
  local current = remuda._butler_matrix_paths or resolved or {}
  local token_path, config_path, dir
  if options.dir then
    dir = options.dir:gsub("/+$", "")
    if dir == "" or not absolute(dir) then return nil, "--dir must be an absolute path" end
    if not no_dot_segments(dir) then return nil, "--dir must not contain . or .. path segments" end
    token_path, config_path = dir .. "/token", dir .. "/config"
  else
    token_path, config_path = current.token_path, current.config_path
  end
  if not absolute(token_path) or not absolute(config_path) then
    return nil, "cannot resolve Matrix output paths; set HOME/XDG_CONFIG_HOME or pass --dir"
  end
  if token_path == config_path then return nil, "Matrix token and config output paths must be different" end
  if not no_dot_segments(token_path) or not no_dot_segments(config_path) then
    return nil, "Matrix output paths must not contain . or .. path segments"
  end

  local touches_default = resolved and (token_path == resolved.token_path or config_path == resolved.config_path)
  if touches_default and not options.default then
    local test_dir = "$HOME/.config/remuda/matrix-test"
    local lines = {
      "Nothing was written.",
      "To enable Matrix for this Butler (the running remuda), rerun:",
      "  " .. setup_command(options, "default"),
      "To set up a separate test Butler, rerun:",
      "  " .. setup_command(options, "test"),
      "Start its own daemon with the setup files:",
      "  REMUDA_BUTLER_TOKEN=\"" .. test_dir .. "/token\" REMUDA_BUTLER_CONFIG=\""
        .. test_dir .. "/config\" remuda -s matrix-test daemon",
      "The relay starts when the Butler module starts or reloads (packages/butler/init.lua:16-30, 88-91).",
      "Trigger it now with: remuda -e \"remuda.reload('butler')\"",
      "For the test Butler, run: remuda -s matrix-test -e \"remuda.reload('butler')\"",
    }
    return nil, table.concat(lines, "\n")
  end
  if options.default and options.dir then return nil, "--default and --dir cannot be combined" end

  local password_path = token_path:match("^(.*)/[^/]+$") .. "/password"
  if options.register and (password_path == token_path or password_path == config_path) then
    return nil, "Matrix password, token, and config output paths must be different"
  end
  if not options.force then
    local paths = { token_path, config_path }
    if options.register then paths[#paths + 1] = password_path end
    for _, path in ipairs(paths) do
      if file_exists(path) then return nil, "output file already exists; pass --force: " .. path end
    end
  end
  -- Validation must not touch output paths; S4 creates the directory at write time.
  return { token_path = token_path, config_path = config_path, dir = dir }
end

local VALUE_OPTIONS = {
  ["--homeserver"] = "homeserver", ["--bot"] = "bot_mxid", ["--owner"] = "owner_mxid",
  ["--password-file"] = "password_file", ["--token-file"] = "token_file",
  ["--registration-token-file"] = "registration_token_file",
  ["--dir"] = "dir", ["--pin"] = "pin", ["--ca-file"] = "ca_file",
}

function matrix.setup_usage()
  return USAGE
end

function matrix.setup_prepare(args)
  if type(args) ~= "table" then return nil, "Matrix setup arguments must be a list" end
  if #args == 0 or (#args == 1 and (args[1] == "--help" or args[1] == "-h")) then
    return { help = true, usage = USAGE }
  end
  local options, seen = {}, {}
  local flags = { ["--default"] = "default", ["--force"] = "force", ["--all"] = "create_all",
    ["--register"] = "register" }
  local at = 1
  while at <= #args do
    local name, value = args[at], args[at + 1]
    if flags[name] then
      if seen[name] then return nil, "duplicate option " .. name end
      options[flags[name]], seen[name] = true, true
      at = at + 1
    elseif VALUE_OPTIONS[name] then
      if seen[name] then return nil, "duplicate option " .. name end
      if not value or value == "" or value:sub(1, 2) == "--" then
        return nil, name .. " requires a value"
      end
      options[VALUE_OPTIONS[name]], seen[name] = value, true
      at = at + 2
    elseif name:sub(1, 2) == "--" then
      return nil, "unknown option " .. name
    else
      return nil, "unexpected setup argument " .. name
    end
  end

  local homeserver, scheme_or_error = valid_url(options.homeserver)
  if not homeserver then return nil, scheme_or_error end
  options.homeserver = homeserver
  local owner, owner_error = valid_mxid(options.owner_mxid, "--owner")
  if not owner then return nil, owner_error end
  options.owner_mxid = owner

  local has_password, has_token, has_registration = options.password_file ~= nil,
    options.token_file ~= nil, options.registration_token_file ~= nil
  if options.register then
    if has_password or has_token then
      return nil, "--register uses --registration-token-file; choose one setup method"
    end
    if not has_registration then return nil, "--register requires --registration-token-file" end
  elseif has_registration then
    return nil, "--registration-token-file requires --register"
  elseif has_password and has_token then
    return nil, "choose one of --password-file or --token-file"
  elseif not has_password and not has_token then
    return nil, "provide --password-file, --token-file, or --register --registration-token-file"
  end
  options.secret_kind = options.register and "registration"
    or (options.password_file and "password" or "token")
  options.secret_path = options.password_file or options.token_file or options.registration_token_file
  local secret_ok, secret_error = validate_secret(options.secret_path, options.secret_kind)
  if not secret_ok then return nil, secret_error end
  options.secret = secret_ok

  if options.register and not options.bot_mxid then
    local hostname = os.getenv("HOSTNAME") or os.getenv("COMPUTERNAME") or ""
    if hostname == "" then
      for _, path in ipairs({ "/etc/hostname", "/var/run/hostname" }) do
        local file = io.open(path, "rb")
        if file then
          hostname = file:read("*l") or ""
          file:close()
          if hostname ~= "" then break end
        end
      end
    end
    local slug = hostname:lower():gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
    slug = slug:sub(1, 48):gsub("-+$", "")
    local server = options.owner_mxid:match("^@[^:]+:(.+)$")
    if slug == "" or not server or server == "" then
      return nil, "cannot derive a bot account name from this computer; pass --bot"
    end
    options.bot_mxid = "@butler-" .. slug .. ":" .. server
  elseif options.bot_mxid then
    local bot, bot_error = valid_mxid(options.bot_mxid, "--bot")
    if not bot then return nil, bot_error end
    options.bot_mxid = bot
  elseif options.password_file then
    return nil, "--bot is required when using --password-file"
  end
  if options.register or options.password_file then
    local bot, bot_error = valid_mxid(options.bot_mxid, "--bot")
    if not bot then return nil, bot_error end
    options.bot_mxid = bot
  end
  if options.bot_mxid and options.bot_mxid == options.owner_mxid then
    return nil, "the bot and your Matrix user ID must be different"
  end

  if options.pin and options.ca_file then return nil, "choose one of --pin or --ca-file" end
  if options.pin then
    if #options.pin ~= 64 or not options.pin:match("^%x+$") then
      return nil, "--pin must be 64 hexadecimal SHA-256 characters"
    end
    options.pin = options.pin:lower()
  end
  if options.ca_file then
    if not absolute(options.ca_file) or not readable_file(options.ca_file) then
      return nil, "cannot read --ca-file: " .. options.ca_file
    end
  end
  if homeserver:match("^https://") and not options.pin and not options.ca_file then
    return nil, "HTTPS setup requires --pin SHA256HEX or --ca-file PATH.\n"
      .. "Next: rerun with --pin SHA256HEX or --ca-file PATH"
  end
  if homeserver:match("^http://") and (options.pin or options.ca_file) then
    return nil, "--pin and --ca-file are only valid with an https:// homeserver"
  end

  local outputs, output_error = resolve_outputs(options)
  if not outputs then return nil, output_error end
  options.token_path, options.config_path, options.output_dir = outputs.token_path,
    outputs.config_path, outputs.dir
  options.password_path = outputs.dir and (outputs.dir .. "/password")
    or outputs.token_path:match("^(.*)/[^/]+$") .. "/password"
  if options.register and options.password_path == options.token_path then
    return nil, "Matrix password and token output paths must be different"
  end
  options.password_file, options.token_file = nil, nil
  options.registration_token_file = nil
  return options
end

function matrix.setup_network(options, on_done)
  local done_called, cancelled, active, registration_password = false, false, nil, nil
  local registration_token_error = "This is not a valid access token for any account. If it is the server's registration token, use --register (creates the bot account). Nothing was written."
  local function done(result)
    if done_called or cancelled then return end
    done_called = true
    if on_done then on_done(result) end
  end
  local function fail(message)
    done({ error = message })
  end
  local base = options and options.homeserver
  if type(base) ~= "string" or type(options.secret) ~= "string" then
    fail("Matrix setup plan is incomplete")
    return { cancel = function() cancelled = true end }
  end

  local function send(stage, method, path, token, payload, callback)
    local body
    if payload then
      body = matrix.encode_json(payload)
      if not body then return fail("Matrix setup could not encode a request") end
    end
    local headers = { Accept = "application/json" }
    if body then headers["Content-Type"] = "application/json" end
    if token then headers.Authorization = "Bearer " .. token end
    local spec = {
      method = method, url = base .. path, headers = headers, body = body,
      timeout = 15, connect_timeout = 10, max_bytes = 1024 * 1024,
      ca_file = options.ca_file, pin = transport_pin(options.pin),
      callback = function(response)
        if done_called or cancelled then return end
        if type(response) ~= "table" then
          return fail("Matrix setup " .. stage .. " request failed")
        end
        local status = tonumber(response.status)
        local decoded, decode_error
        if type(response.body) == "string" and response.body ~= "" then
          local ok
          ok, decoded, decode_error = pcall(matrix.decode_json, response.body)
          if not ok then decoded, decode_error = nil, "invalid JSON" end
        else
          decoded = {}
        end
        local errcode = type(decoded) == "table" and decoded.errcode or nil
        if (stage == "login" or stage == "whoami")
          and (status == 401 or errcode == "M_UNKNOWN_TOKEN") then
          return fail(registration_token_error)
        end
        if response.error then
          return fail("Matrix setup " .. stage .. " request failed")
        end
        if not status or status < 200 or status >= 300 then
          return fail("Matrix setup " .. stage .. " request failed"
            .. (status and (" (HTTP " .. tostring(status) .. ")") or ""))
        end
        if type(decoded) ~= "table" or decode_error then
          return fail("Matrix setup received an invalid " .. stage .. " response")
        end
        callback(decoded)
      end,
    }
    local ok, handle = pcall(remuda.http.request, spec)
    if not ok or not handle then return fail("Matrix setup " .. stage .. " request failed") end
    active = handle
  end

  local function create_rooms(token, user_id)
    local rooms = {}
    local room_specs = { { key = "home_room" } }
    if options.create_all then room_specs[#room_specs + 1] = { key = "all_room" } end
    local at = 1
    local function create_next()
      local room = room_specs[at]
      if not room then
        local result = { user_id = user_id, token = token,
          home_room = rooms.home_room, all_room = rooms.all_room }
        if registration_password then result.password = registration_password end
        return done(result)
      end
      local request_body = { preset = "private_chat", invite = { options.owner_mxid } }
      send("createRoom", "POST", "/_matrix/client/v3/createRoom", token, request_body,
        function(response)
          if type(response.room_id) ~= "string" or response.room_id == "" then
            return fail("Matrix setup createRoom response did not include a room ID")
          end
          rooms[room.key] = response.room_id
          at = at + 1
          create_next()
        end)
    end
    create_next()
  end

  local function whoami(token)
    send("whoami", "GET", "/_matrix/client/v3/account/whoami", token, nil, function(response)
      local user_id = response.user_id
      if not valid_mxid(user_id, "whoami user") then
        return fail("Matrix setup whoami response did not include a valid user ID")
      end
      if options.bot_mxid and options.bot_mxid ~= user_id then
        return fail("Matrix setup login user does not match --bot")
      end
      create_rooms(token, user_id)
    end)
  end

  if options.secret_kind == "password" then
    send("login", "POST", "/_matrix/client/v3/login", nil, {
      type = "m.login.password",
      identifier = { type = "m.id.user", user = options.bot_mxid },
      password = options.secret,
    }, function(response)
      if type(response.access_token) ~= "string" or response.access_token == "" then
        return fail("Matrix setup login response did not include an access token")
      end
      whoami(response.access_token)
    end)
  elseif options.secret_kind == "registration" then
    registration_password = new_password()
    if not registration_password then
      return fail("This system has no secure random source for a bot password. Next: rerun with --password-file PATH (a password you choose)")
    end
    local base_bot = options.bot_mxid
    local localpart, server = base_bot:match("^@([^:]+):(.+)$")
    local attempt = 1
    local function register_bot()
      local username = localpart .. (attempt == 1 and "" or ("-" .. tostring(attempt)))
      options.bot_mxid = "@" .. username .. ":" .. server
      active = matrix.setup_register({ homeserver = base, username = username,
        password = registration_password, registration_token = options.secret,
        ca_file = options.ca_file, pin = options.pin }, function(result)
        if type(result) == "table" and result.errcode == "M_USER_IN_USE" then
          if attempt < 5 then attempt = attempt + 1; return register_bot() end
          return fail("Bot account names ending in -2 through -5 are also in use. Pass --bot with another name. Nothing was created or written.")
        end
        if type(result) ~= "table" or result.error then
          return fail(type(result) == "table" and result.error
            or "Matrix account registration failed")
        end
        whoami(result.access_token)
      end)
    end
    register_bot()
  else
    whoami(options.secret)
  end

  return { cancel = function()
    if done_called or cancelled then return end
    cancelled = true
    if active and active.cancel then active:cancel() end
  end }
end

-- Create a Matrix account using interactive-authentication (UIA). Registration
-- is separate from setup_network so callers can choose this path explicitly.
function matrix.setup_register(options, on_done)
  local done_called, cancelled, active = false, false, nil
  local rejected_token = "The server rejected that registration token. Nothing was created or written."
  local missing_flow = "This server does not accept registration tokens. Next: this server needs an admin-created bot; run setup with --token-file PATH (the bot access token)."
  local function done(result)
    if done_called or cancelled then return end
    done_called = true
    if on_done then on_done(result) end
  end
  local function fail(message, errcode)
    local result = { error = message }
    if type(errcode) == "string" and errcode:match("^M_[A-Z0-9_]+$") then
      result.errcode = errcode
    end
    done(result)
  end
  if type(options) ~= "table" or type(options.homeserver) ~= "string"
    or type(options.username) ~= "string" or options.username == ""
    or type(options.password) ~= "string" or options.password == ""
    or type(options.registration_token) ~= "string" or options.registration_token == "" then
    fail("Matrix registration plan is incomplete")
    return { cancel = function() cancelled = true end }
  end

  local base = options.homeserver:gsub("/+$", "")
  local function decode(response)
    if type(response) ~= "table" or type(response.body) ~= "string" then return nil end
    local ok, value = pcall(matrix.decode_json, response.body)
    if not ok or type(value) ~= "table" then return nil end
    return value
  end
  local function send(payload, callback)
    local body = matrix.encode_json(payload)
    if not body then return fail("Matrix registration could not encode a request") end
    local spec = {
      method = "POST", url = base .. "/_matrix/client/v3/register",
      headers = { Accept = "application/json", ["Content-Type"] = "application/json" },
      body = body, timeout = 15, connect_timeout = 10, max_bytes = 1024 * 1024,
      ca_file = options.ca_file, pin = transport_pin(options.pin),
      callback = function(response)
        if done_called or cancelled then return end
        callback(response, decode(response))
      end,
    }
    local ok, handle = pcall(remuda.http.request, spec)
    if not ok or not handle then return fail("Matrix account registration request failed") end
    active = handle
  end
  local function initial_payload(auth)
    local payload = { username = options.username, password = options.password,
      inhibit_login = false }
    if auth then payload.auth = auth end
    return payload
  end
  local function finish(response, decoded)
    local access_token = type(decoded) == "table" and decoded.access_token
    local user_id = type(decoded) == "table" and decoded.user_id
    if type(access_token) ~= "string" or access_token == ""
      or type(user_id) ~= "string" or not valid_mxid(user_id, "registration user") then
      return fail("Matrix account registration response was incomplete")
    end
    done({ access_token = access_token, user_id = user_id })
  end
  local function register_stage(stage, session, callback)
    local auth = { type = stage, session = session }
    if stage == "m.login.registration_token" then auth.token = options.registration_token end
    send(initial_payload(auth), callback)
  end

  send(initial_payload(), function(response, challenge)
    if type(response) ~= "table" then return fail("Matrix account registration request failed") end
    local status = tonumber(response.status)
    if status ~= 401 or type(challenge) ~= "table"
      or type(challenge.session) ~= "string" or challenge.session == ""
      or type(challenge.flows) ~= "table" then
      if status == 403 or (challenge and challenge.errcode == "M_FORBIDDEN") then
        return fail(rejected_token)
      end
      return fail("Matrix account registration request failed"
        .. (status and (" (HTTP " .. tostring(status) .. ")") or ""),
        challenge and challenge.errcode)
    end
    local selected
    for _, flow in ipairs(challenge.flows) do
      if type(flow) == "table" and type(flow.stages) == "table" then
        local has_token = false
        for _, stage in ipairs(flow.stages) do
          if stage == "m.login.registration_token" then has_token = true; break end
        end
        if has_token then selected = flow.stages; break end
      end
    end
    if not selected then return fail(missing_flow) end

    for _, stage in ipairs(selected) do
      if stage ~= "m.login.dummy" and stage ~= "m.login.registration_token" then
        local safe_stage = type(stage) == "string" and stage:match("^[%w%._%-]+$")
          and stage or "an unknown UIA stage"
        return fail("This server requires an unsupported registration step: "
          .. safe_stage .. ". Nothing was created or written.")
      end
    end

    local stages = {}
    for _, stage in ipairs(selected) do
      if stage == "m.login.dummy" then stages[#stages + 1] = stage end
    end
    stages[#stages + 1] = "m.login.registration_token"
    local at = 1
    local function advance()
      local stage = stages[at]
      if not stage then return fail("Matrix account registration could not complete its authentication flow") end
      register_stage(stage, challenge.session, function(stage_response, stage_body)
        if type(stage_response) ~= "table" then
          return fail("Matrix account registration request failed")
        end
        local stage_status = tonumber(stage_response.status)
        if stage_status and stage_status >= 200 and stage_status < 300 then
          return finish(stage_response, stage_body)
        end
        if stage == "m.login.registration_token" and (stage_status == 401
          or stage_status == 403
          or (stage_body and (stage_body.errcode == "M_FORBIDDEN"
            or stage_body.errcode == "M_INVALID_PARAM"))) then
          return fail(rejected_token)
        end
        if at < #stages and stage_status == 401 and stage_body
          and (not stage_body.session or stage_body.session == challenge.session) then
          at = at + 1
          return advance()
        end
        return fail("Matrix account registration request failed"
          .. (stage_status and (" (HTTP " .. tostring(stage_status) .. ")") or ""),
          stage_body and stage_body.errcode)
      end)
    end
    advance()
  end)

  return { cancel = function()
    if done_called or cancelled then return end
    cancelled = true
    if active and active.cancel then active:cancel() end
  end }
end

function matrix.setup_write(options, result)
  local orphan_ids = {}
  if type(result) == "table" then
    if type(result.home_room) == "string" then orphan_ids[#orphan_ids + 1] = result.home_room end
    if type(result.all_room) == "string" then orphan_ids[#orphan_ids + 1] = result.all_room end
  end
  local function failure(message)
    if #orphan_ids > 0 then
      message = message .. "; orphan room ID" .. (#orphan_ids > 1 and "s" or "")
        .. ": " .. table.concat(orphan_ids, ", ")
    end
    return nil, message
  end
  if type(options) ~= "table" or type(result) ~= "table"
    or type(result.token) ~= "string" or result.token == ""
    or type(result.user_id) ~= "string" or type(result.home_room) ~= "string"
    or (options.secret_kind == "registration"
      and (type(result.password) ~= "string" or result.password == ""
        or type(options.password_path) ~= "string"))
    or (options.create_all and type(result.all_room) ~= "string")
    or type(options.token_path) ~= "string" or type(options.config_path) ~= "string" then
    return failure("Matrix setup cannot write incomplete results")
  end
  if type(remuda.fs) ~= "table" or type(remuda.fs.mkdir_new) ~= "function"
    or type(remuda.fs.write_atomic) ~= "function" then
    return failure("Matrix setup requires the Remuda private filesystem helpers")
  end

  local paths = { options.token_path }
  if options.secret_kind == "registration" then paths[#paths + 1] = options.password_path end
  paths[#paths + 1] = options.config_path
  local path_labels = { [options.token_path] = "token", [options.config_path] = "config" }
  local contents = { [options.token_path] = result.token .. "\n" }
  if options.secret_kind == "registration" then
    path_labels[options.password_path] = "password"
    contents[options.password_path] = result.password .. "\n"
  end
  local config_lines = {
    options.homeserver, result.home_room, result.user_id, options.owner_mxid, "", "30000",
  }
  if result.all_room then config_lines[#config_lines + 1] = "all_room=" .. result.all_room end
  if options.pin then config_lines[#config_lines + 1] = "pin_sha256=" .. options.pin end
  if options.ca_file then config_lines[#config_lines + 1] = "ca_file=" .. options.ca_file end
  contents[options.config_path] = table.concat(config_lines, "\n") .. "\n"
  if not options.force then
    for _, path in ipairs(paths) do
      if file_exists(path) then return failure("Matrix output file already exists; pass --force") end
    end
  end

  local created_dirs, created_set, backups = {}, {}, {}
  local function rollback_dirs()
    for index = #created_dirs, 1, -1 do pcall(os.remove, created_dirs[index]) end
  end
  local function rollback_files(written)
    local clean = true
    for index = #written, 1, -1 do
      local path = written[index]
      if backups[path] == nil then
        local ok, removed = pcall(os.remove, path)
        if not ok or removed == nil then clean = false end
      else
        local ok, restored = pcall(remuda.fs.write_atomic, path, backups[path], { private = true })
        if not ok or not restored then clean = false end
      end
    end
    return clean
  end
  local function ensure_directory(path)
    if not path or path == "" or path == "/" or created_set[path] then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path then
      local ok, parent_error = ensure_directory(parent)
      if not ok then return nil, parent_error end
    end
    local ok, made, reason = pcall(remuda.fs.mkdir_new, path)
    if not ok then return nil, "cannot create private output directory" end
    if made == true then
      created_dirs[#created_dirs + 1], created_set[path] = path, true
      return true
    end
    if reason == "exists" then return true end
    return nil, "cannot create private output directory"
  end
  local directories, directory_seen = {}, {}
  for _, path in ipairs(paths) do
    local parent = path:match("^(.*)/[^/]+$")
    if parent and not directory_seen[parent] then
      directories[#directories + 1], directory_seen[parent] = parent, true
    end
  end
  for _, path in ipairs(directories) do
    local made, make_error = ensure_directory(path)
    if not made then rollback_dirs(); return failure(make_error) end
  end

  for _, path in ipairs(paths) do
    local file = io.open(path, "rb")
    if file then
      if not options.force then
        file:close(); rollback_dirs()
        return failure("Matrix output file already exists; pass --force")
      end
      local old, read_error = file:read("*a")
      file:close()
      if old == nil then
        rollback_dirs()
        return failure("Matrix setup cannot preserve an existing output file")
      end
      backups[path] = old
    end
  end

  local written = {}
  for _, path in ipairs(paths) do
    local ok, wrote = pcall(remuda.fs.write_atomic, path, contents[path], { private = true })
    if not ok or not wrote then
      local files_clean = rollback_files(written)
      rollback_dirs()
      return failure("Matrix setup could not write its " .. path_labels[path]
        .. " file" .. (files_clean and "" or "; rollback was incomplete"))
    end
    written[#written + 1] = path
  end
  return { token_path = options.token_path, config_path = options.config_path,
    password_path = options.secret_kind == "registration" and options.password_path or nil }
end

return matrix
