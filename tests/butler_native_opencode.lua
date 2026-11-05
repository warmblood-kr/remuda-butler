-- Run from the repository root: luajit tests/butler_native_opencode.lua
-- Explicit-server OpenCode adoption: exact loopback endpoint, bounded ses_
-- conversation, strict frozen request, one helper call and typed mapping.
-- No live server and no credential in argv.
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
local module = dofile("packages/butler/native_opencode.lua")
local options = { json = codec }
local DEFAULT_ID = "ses_e543a3368ffe1Hhcoeq7zBDS4b" -- 2.2.5 default shape
local HEX_ID = "ses_0123456789abcdef0123456789abcdef"

-- 1. Only the exact documented loopback form is accepted; nothing normalized.
for _, good in ipairs({ "http://127.0.0.1:4096", "http://127.0.0.1:1",
  "http://127.0.0.1:65535" }) do
  assert(module.valid_endpoint(good), "accepted: " .. good)
end
for _, bad in ipairs({ "http://127.0.0.1:0", "http://127.0.0.1:65536",
  "http://127.0.0.1:4096/", "http://127.0.0.1:4096/api", "https://127.0.0.1:4096",
  "http://localhost:4096", "http://[::1]:4096", "http://127.0.0.2:4096",
  "127.0.0.1:4096", "http://127.0.0.1:4096?x=1", "http://127.0.0.1:4096#f",
  "", nil }) do
  assert(not module.valid_endpoint(bad), "refused: " .. tostring(bad))
end

-- 2. The conversation subset covers the real default id and synthetic hex.
assert(module.valid_conversation(DEFAULT_ID), "default 30-char mixed-case id")
assert(module.valid_conversation(HEX_ID), "synthetic ses_+32hex id")
assert(not module.valid_conversation("ses_"), "an empty suffix is refused")
assert(not module.valid_conversation("ses_abc/def"), "slash refused")
assert(not module.valid_conversation("ses_abc def"), "space refused")
assert(not module.valid_conversation("abc"), "the ses_ prefix is required")
assert(not module.valid_conversation("ses_" .. string.rep("a", 125)), "over 128 refused")

-- 3. The frozen request has exactly the documented fields and shape.
local fields = { binding = "/data/remuda/butler/bindings/lead/ab/manifest.json",
  nonce = string.rep("ab", 16), session = "ses_0123456789abcdef",
  endpoint = "http://127.0.0.1:4096", conversation = DEFAULT_ID,
  password = "s3cret" }
local request = assert(module.build(fields))
local keys = {}
for key in pairs(request) do keys[#keys + 1] = key end
table.sort(keys)
assert(table.concat(keys, ",") == "auth,binding,conversation,endpoint,nonce,session,version",
  "no extra request field")
assert(request.version == 1 and request.auth.scheme == "basic"
  and request.auth.user == "opencode" and request.auth.password == "s3cret",
  "auth is exactly basic/opencode/password")
assert(request.endpoint == fields.endpoint and request.conversation == DEFAULT_ID,
  "the owner declaration is used exactly")
assert(module.build({ binding = fields.binding, nonce = fields.nonce,
  session = fields.session, endpoint = fields.endpoint, conversation = "ses_",
  password = "x" }) == nil, "a bad conversation never builds")
assert(module.build({ binding = "relative/manifest.json", nonce = fields.nonce,
  session = fields.session, endpoint = fields.endpoint, conversation = DEFAULT_ID,
  password = "x" }) == nil, "a relative binding never builds")
assert(module.build({ binding = fields.binding, nonce = "bad nonce",
  session = fields.session, endpoint = fields.endpoint, conversation = DEFAULT_ID,
  password = "x" }) == nil, "a malformed nonce never builds")
assert(module.build({ binding = fields.binding, nonce = fields.nonce,
  session = fields.session, endpoint = fields.endpoint, conversation = DEFAULT_ID,
  password = "" }) == nil, "an empty password never builds")

-- 4. Typed mapping: adopted keeps the short start-time generation; anything
-- else is uncertain and never a binding.
local adopted = module.classify(codec.encode({ outcome = "adopted",
  generation = "65f870ac8f9d2" }), options)
assert(adopted.outcome == "adopted" and adopted.generation == "65f870ac8f9d2",
  "the helper generation is retained")
assert(module.classify(codec.encode({ outcome = "adopted", generation = "" }), options).outcome
  == "uncertain", "an empty generation is refused")
assert(module.classify(codec.encode({ outcome = "adopted", generation = "xyz" }), options).outcome
  == "uncertain", "a non-hex generation is refused")
assert(module.classify(codec.encode({ outcome = "adopted",
  generation = "0123456789abcdef0" }), options).outcome == "uncertain",
  "a 17-char generation is refused")
assert(module.classify(codec.encode({ outcome = "adopted", generation = "10", extra = 1 }),
  options).outcome == "uncertain", "unknown adopted fields are refused")
local unavailable = module.classify(codec.encode({ outcome = "unavailable", reason = "auth" }),
  options)
assert(unavailable.outcome == "unavailable" and unavailable.reason == "auth",
  "a typed refusal is mapped")
assert(module.classify(codec.encode({ outcome = "unavailable", reason = "" }), options).outcome
  == "uncertain", "an empty reason is not a refusal")
assert(module.classify(codec.encode({ outcome = "definitely_not_written", reason = "auth" }),
  options).outcome == "uncertain", "adoption has no definitely_not_written outcome")
assert(module.classify("not json", options).outcome == "uncertain",
  "unparseable output is uncertain")

-- 5. One helper call, the request on stdin, and no credential in argv.
local seen
local function runner(call)
  seen = call
  return { code = 0, stdout = codec.encode({ outcome = "adopted",
    generation = "65f870ac8f9d2" }) }
end
local result = module.adopt(fields, { json = codec, runner = runner, remuda = "remuda" })
assert(result.outcome == "adopted", "the helper answer is returned")
assert(seen.argv[1] == "remuda" and seen.argv[2] == "_opencode_adopt"
  and #seen.argv == 2, "only the fixed helper verb runs")
assert(seen.stdin == literal(module.build(fields)) or seen.stdin:find('"password"', 1, true),
  "the frozen request is on stdin")
for _, arg in ipairs(seen.argv) do
  assert(arg ~= "s3cret" and not arg:find("s3cret", 1, true), "no password in argv")
end
assert(seen.timeout == 15, "the adopt call is bounded")

-- 6. Timeouts, nonzero exits and helper failures never become a binding.
local function with_runner(r)
  return module.adopt(fields, { json = codec, runner = r, remuda = "remuda" })
end
assert(with_runner(function() return { timed_out = true } end).outcome == "uncertain",
  "a timeout is uncertain")
assert(with_runner(function() return { code = 2, stdout = "" } end).outcome == "uncertain",
  "a nonzero exit with no refusal is uncertain")
assert(with_runner(function() return { code = 2,
  stdout = codec.encode({ outcome = "unavailable", reason = "auth" }) } end).outcome
  == "unavailable",
  "a typed refusal stands even on a nonzero exit")
assert(with_runner(function() error("boom") end).outcome == "uncertain",
  "a runner failure is uncertain")

print("ok - OpenCode adoption is exact, credentialled on stdin and strictly mapped")
