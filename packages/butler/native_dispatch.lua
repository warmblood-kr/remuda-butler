-- Narrow client for the frozen core notice helpers.
-- One immutable Request1 goes in on stdin; one typed JSON outcome comes out.
-- Butler selects a fixed per-kind verb from a closed map; no caller text can
-- become a command. No shell, temp file, flag, endpoint or credential: the
-- binding path and nonce are non-secret correlation data. Pure seams (JSON,
-- runner, clock) are injected so the mapping can be unit-tested without a
-- live server.
local M = {}

-- The only allowed helper entrypoints. OpenCode keeps its installed verb; the
-- Codex and Claude verbs are separate, strict protocol helpers. `_agent_notice`
-- is never used for Codex/Claude.
local VERBS = { opencode = "_agent_notice", codex = "_codex_notice",
  claude = "_claude_notice" }
-- Read-only lookup for callers/tests; the table itself stays module-local so
-- no caller can substitute an arbitrary command.
function M.verb(kind) return VERBS[kind] end

local VERSION = 1
local DEFAULT_TIMEOUT = 15
local MAX_TEXT = 1024
local MAX_REQUEST_ID = 128
local MAX_ID = 128

local DEAD = {
  invalid_binding = true, wrapper_gone = true, server_gone = true,
  server_not_owned = true, stale_binding = true, auth = true,
  target_missing = true, target_unverified = true,
  -- A wrong or unverified server identity, or an unsupported platform after a
  -- bound launch, means the binding/helper is unusable: disable, never PTY.
  server_identity = true, server_unverified = true, unsupported_platform = true,
}
local NOT_WRITTEN = {
  invalid_args = true, invalid_request = true,
}
local UNCERTAIN = {
  transport = true, http_400 = true, http_409 = true, http_5xx = true,
  receipt_mismatch = true, uncertain = true,
}
-- Codex: a proven pre-write refusal, split into dead bindings and retryable
-- local refusals. `binding_missing` is special: the caller decides whether it
-- is a startup window or a formerly-published binding that disappeared.
local CODEX_DEAD = {
  invalid_binding = true, manifest_invalid = true, invalid_manifest = true,
  socket_missing = true, socket_dead = true, socket_mismatch = true,
  socket_unverified = true, endpoint_unverified = true, endpoint_gone = true,
  peer_mismatch = true, peer_unverified = true, version_mismatch = true,
  thread_mismatch = true,
  thread_not_loaded = true, not_loaded = true, auth = true,
  target_missing = true, target_unverified = true, bridge_gone = true,
  unsupported_platform = true,
}
local CODEX_NOT_WRITTEN = { invalid_args = true, invalid_request = true }
-- Claude: pre-emission refusals only. `channel_emitted_unconfirmed` and any
-- post-emission unknown stay uncertain; an ACK is never accepted_queue.
local CLAUDE_DEAD = {
  invalid_binding = true, stale_binding = true, channel_unavailable = true,
  channel_gone = true, bridge_gone = true, peer_mismatch = true,
  socket_mismatch = true, version_mismatch = true, auth = true,
  target_missing = true, target_unverified = true, manifest_invalid = true,
  invalid_manifest = true, state_unavailable = true, unsupported_platform = true,
}
local CLAUDE_NOT_WRITTEN = {
  invalid_args = true, invalid_request = true, claim_refused = true,
  ingress_refused = true, not_initialized = true, queue_full = true,
}
local STARTUP_PENDING = "binding_missing"
local RESPONSE_KEYS = { outcome = true, reason = true }

local function valid_id(value)
  return type(value) == "string" and #value >= 1 and #value <= MAX_ID
    and value:match("^[%w_%-]+$") ~= nil
end

local function valid_request_id(value)
  return type(value) == "string" and #value <= MAX_REQUEST_ID
    and value:match("^msg_[%w_%-]+$") ~= nil
end

local function valid_binding(value)
  -- Our launch passes the manifest FILE path; the helper is the authoritative
  -- validator of the binding itself, so this layer only rejects non-absolute
  -- or malformed strings.
  return type(value) == "string" and #value >= 1 and #value <= 1024
    and value:sub(1, 1) == "/" and value:find("%c") == nil
end

local function valid_nonce(value)
  return type(value) == "string" and #value >= 16 and #value <= 128
    and #value % 2 == 0 and value:match("^[0-9a-f]+$") ~= nil
end

local INBOX = "MCP butler_inbox (or remuda butler inbox)"

