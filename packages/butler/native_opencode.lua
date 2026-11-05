-- Owner-declared adoption of an already-running OpenCode server.
-- Butler owns the row id + opaque instance fence and the private binding
-- path; the core `_opencode_adopt` helper owns the credentialled /api/info and
-- /api/session proof, the local pid/start corroboration and the manifest
-- publication. This module is pure glue: normalize nothing, freeze the strict
-- request, run the helper once and map its one-line typed answer. The
-- password stays in the request/manifest only and is never persisted here.
local M = {}

local VERSION = 1
local DEFAULT_TIMEOUT = 25
local MAX_PATH = 1024
local MAX_TOKEN = 128
local MAX_PASSWORD = 1024

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

local function valid_binding(value)
  return type(value) == "string" and #value >= 1 and #value <= MAX_PATH
    and value:sub(1, 1) == "/" and value:find("%c") == nil
end

-- Exactly `http://127.0.0.1:PORT`: literal IPv4 loopback, port 1..65535, no
-- trailing slash, path, query, userinfo or hostname. No normalization.
function M.valid_endpoint(value)
  if type(value) ~= "string" then return false end
  local port_text = value:match("^http://127%.0%.0%.1:(%d+)$")
  if not port_text or #port_text < 1 or #port_text > 5 then return false end
  local port = tonumber(port_text)
  return port ~= nil and port >= 1 and port <= 65535
end

-- The bounded URL-safe `ses_` subset: real 2.2.5 default ids (30 chars,
-- mixed case) and synthetic `ses_`+32hex. Final proof stays the exact GET.
function M.valid_conversation(value)
  if type(value) ~= "string" or #value > 128 then return false end
  local suffix = value:match("^ses_(.+)$")
  return suffix ~= nil and suffix:match("^[%w_%-]+$") ~= nil
end

function M.valid_password(value)
  return type(value) == "string" and #value >= 1 and #value <= MAX_PASSWORD
end

function M.build(fields)
  fields = fields or {}
  if not valid_binding(fields.binding) then return nil, "invalid_binding" end
  if not valid_token(fields.nonce) then return nil, "invalid_nonce" end
  if not valid_token(fields.session) then return nil, "invalid_session" end
  if not M.valid_endpoint(fields.endpoint) then return nil, "invalid_endpoint" end
  if not M.valid_conversation(fields.conversation) then
    return nil, "invalid_conversation"
  end
  if not M.valid_password(fields.password) then return nil, "invalid_password" end
  return { version = VERSION, binding = fields.binding, nonce = fields.nonce,
    session = fields.session, endpoint = fields.endpoint,
    conversation = fields.conversation,
    auth = { scheme = "basic", user = "opencode", password = fields.password } }
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

-- The adopted generation is the server start in microseconds, lowercase hex,
-- at most 16 characters (not the 64-hex Codex generation).
function M.valid_generation(value)
  return type(value) == "string" and #value >= 1 and #value <= 16
    and value:match("^[0-9a-f]+$") ~= nil
end

local function strict_keys(value, allowed)
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end

-- adopted needs a valid generation; unavailable needs a non-empty reason.
-- Anything else is uncertain and never becomes a binding.
function M.classify(stdout, options)
  local codec, why = codec_of(options)
  if not codec then return { outcome = "uncertain", reason = why } end
  local ok, value = pcall(codec.decode, stdout)
  if not ok or type(value) ~= "table" or type(value.outcome) ~= "string" then
    return { outcome = "uncertain", reason = "invalid_response" }
  end
  if value.outcome == "adopted" then
    if not strict_keys(value, ADOPTED_KEYS) or not M.valid_generation(value.generation) then
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

-- The helper makes two HTTP requests (5s each) plus the local proof; 25s
-- leaves room on a slow host without ever retrying.
-- One adopt call. A refusal or uncertain answer leaves the live session
-- untouched; nothing is retried automatically.
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
  local ok, result = pcall(runner, { argv = { options.remuda or "remuda", "_opencode_adopt" },
    stdin = text, timeout = options.timeout or DEFAULT_TIMEOUT })
  if not ok or type(result) ~= "table" then
    return { outcome = "uncertain", reason = "runner_failed" }
  end
  if result.timed_out then return { outcome = "uncertain", reason = "timeout" } end
  local classified = M.classify(result.stdout, options)
  -- The helper exits 0 for adopted and unavailable. A nonzero exit is never
  -- trusted as adopted; a typed refusal still stands as unavailable.
  if result.code ~= 0 then
    if classified.outcome == "unavailable" then return classified end
    return { outcome = "uncertain", reason = "helper_exit_" .. tostring(result.code) }
  end
  return classified
end

M.DEFAULT_TIMEOUT = DEFAULT_TIMEOUT
remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_opencode = M
return M
