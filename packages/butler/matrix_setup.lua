-- Matrix setup argument parsing and staged setup actions.
local matrix = assert(remuda.butler and remuda.butler.matrix, "Matrix request word is unavailable")
local system = assert(remuda._butler_system)

local USAGE = [[Usage: remuda butler matrix setup [OPTIONS]
  --homeserver URL       Your Matrix server address, like https://matrix.example.org.
  --owner ID             Your Matrix user ID, like @alice:example.org (in Element: click your avatar, top left).
  --password-file PATH   Use this chosen bot password; setup saves no copy of it. If omitted with --register, one is generated and saved in the OS secure store, or in a private file when there is no store.
  --password-cmd PROG [ARG...]  Run this program and use the first line it prints as the bot password; no copy is saved. Must be the last option.
  --bot ID               The bot's Matrix user ID, like @butler-home:example.org (the account setup logs in as).
  --token-file PATH      Use an existing access token from this file instead of a password.
  --register             Create the bot account; prompt for its registration token if no file is given.
  --registration-token-file PATH  Optional file with the homeserver registration token (ask the server admin; this is not a bot access token).
  --dir PATH             Save the private token and config files in this directory; a generated password is saved there as a file too.
  --default              Save to the default live Butler config directory.
  --force                Replace existing token or config files.
  --all                  Also create the optional ALL-BUTLERS room.
  --rooms open|allowlist Room invites: open (anyone) or allowlist (default; allowlisted senders only).
  --pin SHA256HEX        Trust this HTTPS certificate SPKI SHA-256 (see docs/butler.md).
  --ca-file PATH         Trust the HTTPS certificate authority in this file.

Example: remuda butler matrix setup --homeserver https://matrix.example.org --owner @alice:example.org --register --dir /path/to/private/butler --pin <64-hex-sha256>

Password from a password manager: end the command with --password-cmd. Setup runs the program directly (no shell) and saves no copy of that password.
  1Password:  ... --password-cmd op read op://Vault/Item/password
  macOS:      ... --password-cmd security find-generic-password -s butler-bot -w
  PowerShell: ... --password-cmd powershell -NoProfile -Command "Get-Secret -Name butler-bot -AsPlainText"]]

matrix.REJECTED_REGISTRATION_TOKEN = "The server rejected that registration token. Nothing was created or written."

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
    local home_ok, user_home = pcall(system.home)
    if not home_ok then return nil end
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
  return matrix.utf8_prefix(value:gsub("[%c]", "?"), 64)
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

matrix.setup_validate_homeserver = valid_url
matrix.setup_validate_mxid = valid_mxid

