-- Run from the repository root: luajit tests/butler_native_dispatch.lua
-- Frozen request construction, helper invocation and typed outcome mapping for
-- the native OpenCode bridge. Injected JSON/runner; no live server or shell.
local function literal(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = literal(item) end
    local keys = {}
    for key in pairs(value) do if type(key) ~= "number" then keys[#keys + 1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("[%q]=%s", key, literal(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

local codec = {
  encode = literal,
  array = function(value) return value end,
  decode = function(text) return assert(loadstring("return " .. text))() end,
}

remuda = { json = codec }
local module = dofile("packages/butler/native_dispatch.lua")
local notice_generation = {}
remuda._butler_notice = notice_generation
remuda.butler = remuda.butler or {}
local policy = {}
remuda.butler.send_policy = policy
local transport = assert(module.install(policy), "the policy takes the one-shot factory")
local function fields_of(request)
  return { binding = request.binding, nonce = request.nonce,
    session = request.session, instance = request.instance,
    request_id = request.request_id, text = request.text,
    message_ids = request.message_ids }
end
local function admit(request, opts)
  opts = opts or {}
  remuda.json = opts.json or codec
  remuda.process = opts.runner and { run = opts.runner } or nil
  local channel, why = transport(opts.kind or "opencode")
  if not channel then
    if why == "invalid_kind" then return { outcome = "dead_binding", reason = why } end
    return { outcome = "not_written", reason = why }
  end
  local claim, build_why = channel.prepare(fields_of(request))
  if not claim then return { outcome = "not_written", reason = build_why } end
  return channel.send(claim, function() return true end)
end
local options = { json = codec }

local base = {
  binding = "/home/me/.local/share/remuda/butler/bindings/lead/ab12/manifest.json",
  nonce = string.rep("ab", 16), session = "ses_0123456789abcdef0123456789abcdef",
  instance = "instance-1", request_id = "msg_M01ABC",
  text = "Butler message m1 arrived. Read it: MCP butler_inbox (or remuda butler inbox)",
  message_ids = { "m1" },
}

-- 1. One frozen request; no count cap; inputs are copied.
local request = module.build(base)
assert(request, "valid request builds")
assert(request.version == 1 and request.request_id == "msg_M01ABC", "envelope fields")
assert(#request.message_ids == 1, "ids preserved")
base.message_ids[1] = "changed"
assert(request.message_ids[1] == "m1", "request owns its ID list")
local many = {}
for index = 1, 128 do many[index] = "m" .. index end
local batch = module.build({ binding = base.binding, nonce = base.nonce, session = base.session,
  instance = base.instance, request_id = "msg_batch",
  text = "128 new Butler messages arrived. Read them: MCP butler_inbox (or remuda butler inbox)",
  message_ids = many })
assert(batch and #batch.message_ids == 128, "no message-id count cap")

-- 2. Validation is strict.
for _, case in ipairs({
  { field = "binding", value = "", reason = "invalid_binding" },
  { field = "binding", value = "relative/path", reason = "invalid_binding" },
  { field = "nonce", value = "", reason = "invalid_nonce" },
  { field = "nonce", value = "ab12", reason = "invalid_nonce" },
  { field = "nonce", value = "ZZ" .. string.rep("ab", 15), reason = "invalid_nonce" },
  { field = "session", value = "bad session", reason = "invalid_session" },
  { field = "instance", value = "", reason = "invalid_instance" },
  { field = "request_id", value = "req_1", reason = "invalid_request_id" },
  { field = "request_id", value = "msg_" .. string.rep("a", 130), reason = "invalid_request_id" },
  { field = "text", value = "line\nbreak", reason = "invalid_text" },
  { field = "text", value = string.rep("x", 1025), reason = "invalid_text" },
  { field = "message_ids", value = {}, reason = "no_message_ids" },
  { field = "message_ids", value = { "bad id" }, reason = "invalid_message_id" },
  { field = "message_ids", value = { [1] = "m1", hidden = "m2" }, reason = "message_ids_schema" },
  { field = "message_ids", value = { [1] = "m1", [3] = "m3" }, reason = "message_ids_schema" },
  { field = "message_ids", value = { "m1", "m1" }, reason = "duplicate_message_id" },
}) do
  local fields = {}
  for key, value in pairs(base) do fields[key] = value end
  fields[case.field] = case.value
  local built, why = module.build(fields)
  assert(built == nil and why == case.reason, "validation: " .. case.reason .. " got " .. tostring(why))
end

-- 3. The exact JSON text is the stdin payload.
local encoded = module.encode(request, options)
assert(encoded == codec.encode(request), "encode is the frozen request")
local saw_array = false
local marked = { array = function(value) saw_array = true; return value end,
  encode = codec.encode, decode = codec.decode }
assert(module.encode(request, { json = marked }) == encoded,
  "the array marker does not change the wire text")
assert(saw_array, "message_ids is encoded with the core array marker")

-- 4. Outcome mapping.
local function classify(value) return module.classify(codec.encode(value), options) end
assert(classify({ outcome = "accepted_queue" }).outcome == "accepted", "accepted_queue")
for _, reason in ipairs({ "invalid_binding", "wrapper_gone", "server_gone",
  "server_not_owned", "stale_binding", "auth", "target_missing", "target_unverified" }) do
  local result = classify({ outcome = "definitely_not_written", reason = reason })
  assert(result.outcome == "dead_binding" and result.reason == reason, "dead binding: " .. reason)
end
for _, reason in ipairs({ "server_identity", "server_unverified", "unsupported_platform" }) do
  assert(classify({ outcome = "definitely_not_written", reason = reason }).outcome
    == "dead_binding", "unusable binding: " .. reason)
end
for _, reason in ipairs({ "invalid_args", "invalid_request" }) do
  assert(classify({ outcome = "definitely_not_written", reason = reason }).outcome
    == "not_written", "proven pre-write refusal: " .. reason)
end
assert(classify({ outcome = "definitely_not_written", reason = "other" }).outcome
  == "uncertain", "an unknown reason is fail-closed, not retryable")
assert(classify({ outcome = "definitely_not_written" }).outcome == "uncertain",
  "a missing reason is fail-closed")
assert(classify({ outcome = "definitely_not_written", reason = 7 }).outcome == "uncertain",
  "a wrong-typed reason is fail-closed")
assert(classify({ outcome = "accepted_queue", extra = true }).outcome == "uncertain",
  "unknown response keys are fail-closed")
assert(classify({ outcome = "accepted_queue", reason = 7 }).outcome == "uncertain",
  "wrong-typed accepted reason is fail-closed")
assert(classify({ outcome = "accepted_queue", reason = "" }).outcome == "uncertain",
  "an empty accepted reason is fail-closed")
assert(classify({ outcome = "accepted_queue", reason = "queued" }).outcome == "uncertain",
  "an arbitrary accepted reason is fail-closed")
for _, reason in ipairs({ "transport", "http_400", "http_409", "http_5xx",
  "receipt_mismatch", "uncertain" }) do
  assert(classify({ outcome = "uncertain", reason = reason }).outcome == "uncertain",
    "uncertain: " .. reason)
end
for _, value in ipairs({ {}, { outcome = "made_up" } }) do
  assert(classify(value).outcome == "uncertain", "unknown response is uncertain")
end
assert(module.classify("not json", options).outcome == "uncertain", "malformed is uncertain")

-- 5. Invocation: exact argv, stdin, timeout 15; every transport failure is
-- uncertain (never silently retried).
local seen
local runner = function(spec)
  seen = spec
  return { code = 0, stdout = codec.encode({ outcome = "accepted_queue" }), stderr = "" }
end
local result = admit(request, { json = codec, runner = runner, remuda = "/bin/remuda" })
assert(result.outcome == "accepted", "dispatch accepted")
assert(seen.argv[1] == "remuda" and seen.argv[2] == "_agent_notice" and #seen.argv == 2,
  "exact helper argv, no flags")
assert(seen.stdin == encoded and seen.timeout == 15, "exact stdin and a modest timeout")
local timeout = admit(request, { json = codec,
  runner = function() return { code = 0, timed_out = true } end })
assert(timeout.outcome == "uncertain" and timeout.reason == "timeout", "timeout is uncertain")
local exited = admit(request, { json = codec,
  runner = function() return { code = 7, stdout = "" } end })
assert(exited.outcome == "uncertain", "nonzero helper exit is uncertain")
local threw = admit(request, { json = codec,
  runner = function() error("spawn failed") end })
assert(threw.outcome == "uncertain", "spawn failure is uncertain")
local no_runner = admit(request, { json = codec, runner = nil,
  process = nil })
assert(no_runner.outcome == "uncertain", "missing runner is uncertain")

-- 5b. A completed nonzero with a typed refusal is authoritative; accepted or
-- untyped output on nonzero stays uncertain.
local refused = admit(request, { json = codec, runner = function()
  return { code = 1, stdout = codec.encode({ outcome = "definitely_not_written",
    reason = "wrapper_gone" }), stderr = "" }
end })
assert(refused.outcome == "dead_binding" and refused.reason == "wrapper_gone",
  "a typed refusal on nonzero is honored")
local accepted_nonzero = admit(request, { json = codec, runner = function()
  return { code = 1, stdout = codec.encode({ outcome = "accepted_queue" }), stderr = "" }
end })
assert(accepted_nonzero.outcome == "uncertain", "accepted on nonzero is never accepted")
local untyped = admit(request, { json = codec, runner = function()
  return { code = 2, stdout = "boom", stderr = "boom" }
end })
assert(untyped.outcome == "uncertain" and untyped.reason == "helper_exit_2",
  "generic nonzero stays uncertain")

-- 6. The 64 KiB wire bound is an invalid request, not a silent drop.
local huge = {}
for index = 1, 600 do huge[index] = string.rep("x", 120) .. index end
local huge_request = module.build({ binding = base.binding, nonce = base.nonce,
  session = base.session, instance = base.instance, request_id = "msg_huge",
  text = "600 new Butler messages arrived. Read them: MCP butler_inbox (or remuda butler inbox)",
  message_ids = huge })
assert(huge_request, "the request builder itself has no small count cap")
local huge_result = admit(huge_request, { json = codec,
  runner = function() error("must not run") end })
assert(huge_result.outcome == "not_written" and huge_result.reason == "request_too_large",
  "an oversized wire request is a proven pre-write refusal")

-- 7. The fixed per-kind command map: unknown kinds never run, and each
-- protocol keeps its own strict pre-write/uncertain vocabulary.
assert(module.verb("opencode") == "_agent_notice"
  and module.verb("codex") == "_codex_notice" and module.verb("claude") == "_claude_notice"
  and module.verb("ruby") == nil, "the verb map is closed and fixed")
local function kind_case(kind, payload)
  local spec
  local outcome = admit(request, { json = codec, kind = kind,
    runner = function(value) spec = value
      return { code = 0, stdout = codec.encode(payload) } end })
  return outcome, spec
end
local codex_accepted, codex_spec = kind_case("codex", { outcome = "accepted_queue" })
assert(codex_accepted.outcome == "accepted" and codex_spec.argv[2] == "_codex_notice"
  and #codex_spec.argv == 2, "Codex uses only _codex_notice")
local claude_spec
local claude_accepted = admit(request, { json = codec, kind = "claude",
  runner = function(value) claude_spec = value
    return { code = 0, stdout = codec.encode({ outcome = "accepted_queue" }) } end })
assert(claude_accepted.outcome == "uncertain" and claude_spec.argv[2] == "_claude_notice",
  "Claude uses _claude_notice and never invents accepted_queue")
local startup = kind_case("codex", { outcome = "definitely_not_written",
  reason = "binding_missing" })
assert(startup.outcome == "not_written" and startup.startup_pending == true,
  "an absent unpublished manifest is a startup-pending pre-write")
for _, reason in ipairs({ "invalid_binding", "socket_dead", "endpoint_unverified",
  "peer_mismatch", "version_mismatch", "thread_not_loaded" }) do
  local dead = kind_case("codex", { outcome = "definitely_not_written", reason = reason })
  assert(dead.outcome == "dead_binding", "Codex dead: " .. reason)
end
local unknown_reason = kind_case("codex", { outcome = "definitely_not_written",
  reason = "made_up" })
assert(unknown_reason.outcome == "uncertain", "unknown Codex refusals are uncertain")
local emitted = kind_case("claude", { outcome = "uncertain",
  reason = "channel_emitted_unconfirmed" })
assert(emitted.outcome == "uncertain" and emitted.reason == "channel_emitted_unconfirmed",
  "possible Claude emission is final and uncertain")
local claude_dead = kind_case("claude", { outcome = "definitely_not_written",
  reason = "bridge_gone" })
assert(claude_dead.outcome == "dead_binding", "a gone Claude channel is a dead binding")
local ran = false
local bad_kind = admit(request, { json = codec, kind = "ruby",
  runner = function() ran = true end })
assert(bad_kind.outcome == "dead_binding" and bad_kind.reason == "invalid_kind" and not ran,
  "an unknown kind fails closed before any command")

-- The raw dispatch/runner entrypoint is deliberately not exported, the
-- one-shot factory is consumed, and a forged shape attempt cannot run a runner.
assert(module.dispatch == nil, "no raw dispatch export")
assert(module.install == nil, "the one-shot factory door is closed")
local forged_calls = 0
local forged = module.admit(request, { json = codec,
  runner = function() forged_calls = forged_calls + 1 end },
  { intent = "mail_notice", generation = notice_generation, record = {} })
assert(forged_calls == 0 and forged.outcome == "not_written"
  and forged.reason == "policy_attempt_required",
  "forged shape fields and a caller runner never dispatch")
local channel = assert(transport("opencode"))
local untracked_calls = 0
remuda.process = { run = function() untracked_calls = untracked_calls + 1 end }
local untracked = channel.send({ request = request, kind = "opencode", used = false },
  function() return true end)
assert(untracked_calls == 0 and untracked.outcome == "not_written"
  and untracked.reason == "policy_attempt_required",
  "an untracked attempt table never runs the helper")
local reused_claim = assert(channel.prepare(fields_of(request)))
remuda.process = { run = function()
  return { code = 0, stdout = codec.encode({ outcome = "accepted_queue" }), stderr = "" }
end }
assert(channel.send(reused_claim, function() return true end).outcome == "accepted",
  "a tracked attempt dispatches once")
local reused_calls = 0
remuda.process = { run = function() reused_calls = reused_calls + 1 end }
local reused = channel.send(reused_claim, function() return true end)
assert(reused_calls == 0 and reused.outcome == "not_written"
  and reused.reason == "policy_attempt_required", "an attempt is one-use")

print("ok - native request is frozen, validated and mapped without guessing")
