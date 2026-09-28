-- Public Matrix CLI words. Each operation is a thin dispatch to matrix_cli.py,
-- whose verbs compose the shared matrix_http trust/limit/allow/request units.
local public = remuda.butler or {}
remuda.butler = public
local matrix = public.matrix or {}
public.matrix = matrix

local config = remuda._butler_matrix_config
local home = os.getenv("XDG_DATA_HOME")
if not home or home == "" then home = (os.getenv("HOME") or "") .. "/.local/share" end
local package_dir = home .. "/remuda/mods/butler/packages/butler"
local script_path = package_dir .. "/matrix_cli.py"
local token_path = config and config.token_path
local config_path = config and config.config_path
local state_dir = config_path and (config_path .. ".state") or ""

local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\"'\\"'") .. "'"
end

local function run(verb, values, json_mode)
  if not token_path or not config_path then error("Matrix is not configured", 0) end
  local argv = { "python3", script_path, token_path, config_path, state_dir, verb }
  if json_mode then argv[#argv + 1] = "--json" end
  for _, value in ipairs(values) do argv[#argv + 1] = tostring(value) end
  local quoted = {}
  for _, value in ipairs(argv) do quoted[#quoted + 1] = quote(value) end
  local pipe = assert(io.popen(table.concat(quoted, " ") .. " 2>&1", "r"))
  local output = pipe:read("*a")
  local ok, _, code = pipe:close()
  output = output:gsub("%s+$", "")
  if not ok then error(output ~= "" and output or ("Matrix " .. verb .. " failed (" .. tostring(code) .. ")"), 0) end
  return output
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

local function operator_only(verb, opts, caller)
  if caller and caller.env and ((caller.env.REMUDA_BUTLER_AGENT_ID or "") ~= ""
      or (caller.env.REMUDA_BUTLER_SESSION_NAME or "") ~= "") then
    error("matrix " .. verb .. " is operator-only", 0)
  end
  opts = opts or {}
  assert(opts.room, verb .. " requires room")
  return run(verb, { opts.room }, opts.json)
end

function matrix.join(opts, caller) return operator_only("join", opts, caller) end
function matrix.leave(opts, caller) return operator_only("leave", opts, caller) end

return matrix