-- This computer's name, or nil: the one seam for the name source. On a core
-- with remuda.hostname() that word is the only source (#207). The env and file
-- lookup below is for older cores only: its HOSTNAME is the daemon's, not the
-- caller's.
function matrix.setup_machine_name()
  if type(remuda.hostname) == "function" then
    local ok, name = pcall(remuda.hostname)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
  end
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
  if hostname ~= "" then return hostname end
end

-- "@butler-SLUG:SERVER" from this computer's name and the owner's server, or nil.
function matrix.setup_default_bot(owner_mxid)
  local slug = (matrix.setup_machine_name() or ""):lower():gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  slug = slug:sub(1, 48):gsub("-+$", "")
  local server = type(owner_mxid) == "string" and owner_mxid:match("^@[^:]+:(.+)$")
  if slug == "" or not server or server == "" then return nil end
  return "@butler-" .. slug .. ":" .. server
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
    if not options.prompt_registration_token then
      add("--registration-token-file", options.secret_path)
    end
    if options.password_input_path then add("--password-file", options.password_input_path) end
    add("--bot", options.bot_mxid)
  elseif options.secret_kind == "password" then
    if not options.password_cmd then add("--password-file", options.secret_path) end
    add("--bot", options.bot_mxid)
  else
    add("--token-file", options.secret_path)
    if options.bot_mxid then add("--bot", options.bot_mxid) end
  end
  if options.force then parts[#parts + 1] = "--force" end
  if options.create_all then parts[#parts + 1] = "--all" end
  if options.pin then add("--pin", options.pin) end
  if options.ca_file then add("--ca-file", options.ca_file) end
  if options.rooms_mode == "open" then add("--rooms", "open") end
  if destination == "default" then
    parts[#parts + 1] = "--default"
  else
    parts[#parts + 1] = '--dir "$HOME/.config/remuda/matrix-test"'
  end
  if options.password_cmd then
    -- Stays last: --password-cmd takes every remaining argument. The quoting is POSIX-style.
    parts[#parts + 1] = "--password-cmd"
    for _, word in ipairs(options.password_cmd) do parts[#parts + 1] = shell_quote(word) end
  end
  return table.concat(parts, " ")
end

local function normalize_secret(contents)
  if type(contents) ~= "string" then return nil, "invalid" end
  if #contents > 4096 then return nil, "too_long" end
  local first_line = contents:match("^([^\r\n]*)") or ""
  first_line = first_line:gsub("^%s+", ""):gsub("%s+$", "")
  if first_line == "" then return nil, "empty" end
  return first_line
end

matrix.normalize_secret = normalize_secret

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
  local secret, secret_error = normalize_secret(contents)
  if secret_error == "too_long" then return nil, "secret input file exceeds 4 KiB: " .. path end
  if secret_error == "empty" then return nil, "secret input file is empty: " .. path end
  if not secret then return nil, "secret input file is invalid: " .. path end
  return secret
end

-- The bot password is the first line a program prints; nothing it prints is ever echoed.
local function password_from_command(argv)
  local function failed(what)
    return nil, "--password-cmd: " .. safe_user_id_echo(argv[1]) .. " " .. what
      .. "\nNext: check the command runs by itself and prints only the password"
  end
  -- Resolve the program as doctor does, so a Windows .cmd shim starts by its bare name.
  local resolved = { system.find_command(argv[1]) or argv[1] }
  for index = 2, #argv do resolved[#resolved + 1] = argv[index] end
  local ok, result = pcall(remuda.process.run, { argv = resolved, timeout = 10 })
  if not ok or type(result) ~= "table" then return failed("could not be started") end
  if result.timed_out then return failed("timed out after 10 seconds") end
  if result.code ~= 0 then return failed("failed with exit status " .. tostring(result.code)) end
  local secret, secret_error = normalize_secret(result.stdout)
  if secret_error == "too_long" then return failed("printed more than 4 KiB") end
  if not secret then return failed("printed an empty password") end
  return secret
end

local PIN_MISMATCH = assert(matrix.PIN_MISMATCH, "load butler/matrix_request before butler/matrix_setup")
local CERT_UNTRUSTED = matrix.CERT_UNTRUSTED

-- A pin mismatch or an untrusted certificate gets one concrete next step.
local function tls_error(response)
  local message = type(response) == "table" and response.error
  if type(message) ~= "string" then return nil end
  if message:find(PIN_MISMATCH, 1, true) then
    return "The HTTPS server key does not match --pin.\n"
      .. "Next: recompute the SPKI SHA-256 of the server key (see docs/butler.md) or use --ca-file PATH"
  end
  if message:find(CERT_UNTRUSTED, 1, true) then
    return "The HTTPS server certificate is not trusted by this system.\n"
      .. matrix.UNTRUSTED_NEXT
  end
  return nil
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
  if type(remuda.random_bytes) == "function" then
    local ok, bytes = pcall(remuda.random_bytes, 32)
    if ok and type(bytes) == "string" and #bytes >= 32 then
      return base64url(bytes:sub(1, 32))
    end
  end
  local ok, file = pcall(io.open, "/dev/urandom", "rb")
  if not ok or not file then return nil end
  local read_ok, bytes = pcall(file.read, file, 32)
  pcall(file.close, file)
  if not read_ok or type(bytes) ~= "string" or #bytes ~= 32 then return nil end
  return base64url(bytes)
end

-- Whoever made the password keeps it: only one setup generated is saved, never a
-- --password-file or --password-cmd one.
local function saves_password(options)
  return options.secret_kind == "registration" and not options.password_cmd
    and not options.password_input_path
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
    return nil, "cannot resolve Matrix output paths. Next: set HOME or XDG_CONFIG_HOME, or pass --dir PATH"
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
    }
    return nil, table.concat(lines, "\n")
  end
  if options.default and options.dir then return nil, "--default and --dir cannot be combined" end

  local password_path = token_path:match("^(.*)/[^/]+$") .. "/password"
  local keeps_password = saves_password(options)
  if keeps_password and (password_path == token_path or password_path == config_path) then
    return nil, "Matrix password, token, and config output paths must be different"
  end
  if not options.force then
    local paths = { token_path, config_path }
    -- Only the file route can collide with an old password file: --dir always
    -- means the file, and so does a system with no OS secure store.
    if keeps_password and (dir or not system.credential_backend()) then
      paths[#paths + 1] = password_path
    end
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
  ["--rooms"] = "rooms_mode",
}

function matrix.setup_usage()
  return USAGE
end

function matrix.setup_prepare(args)
  if type(args) ~= "table" then return nil, "Matrix setup arguments must be a list" end
  if #args == 0 then return { wizard = true } end
  if #args == 1 and (args[1] == "--help" or args[1] == "-h") then
    return { help = true, usage = USAGE }
  end
  local options, seen = {}, {}
  local flags = { ["--default"] = "default", ["--force"] = "force", ["--all"] = "create_all",
    ["--register"] = "register" }
  local at = 1
  while at <= #args do
    local name, value = args[at], args[at + 1]
    if name == "--password-cmd" then
      -- Takes every remaining argument, so it must be the last option.
      if not value or value == "" then return nil, "--password-cmd requires a program to run" end
      options.password_cmd = {}
      for index = at + 1, #args do options.password_cmd[#options.password_cmd + 1] = args[index] end
      break
    elseif flags[name] then
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

  options.rooms_mode = options.rooms_mode or "allowlist"
  if options.rooms_mode ~= "open" and options.rooms_mode ~= "allowlist" then
    return nil, "rooms must be open or allowlist"
  end

  local homeserver, scheme_or_error = valid_url(options.homeserver)
  if not homeserver then return nil, scheme_or_error end
  options.homeserver = homeserver
  local owner, owner_error = valid_mxid(options.owner_mxid, "--owner")
  if not owner then return nil, owner_error end
  options.owner_mxid = owner

  if options.password_cmd and (options.password_file or options.token_file) then
    return nil, "choose one of --password-cmd, --password-file, or --token-file"
  end
  local has_password, has_token, has_registration = options.password_file ~= nil
    or options.password_cmd ~= nil, options.token_file ~= nil, options.registration_token_file ~= nil
  if options.register then
    if has_token then
      return nil, "--register creates a bot; use --registration-token-file instead of --token-file"
    end
    options.prompt_registration_token = not has_registration
  elseif has_registration then
    return nil, "--registration-token-file requires --register"
  elseif has_password and has_token then
    return nil, "choose one of --password-file or --token-file"
  elseif not has_password and not has_token then
    return nil, "provide --password-file, --password-cmd, --token-file, or --register"
  end
  options.secret_kind = options.register and "registration"
    or (has_password and "password" or "token")
  options.secret_path = options.register and options.registration_token_file
    or options.password_file or options.token_file
  if not options.prompt_registration_token and (options.register or not options.password_cmd) then
    local secret_ok, secret_error = validate_secret(options.secret_path, options.secret_kind)
    if not secret_ok then return nil, secret_error end
    options.secret = secret_ok
  end
  if options.register and options.password_file then
    if options.password_file == options.registration_token_file then
      return nil, "use separate files for the bot password and the homeserver registration token"
    end
    local chosen_password, password_error = validate_secret(options.password_file, "password")
    if not chosen_password then return nil, password_error end
    options.password_secret = chosen_password
    options.password_input_path = options.password_file
  end

  if options.register and not options.bot_mxid then
    options.bot_mxid = matrix.setup_default_bot(options.owner_mxid)
    if not options.bot_mxid then
      return nil, "cannot derive a bot account name from this computer\nNext: add --bot @butler-NAME:"
        .. (options.owner_mxid:match("^@[^:]+:(.+)$") or "SERVER")
    end
  elseif has_password and not options.bot_mxid then
    return nil, "--bot is required when using "
      .. (options.password_cmd and "--password-cmd" or "--password-file")
  end
  if options.register or has_password or options.bot_mxid then
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
  -- Run last, so a command that may prompt its owner only runs for a setup that can proceed.
  if options.password_cmd then
    local password, command_error = password_from_command(options.password_cmd)
    if not password then return nil, command_error end
    if options.register then options.password_secret = password else options.secret = password end
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
      ca_file = options.ca_file, pin = transport_pin(options.pin), pin_only = options.pin ~= nil,
      callback = function(response)
        if done_called or cancelled then return end
        if type(response) ~= "table" then
          return fail("Matrix setup " .. stage .. " request failed")
        end
        if tls_error(response) then return fail(tls_error(response)) end
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
    registration_password = options.password_secret or new_password()
    if not registration_password then
      return fail("This system has no secure random source for a bot password. Next: create a private password file, then rerun with --password-file PATH. PowerShell: [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)) | Set-Content -NoNewline FILE. POSIX: umask 077; head -c 24 /dev/urandom | base64 > FILE. Keep the file private.")
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
  local rejected_token = matrix.REJECTED_REGISTRATION_TOKEN
  local registration_disabled = "Account registration is disabled on this server. Nothing was created or written. Next: ask the server admin for a bot account, then rerun with --token-file PATH (the bot access token)."
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
      ca_file = options.ca_file, pin = transport_pin(options.pin), pin_only = options.pin ~= nil,
      callback = function(response)
        if done_called or cancelled then return end
        if tls_error(response) then return fail(tls_error(response)) end
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
        return fail(registration_disabled, challenge and challenge.errcode)
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
  local stored -- { backend, name } once the generated password is in the OS secure store
  local function failure(message)
    if stored then
      local ok, deleted = pcall(system.credential_delete, stored.name)
      if not ok or not deleted then message = message .. "; the password is still in the OS secure store" end
      stored = nil
    end
    if #orphan_ids > 0 then
      message = message .. "; orphan room ID" .. (#orphan_ids > 1 and "s" or "")
        .. ": " .. table.concat(orphan_ids, ", ")
    end
    return nil, message
  end
  local keeps_password = type(options) == "table" and saves_password(options)
  if type(options) ~= "table" or type(result) ~= "table"
    or type(result.token) ~= "string" or result.token == ""
    or type(result.user_id) ~= "string" or type(result.home_room) ~= "string"
    or (keeps_password
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

  -- A generated password goes to the OS secure store. --dir always means the
  -- file in that directory, and so does a store that is missing or says no.
  local uses_store = keeps_password and not options.output_dir and system.credential_backend() ~= nil
  local writes_password = keeps_password
  if not options.force then
    local checked = { options.token_path, options.config_path }
    if keeps_password and not uses_store then checked[#checked + 1] = options.password_path end
    for _, path in ipairs(checked) do
      if file_exists(path) then return failure("Matrix output file already exists; pass --force") end
    end
  end
  if uses_store then
    local name = "butler/matrix/" .. result.user_id .. "/password"
    local put, backend = system.credential_put(name, result.password)
    if put then stored, writes_password = { backend = backend, name = name }, false end
  end
  -- The account exists by now. A store that refused must not cost its password,
  -- so the fallback may replace an old password file even without --force.
  local replaces_password = uses_store and writes_password

  local paths = { options.token_path }
  if writes_password then paths[#paths + 1] = options.password_path end
  paths[#paths + 1] = options.config_path
  local path_labels = { [options.token_path] = "token", [options.config_path] = "config" }
  local contents = { [options.token_path] = result.token .. "\n" }
  if writes_password then
    path_labels[options.password_path] = "password"
    contents[options.password_path] = result.password .. "\n"
  end
  local config_lines = {
    options.homeserver, result.home_room, result.user_id, options.owner_mxid, "", "30000",
  }
  if result.all_room then config_lines[#config_lines + 1] = "all_room=" .. result.all_room end
  if options.rooms_mode == "open" then config_lines[#config_lines + 1] = "rooms=open" end
  if options.pin then config_lines[#config_lines + 1] = "pin_sha256=" .. options.pin end
  if options.ca_file then config_lines[#config_lines + 1] = "ca_file=" .. options.ca_file end
  contents[options.config_path] = table.concat(config_lines, "\n") .. "\n"

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
      if not options.force and not (replaces_password and path == options.password_path) then
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

  -- Hand-added deny rules outlive a --force rewrite (#146).
  for line in (backups[options.config_path] or ""):gmatch("[^\r\n]+") do
    -- Mirror the config parser: the key before the first "=" is trimmed.
    if line:match("^%s*deny_room%s*=") or line:match("^%s*deny_server%s*=") then
      contents[options.config_path] = contents[options.config_path] .. line .. "\n"
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
  local files = { token_path = options.token_path, config_path = options.config_path,
    password_path = writes_password and options.password_path or nil, password_store = stored }
  if writes_password then
    files.password_replaced = replaces_password and not options.force
      and backups[options.password_path] ~= nil or nil
  elseif options.secret_kind == "registration" and type(options.password_path) == "string"
    and file_exists(options.password_path) then
    files.old_password_path = options.password_path
  end
  return files
end

return matrix
