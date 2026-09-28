-- Public Matrix CLI words. Each operation is a thin dispatch to matrix_cli.py,
-- whose verbs compose the shared matrix_http trust/limit/allow/request units.
local public = remuda.butler or {}
remuda.butler = public
local matrix = public.matrix or {}
public.matrix = matrix

local windows = package.config and package.config:sub(1, 1) == "\\"

local function quote(value)
  value = tostring(value)
  if windows then
    -- cmd.exe expands metacharacters even inside quotes; double percent and
    -- caret-escape command separators before applying Windows argv quoting.
    value = value:gsub("%%", "%%%%"):gsub("([%^&|<>])", "^%1")
    value = '"' .. value:gsub('(\\*)"', '%1%1\\"'):gsub("(\\+)$", "%1%1") .. '"'
    return value
  end
  return "'" .. value:gsub("'", "'\\"'\\"'") .. "'"
end

local function paths()
  local config = remuda._butler_matrix_config
  if not config or not config.token_path or not config.config_path then
    error("Matrix is not configured", 0)
  end
  local relay_path = config.relay_path or (remuda.butler and remuda.butler.matrix
    and remuda.butler.matrix._relay_path)
  if not relay_path then error("Matrix package path is unavailable; reload Butler", 0) end
  local script_path = relay_path:gsub("matrix_relay%.py$", "matrix_cli.py")
  if script_path == relay_path then error("Matrix dispatcher path is unavailable; reload Butler", 0) end
  return config.token_path, config.config_path, config.config_path .. ".state", script_path
end

local function python_words(script_path, token_path, config_path, state_dir, verb)
  local argv = windows and { "py", "-3", script_path, token_path, config_path, state_dir, verb }
    or { "python3", script_path, token_path, config_path, state_dir, verb }
  return argv
end

local function run(verb, values, json_mode)
  local token_path, config_path, state_dir, script_path = paths()
  local argv = python_words(script_path, token_path, config_path, state_dir, verb)
  if json_mode then argv[#argv + 1] = "--json" end
  for _, value in ipairs(values) do argv[#argv + 1] = tostring(value) end
  local quoted = {}
  for _, value in ipairs(argv) do quoted[#quoted + 1] = quote(value) end
  local stderr_path = os.tmpname()
  local pipe = assert(io.popen(table.concat(quoted, " ") .. " 2>" .. quote(stderr_path), "r"))
  local output = pipe:read("*a")
  local ok, _, code = pipe:close()
  local stderr = ""
  local err_file = io.open(stderr_path, "r")
  if err_file then stderr = err_file:read("*a"); err_file:close() end
  os.remove(stderr_path)
  output = output:gsub("%s+$", "")
  stderr = stderr:gsub("%s+$", "")
  if not ok then error(stderr ~= "" and stderr or ("Matrix " .. verb .. " failed (" .. tostring(code) .. ")"), 0) end
  return output
end

local function argv_for(verb, values, json_mode)
  local token_path, config_path, state_dir, script_path = paths()
  local argv = python_words(script_path, token_path, config_path, state_dir, verb)
  if json_mode then argv[#argv + 1] = "--json" end
  for _, value in ipairs(values) do argv[#argv + 1] = tostring(value) end
  return argv
end

local function option_args(opts)
  opts = opts or {}
  local values = {}
  if opts.room then values[#values + 1] = "--room"; values[#values + 1] = opts.room end
  if opts.json then values[#values + 1] = "--json" end
  return values
end

function matrix.send(opts)
  opts = opts or {}
  local values = option_args(opts)
  assert(opts.text ~= nil, "send requires text")
  values[#values + 1] = opts.text
  return run("send", values)
end

function matrix.queue_send(opts)
  opts = opts or {}
  assert(opts.text ~= nil, "send requires text")
  local values = {}
  if opts.room then values[#values + 1] = "--room"; values[#values + 1] = opts.room end
  values[#values + 1] = opts.text
  remuda.process({ argv = argv_for("send", values, false), on_exit = "butler-matrix-reply-exit" })
  return "queued"
end

function matrix.reply(opts)
  opts = opts or {}
  local values = option_args(opts)
  assert(opts.event_id and opts.text, "reply requires event_id and text")
  values[#values + 1] = opts.event_id
  values[#values + 1] = opts.text
  return run("reply", values)
end

function matrix.react(opts)
  opts = opts or {}
  local values = option_args(opts)
  assert(opts.event_id and opts.key, "react requires event_id and key")
  values[#values + 1] = opts.event_id
  values[#values + 1] = opts.key
  return run("react", values)
end

function matrix.upload(opts)
  opts = opts or {}
  local values = option_args(opts)
  assert(opts.file, "upload requires file")
  values[#values + 1] = opts.file
  return run("upload", values)
end

function matrix.redact(opts)
  opts = opts or {}
  local values = option_args(opts)
  assert(opts.event_id, "redact requires event_id")
  values[#values + 1] = opts.event_id
  if opts.reason then values[#values + 1] = opts.reason end
  return run("redact", values)
end

local function operator_only(verb, opts, agent)
  if agent then
    error("matrix " .. verb .. " is operator-only", 0)
  end
  opts = opts or {}
  assert(opts.room, verb .. " requires room")
  return run(verb, { opts.room }, opts.json)
end

function matrix.join(opts, agent) return operator_only("join", opts, agent) end
function matrix.leave(opts, agent) return operator_only("leave", opts, agent) end

return matrix
