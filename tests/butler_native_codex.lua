-- Run from the repository root: luajit tests/butler_native_codex.lua
-- Owner-declared Codex adoption: local-socket normalization, canonical UUID,
-- frozen request, one helper call and strict typed mapping. No live server.
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

remuda = {}
local module = dofile("packages/butler/native_codex.lua")
local options = { json = codec }
local UUID = "01234567-89ab-cdef-0123-456789abcdef"

-- 1. Only the documented local scheme is normalized, and only to an absolute
-- path. Remote/query/fragment forms are refused, never guessed.
assert(module.normalize_socket("/private/tmp/codex-daemon-501/abcd.sock")
  == "/private/tmp/codex-daemon-501/abcd.sock", "an absolute path passes through")
assert(module.normalize_socket("unix:///private/tmp/codex-daemon-501/abcd.sock")
  == "/private/tmp/codex-daemon-501/abcd.sock", "unix:// keeps the absolute path")
for _, bad in ipairs({ "unix://host/socket", "tcp://127.0.0.1:1", "unix:/tmp/x",
  "relative.sock", "/tmp/x?s=1", "/tmp/x#frag", "/tmp/\nfoo", "", nil }) do
  local path, why = module.normalize_socket(bad)
  assert(path == nil and why, "refused: " .. tostring(bad))
end

-- 2. The owner's UUID is used exactly; no case folding or truncation.
assert(module.valid_thread(UUID), "canonical lowercase UUID accepted")
assert(not module.valid_thread(UUID:upper()), "uppercase is not silently normalized")
assert(not module.valid_thread(UUID:sub(1, 8)), "truncated UUID refused")
assert(not module.valid_thread(UUID:gsub("-", "")), "unhyphenated UUID refused")

-- 3. The frozen request has exactly the six documented fields.
local fields = { binding = "/data/remuda/butler/bindings/lead/ab/manifest.json",
  nonce = string.rep("ab", 16), session = "ses_0123456789abcdef",
  socket = "unix:///private/tmp/codex.sock", thread = UUID }
local request = assert(module.build(fields))
local keys = {}
for key in pairs(request) do keys[#keys + 1] = key end
table.sort(keys)
assert(table.concat(keys, ",") == "binding,nonce,session,socket,thread,version",
  "no extra request field")
assert(request.version == 1 and request.thread == UUID
  and request.socket == "/private/tmp/codex.sock", "normalized endpoint in the request")
fields.socket = "/tmp/other"
assert(request.socket == "/private/tmp/codex.sock", "the request owns its socket string")
fields.socket = "unix:///private/tmp/codex.sock"

local valid, why = module.build({ binding = fields.binding, nonce = fields.nonce,
  session = fields.session, socket = "/tmp/x", thread = UUID:upper() })
assert(valid == nil and why == "invalid_thread", "a bad UUID is refused before a call")

-- 4. Adopt maps only the two strict typed answers. Any extra field, missing
-- generation or unknown outcome is uncertain and must not create a binding.
local adopted = module.classify(codec.encode({ outcome = "adopted",
  generation = string.rep("01", 32) }), options)
assert(adopted.outcome == "adopted" and adopted.generation == string.rep("01", 32),
  "adopted requires a 64-hex generation")
local unavailable = module.classify(codec.encode({ outcome = "unavailable",
  reason = "version_mismatch" }), options)
assert(unavailable.outcome == "unavailable" and unavailable.reason == "version_mismatch",
  "unavailable keeps the typed reason")
for _, text in ipairs({
  codec.encode({ outcome = "adopted" }),
  codec.encode({ outcome = "adopted", generation = string.rep("01", 32), extra = true }),
  codec.encode({ outcome = "adopted", generation = string.rep("zz", 32) }),
  codec.encode({ outcome = "unavailable" }),
  codec.encode({ outcome = "unavailable", reason = "" }),
  codec.encode({ outcome = "accepted_queue" }),
  "not json", "{}" }) do
  local result = module.classify(text, options)
  assert(result.outcome == "uncertain", "not a binding: " .. tostring(text))
end

-- 5. One helper call with the fixed verb; no argv fields, one stdin request.
local calls = {}
local function runner(result)
  return function(spec)
    calls[#calls + 1] = spec
    return result
  end
end
local ok = module.adopt(fields, { json = codec, runner = runner({
  code = 0, stdout = codec.encode({ outcome = "adopted", generation = string.rep("cd", 32) }) }) })
assert(ok.outcome == "adopted", "a typed adopted answer is returned")
assert(#calls == 1 and calls[1].argv[1] == "remuda" and calls[1].argv[2] == "_codex_adopt"
  and #calls[1].argv == 2, "exactly the fixed adopt verb")
assert(type(calls[1].stdin) == "string" and calls[1].stdin:find(UUID, 1, true) ~= nil,
  "the owner UUID travels on stdin")
assert(calls[1].stdin:find("/private/tmp/codex.sock", 1, true) ~= nil,
  "the declared socket travels on stdin")
assert(not calls[1].stdin:find("REMUDA", 1, true), "no environment material in the request")

-- 6. A timeout, untyped nonzero and missing runner are uncertain, never a
-- silent success and never a retry invented here.
local timed_out = module.adopt(fields, { json = codec,
  runner = runner({ timed_out = true }) })
assert(timed_out.outcome == "uncertain" and timed_out.reason == "timeout", "timeout is uncertain")
local nonzero = module.adopt(fields, { json = codec,
  runner = runner({ code = 2, stdout = "boom" }) })
assert(nonzero.outcome == "uncertain" and nonzero.reason == "helper_exit_2",
  "an untyped nonzero is uncertain")
local typed_refusal = module.adopt(fields, { json = codec,
  runner = runner({ code = 1, stdout = codec.encode({ outcome = "unavailable",
    reason = "thread_not_loaded" }) }) })
assert(typed_refusal.outcome == "unavailable", "a typed refusal survives a nonzero exit")
local no_runner = module.adopt(fields, { json = codec, runner = false })
assert(no_runner.outcome == "uncertain" and no_runner.reason == "runner_unavailable",
  "a missing runner is uncertain")

print("ok - Codex owner adoption is local, strict and never guessed")