local function canonical_text(ids)
  if #ids == 1 then
    return "Butler message " .. ids[1] .. " arrived. Read it: " .. INBOX
  end
  return #ids .. " new Butler messages arrived. Read them: " .. INBOX
end

local function canonical_match(text, ids)
  if type(text) ~= "string" or text == "" or #text > MAX_TEXT then return false end
  if text:find("[%z\r\n]") then return false end
  return text == canonical_text(ids)
end

local function dense_array(value)
  if type(value) ~= "table" then return false end
  local count = #value
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key > count or key % 1 ~= 0 then return false end
  end
  for index = 1, count do if value[index] == nil then return false end end
  return true
end

local function copy_ids(ids)
  if type(ids) ~= "table" or #ids < 1 then return nil, "no_message_ids" end
  if not dense_array(ids) then return nil, "message_ids_schema" end
  local out, seen = {}, {}
  for _, id in ipairs(ids) do
    if not valid_id(id) then return nil, "invalid_message_id" end
    if seen[id] then return nil, "duplicate_message_id" end
    seen[id] = true
    out[#out + 1] = id
  end
  return out
end

-- Freeze one request. `instance` is accepted by the helper for compatibility
-- but is not used for matching; the binding decision remains Butler's.
function M.build(fields)
  fields = fields or {}
  if not valid_binding(fields.binding) then return nil, "invalid_binding" end
  if not valid_nonce(fields.nonce) then return nil, "invalid_nonce" end
  if not valid_id(fields.session) then return nil, "invalid_session" end
  if not valid_id(fields.instance) then return nil, "invalid_instance" end
  if not valid_request_id(fields.request_id) then return nil, "invalid_request_id" end
  local ids, ids_err = copy_ids(fields.message_ids)
  if not ids then return nil, ids_err end
  if not canonical_match(fields.text, ids) then return nil, "invalid_text" end
  return { version = VERSION, binding = fields.binding, nonce = fields.nonce,
    session = fields.session, instance = fields.instance,
    request_id = fields.request_id, text = fields.text, message_ids = ids }
end

local function codec_of(options)
  local codec = options and options.json or (remuda and remuda.json)
  if type(codec) ~= "table" or type(codec.encode) ~= "function"
      or type(codec.decode) ~= "function" then
    return nil, "codec_unavailable"
  end
  return codec
end

function M.encode(request, options)
  local codec, why = codec_of(options)
  if not codec then return nil, why end
  -- The core JSON codec distinguishes arrays with its marker; the helper
  -- requires message_ids to be a JSON array, never an object keyed "1", "2".
  local payload = request
  if type(codec.array) == "function" then
    payload = {}
    for key, value in pairs(request) do payload[key] = value end
    payload.message_ids = codec.array(request.message_ids)
  end
  local ok, text = pcall(codec.encode, payload)
  if not ok or type(text) ~= "string" or text == "" then return nil, "encode_failed" end
  if #text > 64 * 1024 then return nil, "request_too_large" end
  return text
end

local function strict_response(value)
  if type(value) ~= "table" or type(value.outcome) ~= "string" then return false end
  for key in pairs(value) do if not RESPONSE_KEYS[key] then return false end end
  if value.reason ~= nil and type(value.reason) ~= "string" then return false end
  return true
end

local function accepted_outcome(value)
  -- The frozen core response is exactly {outcome} with no reason. Any reason
  -- field is an unproven shape and must not be accepted.
  if value.reason ~= nil then return { outcome = "uncertain", reason = "invalid_response" } end
  return { outcome = "accepted", reason = "" }
end

local function refused_outcome(reason, kind)
  if reason == "" then return { outcome = "uncertain", reason = "invalid_response" } end
  if kind == "codex" then
    if reason == STARTUP_PENDING then
      return { outcome = "not_written", reason = reason, startup_pending = true }
    end
    if CODEX_DEAD[reason] then return { outcome = "dead_binding", reason = reason } end
    if CODEX_NOT_WRITTEN[reason] then return { outcome = "not_written", reason = reason } end
    return { outcome = "uncertain", reason = "unknown_reason" }
  end
  if kind == "claude" then
    if reason == STARTUP_PENDING then
      return { outcome = "not_written", reason = reason, startup_pending = true }
    end
    if CLAUDE_DEAD[reason] then return { outcome = "dead_binding", reason = reason } end
    if CLAUDE_NOT_WRITTEN[reason] then return { outcome = "not_written", reason = reason } end
    return { outcome = "uncertain", reason = "unknown_reason" }
  end
  if reason == STARTUP_PENDING then
    return { outcome = "not_written", reason = reason, startup_pending = true }
  end
  if DEAD[reason] then return { outcome = "dead_binding", reason = reason } end
  if NOT_WRITTEN[reason] then return { outcome = "not_written", reason = reason } end
  return { outcome = "uncertain", reason = "unknown_reason" }
end

local function uncertain_outcome(value, name, reason, kind)
  if name == "uncertain" then
    -- Codex/Claude reasons are comment-free tokens from their own strict
    -- helper; every one of them is final. OpenCode keeps its allowlist.
    if kind == "codex" or kind == "claude" then
      return { outcome = "uncertain", reason = reason ~= "" and reason or "uncertain" }
    end
    if reason ~= "" and not UNCERTAIN[reason] then
      return { outcome = "uncertain", reason = "unknown_reason" }
    end
    return { outcome = "uncertain", reason = reason ~= "" and reason or "uncertain" }
  end
  if UNCERTAIN[name] and value.reason == nil then
    return { outcome = "uncertain", reason = name }
  end
  return { outcome = "uncertain", reason = "invalid_response" }
end

-- Unknown, missing or wrong-typed fields/reasons are uncertain, never a
-- retryable "nothing was written".
local function outcome(value, kind)
  if not strict_response(value) then
    return { outcome = "uncertain", reason = "invalid_response" }
  end
  local name, reason = value.outcome, value.reason or ""
  if name == "accepted_queue" then
    -- The Claude helper never proves queue admission; an ACK there must not be
    -- promoted into success.
    if kind == "claude" then return { outcome = "uncertain", reason = "invalid_response" } end
    return accepted_outcome(value)
  end
  if name == "definitely_not_written" then return refused_outcome(reason, kind) end
  return uncertain_outcome(value, name, reason, kind)
end

function M.classify(stdout, options)
  options = options or {}
  local kind = options.kind or "opencode"
  if not VERBS[kind] then return { outcome = "dead_binding", reason = "invalid_kind" } end
  local codec, why = codec_of(options)
  if not codec then return { outcome = "uncertain", reason = why } end
  local ok, value = pcall(codec.decode, stdout)
  if not ok or type(value) ~= "table" then
    return { outcome = "uncertain", reason = "invalid_response" }
  end
  return outcome(value, kind)
end

local function runner_of(options)
  return options.runner or (remuda and remuda.process and remuda.process.run)
end

-- A completed helper that printed a typed refusal is authoritative even with
-- a nonzero exit; an accepted or untyped answer is not.
local function typed_refusal(stdout, options)
  local result = M.classify(stdout, options)
  if result.outcome == "dead_binding" or result.outcome == "not_written" then
    return result
  end
end

local function result_outcome(result, options)
  if result.timed_out then return { outcome = "uncertain", reason = "timeout" } end
  if result.code ~= 0 then
    return typed_refusal(result.stdout, options)
      or { outcome = "uncertain", reason = "helper_exit_" .. tostring(result.code) }
  end
  return M.classify(result.stdout, options)
end

local function encode_request(request, options)
  local text, why = M.encode(request, options)
  if text then return text end
  -- A local preflight refusal wrote nothing; a live binding may retry the
  -- bounded schedule. A missing codec cannot be classified at all.
  if why == "request_too_large" or why == "encode_failed" then
    return nil, { outcome = "not_written", reason = why }
  end
  return nil, { outcome = "uncertain", reason = why }
end

local function run_helper(runner, text, options, verb)
  local argv = { options.remuda or "remuda", verb }
  local ok, result = pcall(runner, { argv = argv, stdin = text,
    timeout = options.timeout or DEFAULT_TIMEOUT })
  if not ok or type(result) ~= "table" then
    return nil, { outcome = "uncertain", reason = "runner_failed" }
  end
  return result
end

-- A nonzero exit, timeout or missing runner is never "nothing was written":
-- the helper may have POSTed before it died, so it is uncertain and never
-- retried automatically.
function M.dispatch(request, options)
  options = options or {}
  local kind = options.kind or "opencode"
  local verb = VERBS[kind]
  if not verb then return { outcome = "dead_binding", reason = "invalid_kind" } end
  local runner = runner_of(options)
  if type(runner) ~= "function" then
    return { outcome = "uncertain", reason = "runner_unavailable" }
  end
  local text, encode_outcome = encode_request(request, options)
  if not text then return encode_outcome end
  local result, run_outcome = run_helper(runner, text, options, verb)
  if not result then return run_outcome end
  return result_outcome(result, options)
end

M.DEFAULT_TIMEOUT = DEFAULT_TIMEOUT
remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_dispatch = M
return M
