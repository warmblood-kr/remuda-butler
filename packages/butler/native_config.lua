-- Default-off selection for the native OpenCode bridge (phase 2).
-- Pure: config text, file read, JSON codec, capability runner and platform are
-- injected so the decision can be unit-tested without a daemon or a launch.
-- Nothing here mutates state: it answers "should this NEW launch be native?".
local M = {}

local PROTOCOL = "opencode-http-v1"
local CAPABILITY_TIMEOUT = 5

local function codec_of(options)
  local codec = options and options.json or (remuda and remuda.json)
  if type(codec) ~= "table" or type(codec.decode) ~= "function" then
    return nil, "codec_unavailable"
  end
  return codec
end

local function decode(codec, text)
  if type(text) ~= "string" or text == "" then return nil, "empty" end
  local ok, value = pcall(codec.decode, text)
  if not ok or type(value) ~= "table" then return nil, "invalid_json" end
  return value
end

-- A missing file is the default: off, no error. Malformed content is also off,
-- with an explicit reason for the launch trace (never a silent enable).
local function valid_root(value)
  for key in pairs(value) do
    if key ~= "version" and key ~= "opencode" then return nil, "config_invalid: unknown_key" end
  end
  if type(value.version) ~= "number" or value.version ~= 1 then
    return nil, "config_version"
  end
  return true
end

-- nil means invalid (with a reason); false is an explicit switch off.
local function opencode_enabled(value)
  local opencode = value.opencode
  if type(opencode) ~= "table" then return nil, "config_invalid: opencode" end
  for key in pairs(opencode) do
    if key ~= "enabled" then return nil, "config_invalid: unknown_key" end
  end
  if type(opencode.enabled) ~= "boolean" then return nil, "config_invalid: enabled" end
  return opencode.enabled
end

function M.read(text, options)
  local codec, why = codec_of(options)
  if not codec then return { enabled = false, reason = why } end
  if text == nil then return { enabled = false, reason = "config_missing" } end
  local value, decode_why = decode(codec, text)
  if not value then return { enabled = false, reason = "config_invalid: " .. decode_why } end
  local root_ok, root_why = valid_root(value)
  if not root_ok then return { enabled = false, reason = root_why } end
  local enabled, enabled_why = opencode_enabled(value)
  if enabled == nil then return { enabled = false, reason = enabled_why } end
  if enabled ~= true then return { enabled = false, reason = "disabled" } end
  return { enabled = true, reason = "enabled" }
end

function M.load(path, options)
  options = options or {}
  if type(path) ~= "string" or path == "" then
    return { enabled = false, reason = "config_missing" }
  end
  local read = options.read
  if type(read) ~= "function" then return { enabled = false, reason = "read_unavailable" } end
  local ok, text, err = pcall(read, path)
  if not ok then return { enabled = false, reason = "config_read_failed: " .. tostring(text) } end
  if text == nil then
    if err == "missing" or err == nil then return { enabled = false, reason = "config_missing" } end
    return { enabled = false, reason = "config_read_failed: " .. tostring(err) }
  end
  return M.read(text, options)
end

-- Exact supported protocol and a usable binary. Any other answer (including a
-- missing helper or a timeout) disables only NEW launches.
function M.parse_capability(stdout, options)
  local codec, why = codec_of(options)
  if not codec then return false, why end
  local value, decode_why = decode(codec, stdout)
  if not value then return false, "capability_" .. decode_why end
  if value.native_notice ~= true then return false, "capability_unsupported" end
  if value.protocol ~= PROTOCOL then return false, "capability_protocol" end
  if value.platform ~= "macos" and value.platform ~= "linux" then
    return false, "capability_platform"
  end
  return true, "capability_ok"
end

function M.probe(options)
  options = options or {}
  local runner = options.runner or (remuda and remuda.process and remuda.process.run)
  if type(runner) ~= "function" then return false, "capability_runner_unavailable" end
  local argv = { options.remuda or "remuda", "_opencode_tui", "--capability" }
  local ok, result = pcall(runner, { argv = argv, timeout = CAPABILITY_TIMEOUT })
  if not ok or type(result) ~= "table" then return false, "capability_failed" end
  if result.timed_out then return false, "capability_timeout" end
  if result.code ~= 0 then return false, "capability_exit_" .. tostring(result.code) end
  return M.parse_capability(result.stdout, options)
end

M.PROTOCOL = PROTOCOL
remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_config = M
return M
