-- S2 Matrix setup argument parsing and local safety checks. Network and
-- credential-file creation are added in later setup steps.
local matrix = assert(remuda.butler and remuda.butler.matrix, "Matrix request word is unavailable")

local USAGE = [[Usage: remuda butler matrix setup --homeserver URL --owner MXID
  (--password-file PATH --bot MXID | --token-file PATH) [--dir PATH | --default]
  [--force] [--all] [--pin SHA256HEX | --ca-file PATH]]

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

local function valid_mxid(value, label)
  if type(value) ~= "string" then return nil, label .. " MXID is required" end
  local localpart, server = value:match("^@([^:]+):(.+)$")
  if not localpart or localpart:find("[%s%c/@]") or server == ""
    or server:find("[%s%c/#?]") then
    return nil, label .. " must be a Matrix user ID such as @user:server"
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

local function create_output_directory(path, options)
  if type(remuda.fs) ~= "table" or type(remuda.fs.mkdir_new) ~= "function" then
    return nil, "core does not provide remuda.fs.mkdir_new"
  end
  local parent = path:match("^(.*)/[^/]+$")
  if parent and type(remuda.mkdir) == "function" then remuda.mkdir(parent) end
  local created, reason = remuda.fs.mkdir_new(path)
  if created == true then return true end
  if reason == "exists" and (options.force or options.dir) then return false end
  if reason == "exists" then
    return nil, "default output directory already exists; pass --force or choose an existing --dir"
  end
  return nil, "cannot create private output directory: " .. tostring(reason or "unknown error")
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
  -- Atomic replacement does not follow an output symlink. A symlinked parent
  -- cannot be detected without lstat, so the caller owns the selected path.
  local directories = {}
  local function add_directory(path)
    if path and not directories[path] then directories[path] = true end
  end
  if dir then add_directory(dir)
  else
    add_directory(token_path:match("^(.*)/[^/]+$"))
    add_directory(config_path:match("^(.*)/[^/]+$"))
  end
  for path in pairs(directories) do
    local made, make_error = create_output_directory(path, options)
    if made == nil then return nil, make_error end
  end
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
  local owner, owner_error = valid_mxid(options.owner_mxid, "owner")
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
    local bot, bot_error = valid_mxid(options.bot_mxid, "bot")
    if not bot then return nil, bot_error end
    options.bot_mxid = bot
  elseif options.bot_mxid then
    local bot, bot_error = valid_mxid(options.bot_mxid, "bot")
    if not bot then return nil, bot_error end
    options.bot_mxid = bot
  end
  if options.bot_mxid and options.bot_mxid == options.owner_mxid then
    return nil, "bot and owner MXIDs must be different"
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

return matrix
