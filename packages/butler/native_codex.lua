-- Owner-declared adoption of an existing Codex app-server session.
-- Butler owns the row id + opaque instance fence and the private binding path;
-- the core `_codex_adopt` helper owns the endpoint, peer/process/socket proof,
-- the exact 0.166.0 preflight and the pin/manifest publication. This module is
-- pure glue: normalize the owner's declared local socket, freeze the strict
-- request, run the helper once, and map its one-line typed answer. It never
-- reads the manifest, never accepts a remote endpoint and never retries an
-- unknown result. Socket and thread are not persisted by this module.
local M = {}

local VERSION = 1
local DEFAULT_TIMEOUT = 15
local MAX_PATH = 1024
local MAX_TOKEN = 128

local function codec_of(options)
  local codec = options and options.json or (remuda and remuda.json)
  if type(codec) ~= "table" or type(codec.encode) ~= "function"
      or type(codec.decode) ~= "function" then
    return nil, "codec_unavailable"
  end
  return codec
end

local function valid_token(value)
  return type(value) == "string" and #value >= 1 and #value <= MAX_TOKEN
    and value:match("^[%w_%-]+$") ~= nil
end

local function valid_nonce(value)
  return type(value) == "string" and #value >= 16 and #value <= MAX_TOKEN
    and #value % 2 == 0 and value:match("^[0-9a-f]+$") ~= nil
end

local function valid_binding(value)
  return type(value) == "string" and #value >= 1 and #value <= MAX_PATH
    and value:sub(1, 1) == "/" and value:find("%c") == nil
end

-- Only the documented local `unix://` form is normalized, and only to an
-- absolute filesystem path. Remote schemes, queries, fragments and control
-- characters are refused instead of guessed at.
function M.normalize_socket(value)
  if type(value) ~= "string" or value == "" then return nil, "socket_invalid" end
  local path = value
  if path:sub(1, 7) == "unix://" then
    path = path:sub(8)
  elseif path:find("://", 1, true) then
    return nil, "socket_scheme"
  end
  if #path > MAX_PATH then return nil, "socket_too_long" end
  if path:find("%c") or path:find("[?#]") then return nil, "socket_invalid" end
  if path:sub(1, 1) ~= "/" then return nil, "socket_not_absolute" end
  return path
end

-- A canonical lowercase UUID. The owner copies it from a fresh /status; an
-- uppercase or truncated value is refused rather than normalized.
function M.valid_thread(value)
  if type(value) ~= "string" or #value ~= 36 then return false end
  if value ~= value:lower() then return false end
  return value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

function M.build(fields)
  fields = fields or {}
  if not valid_binding(fields.binding) then return nil, "invalid_binding" end
  if not valid_nonce(fields.nonce) then return nil, "invalid_nonce" end
  if not valid_token(fields.session) then return nil, "invalid_session" end
  local socket, socket_why = M.normalize_socket(fields.socket)
  if not socket then return nil, socket_why end
  if not M.valid_thread(fields.thread) then return nil, "invalid_thread" end
  return { version = VERSION, binding = fields.binding, nonce = fields.nonce,
    session = fields.session, socket = socket, thread = fields.thread }
end

local function encode(request, options)
  local codec, why = codec_of(options)
  if not codec then return nil, why end
  local ok, text = pcall(codec.encode, request)
  if not ok or type(text) ~= "string" or text == "" then return nil, "encode_failed" end
  if #text > 64 * 1024 then return nil, "request_too_large" end
  return text
end

local ADOPTED_KEYS = { outcome = true, generation = true }
local UNAVAILABLE_KEYS = { outcome = true, reason = true }

local function valid_generation(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function strict_keys(value, allowed)
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end

-- The helper's single JSON line is authoritative: adopted needs a 64-hex
-- generation, unavailable needs a non-empty reason. Anything else is
-- uncertain and never becomes a binding.
function M.classify(stdout, options)
  local codec, why = codec_of(options)
  if not codec then return { outcome = "uncertain", reason = why } end
  local ok, value = pcall(codec.decode, stdout)
  if not ok or type(value) ~= "table" or type(value.outcome) ~= "string" then
    return { outcome = "uncertain", reason = "invalid_response" }
  end
  if value.outcome == "adopted" then
    if not strict_keys(value, ADOPTED_KEYS) or not valid_generation(value.generation) then
      return { outcome = "uncertain", reason = "invalid_response" }
    end
    return { outcome = "adopted", generation = value.generation }
  end
  if value.outcome == "unavailable" then
    if not strict_keys(value, UNAVAILABLE_KEYS) or type(value.reason) ~= "string"
        or value.reason == "" then
      return { outcome = "uncertain", reason = "invalid_response" }
    end
    return { outcome = "unavailable", reason = value.reason }
  end
  return { outcome = "uncertain", reason = "invalid_response" }
end

local function runner_of(options)
  return options.runner or (remuda and remuda.process and remuda.process.run)
end

-- One adopt call. Adoption is non-mutating on the agent: the core publishes
-- only after its preflight, so a refused or uncertain answer leaves the live
-- session untouched. No automatic retry is performed here.
function M.adopt(fields, options)
  options = options or {}
  local request, why = M.build(fields)
  if not request then return { outcome = "unavailable", reason = why } end
  local text, encode_why = encode(request, options)
  if not text then return { outcome = "uncertain", reason = encode_why } end
  local runner = runner_of(options)
  if type(runner) ~= "function" then
    return { outcome = "uncertain", reason = "runner_unavailable" }
  end
  local ok, result = pcall(runner, { argv = { options.remuda or "remuda", "_codex_adopt" },
    stdin = text, timeout = options.timeout or DEFAULT_TIMEOUT })
  if not ok or type(result) ~= "table" then
    return { outcome = "uncertain", reason = "runner_failed" }
  end
  if result.timed_out then return { outcome = "uncertain", reason = "timeout" } end
  local classified = M.classify(result.stdout, options)
  -- A typed answer is authoritative even with a nonzero exit; an untyped
  -- nonzero is unknown and never published as a binding.
  if result.code ~= 0 and classified.outcome == "uncertain" then
    return { outcome = "uncertain", reason = "helper_exit_" .. tostring(result.code) }
  end
  return classified
end

M.DEFAULT_TIMEOUT = DEFAULT_TIMEOUT
remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_codex = M
return M
