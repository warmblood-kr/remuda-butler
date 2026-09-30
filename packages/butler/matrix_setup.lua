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

local function validate_secret(path, kind)
  if not absolute(path) then return nil, "--" .. kind .. "-file must be an absolute path" end
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
    return nil, "writing the default Matrix files enables the live daemon; pass --default"
  end
  if options.default and options.dir then return nil, "--default and --dir cannot be combined" end

  if not options.force then
    for _, path in ipairs({ token_path, config_path }) do
      if file_exists(path) then return nil, "output file already exists; pass --force: " .. path end
    end
  end
  -- Validation must not touch output paths; S4 creates the directory at write time.
  return { token_path = token_path, config_path = config_path, dir = dir }
end

local VALUE_OPTIONS = {
  ["--homeserver"] = "homeserver", ["--bot"] = "bot_mxid", ["--owner"] = "owner_mxid",
  ["--password-file"] = "password_file", ["--token-file"] = "token_file",
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
  local flags = { ["--default"] = "default", ["--force"] = "force", ["--all"] = "create_all" }
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

  if options.password_file and options.token_file then return nil, "choose one of --password-file or --token-file" end
  if not options.password_file and not options.token_file then
    return nil, "provide --password-file or --token-file"
  end
  options.secret_kind = options.password_file and "password" or "token"
  options.secret_path = options.password_file or options.token_file
  local secret_ok, secret_error = validate_secret(options.secret_path, options.secret_kind)
  if not secret_ok then return nil, secret_error end
  options.secret = secret_ok

  if options.password_file then
    local bot, bot_error = valid_mxid(options.bot_mxid, "--bot")
    if not bot then return nil, bot_error end
    options.bot_mxid = bot
  elseif options.bot_mxid then
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
  options.password_file, options.token_file = nil, nil
  return options
end

function matrix.setup_network(options, on_done)
  local done_called, cancelled, active = false, false, nil
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
        if type(response) ~= "table" or response.error then
          return fail("Matrix setup " .. stage .. " request failed")
        end
        local status = tonumber(response.status)
        if not status or status < 200 or status >= 300 then
          return fail("Matrix setup " .. stage .. " request failed"
            .. (status and (" (HTTP " .. tostring(status) .. ")") or ""))
        end
        local decoded, decode_error
        if type(response.body) == "string" and response.body ~= "" then
          decoded, decode_error = matrix.decode_json(response.body)
        else
          decoded = {}
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
        return done({ user_id = user_id, token = token,
          home_room = rooms.home_room, all_room = rooms.all_room })
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
  else
    whoami(options.secret)
  end

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
    or (options.create_all and type(result.all_room) ~= "string")
    or type(options.token_path) ~= "string" or type(options.config_path) ~= "string" then
    return failure("Matrix setup cannot write incomplete results")
  end
  if type(remuda.fs) ~= "table" or type(remuda.fs.mkdir_new) ~= "function"
    or type(remuda.fs.write_atomic) ~= "function" then
    return failure("Matrix setup requires the Remuda private filesystem helpers")
  end

  local paths = { options.token_path, options.config_path }
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

  local config_lines = {
    options.homeserver, result.home_room, result.user_id, options.owner_mxid, "", "30000",
  }
  if result.all_room then config_lines[#config_lines + 1] = "all_room=" .. result.all_room end
  if options.pin then config_lines[#config_lines + 1] = "pin_sha256=" .. options.pin end
  if options.ca_file then config_lines[#config_lines + 1] = "ca_file=" .. options.ca_file end
  local contents = { result.token .. "\n", table.concat(config_lines, "\n") .. "\n" }
  local written = {}
  for index, path in ipairs(paths) do
    local ok, wrote = pcall(remuda.fs.write_atomic, path, contents[index], { private = true })
    if not ok or not wrote then
      local files_clean = rollback_files(written)
      rollback_dirs()
      return failure("Matrix setup could not write its " .. (index == 1 and "token" or "config")
        .. " file" .. (files_clean and "" or "; rollback was incomplete"))
    end
    written[#written + 1] = path
  end
  return { token_path = options.token_path, config_path = options.config_path }
end

return matrix
