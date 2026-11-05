-- Run from the repository root: luajit tests/butler_native_adopt.lua
-- Owner-declared Codex adoption glue and CLI: identity fence, no partial
-- binding, no endpoint persistence and honest typed reports. No daemon.
remuda = {}
local adopt_module = dofile("packages/butler/native_adopt.lua")
local cli = dofile("packages/butler/native_cli.lua")
local UUID = "01234567-89ab-cdef-0123-456789abcdef"
local SOCKET = "unix:///private/tmp/codex-daemon-501/abcd.sock"

local function fixture(result, overrides)
  overrides = overrides or {}
  local bus = { agents = { m1 = { kind = "codex", id = "id-m1" } } }
  local rows = { { name = "m1", alive = true, id = "ses_row", instance_id = "instance-1" } }
  local saved, calls = 0, {}
  local self = {
    bus = bus,
    list = function() return overrides.rows or rows end,
    launch = { prepare = function(name)
      calls.prepare = name
      return "/data/remuda/butler/bindings/m1/ab/manifest.json", string.rep("ab", 16)
    end, config_path = function() return "/cfg/native.json" end },
    config = {
      load = function() return {} end,
      kind = function(_, kind)
        if overrides.config_off then return { enabled = false, reason = "disabled" } end
        return { enabled = true, reason = "enabled" }
      end,
    },
    codex = { adopt = function(fields, options)
      calls.fields, calls.options = fields, options
      if overrides.during then overrides.during() end
      return result
    end },
    opencode = { adopt = function(fields, options)
      calls.fields, calls.options = fields, options
      if overrides.during then overrides.during() end
      return overrides.opencode_result or result
    end },
    json = {}, runner = function() end, remuda = "remuda",
    roster_save = function() saved = saved + 1 end,
    trace = function() end,
  }
  return self, bus, calls, function() return saved end
end

-- 1. Success binds exactly the fenced identity; the endpoint/thread stay on
-- the request only and never reach the agent or the roster.
local self, bus, calls, saved = fixture({ outcome = "adopted", generation = string.rep("cd", 32) })
local result, why = adopt_module.codex(self, "m1", SOCKET, UUID)
assert(result and result.generation == string.rep("cd", 32), "adoption returns the generation")
assert(why == nil, "no failure reason")
assert(calls.fields.binding == "/data/remuda/butler/bindings/m1/ab/manifest.json"
  and calls.fields.session == "ses_row" and calls.fields.socket == SOCKET
  and calls.fields.thread == UUID and calls.fields.nonce == string.rep("ab", 16),
  "the request carries the live row id and the owner declaration once")
local native = bus.agents.m1.native
assert(native.mode == "native" and native.kind == "codex"
  and native.row_id == "ses_row" and native.instance == "instance-1"
  and native.generation == string.rep("cd", 32) and native.awaiting_publication == false,
  "the binding keeps identity and the published generation")
for key, value in pairs(native) do
  assert(key ~= "socket" and key ~= "thread" and key ~= "auth", "never persist " .. key)
  assert(tostring(value):find("private/tmp", 1, true) == nil, "no endpoint in " .. key)
end
assert(saved() == 1, "the roster is saved once")

-- 2. A session replaced during the adopt yield never keeps the new binding.
local replaced_bus
local replaced = fixture({ outcome = "adopted", generation = string.rep("cd", 32) }, {
  during = function() end })
replaced_bus = replaced
replaced_bus.list = (function()
  local calls = 0
  return function()
    calls = calls + 1
    if calls == 1 then
      return { { name = "m1", alive = true, id = "ses_row", instance_id = "instance-1" } }
    end
    return { { name = "m1", alive = true, id = "ses_row", instance_id = "instance-2" } }
  end
end)()
local self2, bus2 = fixture({ outcome = "adopted", generation = string.rep("cd", 32) })
self2.list = replaced_bus.list
local result2, why2 = adopt_module.codex(self2, "m1", SOCKET, UUID)
assert(result2 == nil and why2 == "session_replaced_during_adopt",
  "a replaced row is refused after the yield")
assert(bus2.agents.m1.native == nil, "no half-binding is attached")

-- 2b. A reload or concurrent adoption during the helper yield is never
-- overwritten, even when the live row itself is unchanged.
local replaced_agent
replaced_agent = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { during = function()
      local fresh = { kind = "codex", id = "id-fresh" }
      replaced_agent.bus.agents.m1 = fresh
    end })
local _, replaced_agent_why = adopt_module.codex(replaced_agent, "m1", SOCKET, UUID)
assert(replaced_agent_why == "session_replaced_during_adopt",
  "a replaced agent object is refused after the yield")
assert(replaced_agent.bus.agents.m1.native == nil, "the new agent gets no stale binding")

local concurrent
concurrent = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { during = function()
      concurrent.bus.agents.m1.native = { mode = "native", kind = "codex",
        path = "/already/bound", row_id = "ses_row", instance = "instance-1" }
    end })
local _, concurrent_why = adopt_module.codex(concurrent, "m1", SOCKET, UUID)
assert(concurrent_why == "session_replaced_during_adopt",
  "a concurrent adoption wins")
assert(concurrent.bus.agents.m1.native.path == "/already/bound",
  "the newer decision is not overwritten")

local module_live = remuda.butler.native_adopt
local reloaded
reloaded = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { during = function() remuda.butler.native_adopt = {} end })
local _, reloaded_why = adopt_module.codex(reloaded, "m1", SOCKET, UUID)
remuda.butler.native_adopt = module_live
assert(reloaded_why == "session_replaced_during_adopt",
  "a reloaded module never installs through the old image")
assert(reloaded.bus.agents.m1.native == nil, "the stale module attaches no binding")

-- 3. Opt-in, identity and availability failures create no binding.
local off, off_bus = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { config_off = true })
assert(adopt_module.codex(off, "m1", SOCKET, UUID) == nil, "opt-in is required")
assert(off_bus.agents.m1.native == nil, "unopted session stays unbound")
local unavailable, unavailable_bus = fixture({ outcome = "unavailable",
  reason = "thread_not_loaded" })
local unavailable_result, unavailable_why = adopt_module.codex(unavailable, "m1", SOCKET, UUID)
assert(unavailable_result == nil and unavailable_why == "unavailable: thread_not_loaded",
  "the typed unavailable reason is reported")
assert(unavailable_bus.agents.m1.native == nil, "unavailable publishes no binding")
local unknown, unknown_bus = fixture({ outcome = "uncertain", reason = "timeout" })
local unknown_result, unknown_why = adopt_module.codex(unknown, "m1", SOCKET, UUID)
assert(unknown_result == nil and unknown_why == "uncertain: timeout", "unknown is final")
assert(unknown_bus.agents.m1.native == nil, "uncertain attaches no binding")

-- 4. A live PTY session of another kind is refused before any helper call.
local wrong, wrong_bus = fixture({ outcome = "adopted", generation = string.rep("cd", 32) })
wrong_bus.agents.m1.kind = "opencode"
local wrong_result, wrong_why = adopt_module.codex(wrong, "m1", SOCKET, UUID)
assert(wrong_result == nil and wrong_why == "not_a_codex_session", "only Codex sessions adopt")
assert(wrong_bus.agents.m1.native == nil, "a wrong kind never binds")

-- 5. CLI parsing is exact and the report never repeats the socket or thread.
local parsed, parse_why = cli.parse({ "adopt-codex", "m1", "--socket", SOCKET,
  "--thread", UUID })
assert(parsed and parsed.session == "m1" and parsed.socket == SOCKET
  and parsed.thread == UUID, "the documented argv parses")
assert(cli.parse({ "adopt-codex", "m1", "--socket", SOCKET }) == nil, "a missing UUID is refused")
assert(cli.parse({ "adopt-codex", "m1", "--socket", SOCKET, "--thread", UUID,
  "extra" }) == nil, "extra words are refused")
assert(cli.parse({ "adopt-codex", "m1", "--socket", SOCKET, "--socket", SOCKET,
  "--thread", UUID }) == nil, "a repeated flag is refused")
assert(cli.parse({ "adopt-codex", "m1", "--endpoint", SOCKET, "--thread", UUID }) == nil,
  "unknown options are refused")

assert(cli.run({ "--help" }) == cli.USAGE, "help is printed as help")
assert(cli.run({ "adopt-codex", "--help" }) == cli.USAGE, "verb help is printed as help")
local function report(value, error_message)
  return cli.run({ "adopt-codex", "m1", "--socket", SOCKET, "--thread", UUID },
    { adopt_codex = function() return value, error_message end })
end
local text = report({ generation = string.rep("cd", 32) })
assert(text and text:find("natively bound", 1, true) ~= nil, "success is explicit")
assert(text:find("private/tmp", 1, true) == nil and text:find(UUID, 1, true) == nil,
  "the report repeats neither the socket nor the thread")
local unavailable_text, unavailable_error = report(nil, "unavailable: version_mismatch")
assert(unavailable_text == nil and unavailable_error:find("No binding was published", 1, true),
  "unavailable is reported without a retry")
local uncertain_text, uncertain_error = report(nil, "uncertain: timeout")
assert(uncertain_text == nil and uncertain_error:find("Do not retry automatically", 1, true),
  "uncertain never invites a blind retry")

-- 6. OpenCode adoption binds the canonical row id and never persists the
-- endpoint, conversation or password.
local oc, oc_bus, oc_calls = fixture({ outcome = "adopted", generation = "65f870ac8f9d2" })
oc_bus.agents.m1.kind = "opencode"
local oc_result = assert(adopt_module.opencode(oc, "m1", "http://127.0.0.1:4096",
  "ses_e543a3368ffe1Hhcoeq7zBDS4b", "s3cret"))
assert(oc_result.generation == "65f870ac8f9d2", "OpenCode returns the generation")
assert(oc_calls.fields.session == "ses_row"
  and oc_calls.fields.endpoint == "http://127.0.0.1:4096"
  and oc_calls.fields.conversation == "ses_e543a3368ffe1Hhcoeq7zBDS4b"
  and oc_calls.fields.password == "s3cret"
  and oc_calls.fields.nonce == string.rep("ab", 16),
  "the request carries the declaration once and the live row id")
local oc_native = oc_bus.agents.m1.native
assert(oc_native.mode == "native" and oc_native.kind == "opencode"
  and oc_native.row_id == "ses_row" and oc_native.session_token == "ses_row"
  and oc_native.generation == "65f870ac8f9d2" and oc_native.awaiting_publication == false,
  "the binding keeps the identity and generation")
for key, value in pairs(oc_native) do
  assert(key ~= "endpoint" and key ~= "conversation" and key ~= "auth"
    and key ~= "password", "never persist " .. key)
  assert(not tostring(value):find("s3cret", 1, true), "no credential in " .. key)
  assert(not tostring(value):find("127.0.0.1", 1, true), "no endpoint in " .. key)
end

-- 7. OpenCode refusals: wrong kind, opt-in, a replaced row and unavailable.
local oc_wrong, oc_wrong_bus = fixture({ outcome = "adopted", generation = "10" })
oc_wrong_bus.agents.m1.kind = "codex"
assert(adopt_module.opencode(oc_wrong, "m1", "http://127.0.0.1:4096",
  "ses_abc", "x") == nil, "only OpenCode sessions adopt")
local oc_off, oc_off_bus = fixture({ outcome = "adopted", generation = "10" },
  { config_off = true })
oc_off_bus.agents.m1.kind = "opencode"
local _, oc_off_why = adopt_module.opencode(oc_off, "m1", "http://127.0.0.1:4096",
  "ses_abc", "x")
assert(oc_off_why and oc_off_why:find("opencode_not_opted_in", 1, true),
  "OpenCode adoption is opt-in")
assert(oc_off_bus.agents.m1.native == nil, "unopted OpenCode stays unbound")
local oc_replaced = fixture({ outcome = "adopted", generation = "10" })
oc_replaced.bus.agents.m1.kind = "opencode"
local replaced_calls = 0
oc_replaced.list = function()
  replaced_calls = replaced_calls + 1
  if replaced_calls == 1 then
    return { { name = "m1", alive = true, id = "ses_row", instance_id = "instance-1" } }
  end
  return { { name = "m1", alive = true, id = "ses_row", instance_id = "instance-2" } }
end
local _, oc_replaced_why = adopt_module.opencode(oc_replaced, "m1",
  "http://127.0.0.1:4096", "ses_abc", "x")
assert(oc_replaced_why == "session_replaced_during_adopt",
  "a replaced OpenCode row is refused")
assert(oc_replaced.bus.agents.m1.native == nil, "no half-binding for OpenCode")
local oc_unavailable = fixture({ outcome = "unavailable", reason = "auth" })
oc_unavailable.bus.agents.m1.kind = "opencode"
local _, oc_unavailable_why = adopt_module.opencode(oc_unavailable, "m1",
  "http://127.0.0.1:4096", "ses_abc", "x")
assert(oc_unavailable_why == "unavailable: auth", "the typed refusal is reported")

-- 7b. The same post-yield fences apply to OpenCode.
local oc_replaced_agent = fixture({ outcome = "adopted", generation = "10" })
oc_replaced_agent.bus.agents.m1.kind = "opencode"
oc_replaced_agent.opencode.adopt = function()
  oc_replaced_agent.bus.agents.m1 = { kind = "opencode", id = "id-fresh" }
  return { outcome = "adopted", generation = "10" }
end
local _, oc_replaced_agent_why = adopt_module.opencode(oc_replaced_agent, "m1",
  "http://127.0.0.1:4096", "ses_abc", "x")
assert(oc_replaced_agent_why == "session_replaced_during_adopt",
  "a replaced OpenCode agent object is refused")
assert(oc_replaced_agent.bus.agents.m1.native == nil, "no stale OpenCode binding")

local oc_concurrent = fixture({ outcome = "adopted", generation = "10" })
oc_concurrent.bus.agents.m1.kind = "opencode"
oc_concurrent.opencode.adopt = function()
  oc_concurrent.bus.agents.m1.native = { mode = "native", kind = "opencode",
    path = "/already/bound", row_id = "ses_row", instance = "instance-1" }
  return { outcome = "adopted", generation = "10" }
end
local _, oc_concurrent_why = adopt_module.opencode(oc_concurrent, "m1",
  "http://127.0.0.1:4096", "ses_abc", "x")
assert(oc_concurrent_why == "session_replaced_during_adopt",
  "a concurrent OpenCode adoption wins")
assert(oc_concurrent.bus.agents.m1.native.path == "/already/bound",
  "the newer OpenCode decision is not overwritten")

-- 8. OpenCode CLI: endpoint and conversation on argv, password only on stdin.
local oc_parsed = assert(cli.parse({ "adopt-opencode", "m1", "--endpoint",
  "http://127.0.0.1:4096", "--conversation", "ses_abc", "--password-stdin" }))
assert(oc_parsed.session == "m1" and oc_parsed.endpoint == "http://127.0.0.1:4096"
  and oc_parsed.conversation == "ses_abc", "the documented argv parses")
assert(cli.parse({ "adopt-opencode", "m1", "--endpoint", "http://127.0.0.1:4096",
  "--conversation", "ses_abc" }) == nil, "the stdin marker is required")
assert(cli.parse({ "adopt-opencode", "m1", "--endpoint", "http://127.0.0.1:4096",
  "--conversation", "ses_abc", "--password-stdin", "--password", "x" }) == nil,
  "a password flag is never accepted")
assert(cli.parse({ "adopt-opencode", "m1", "--endpoint", "http://127.0.0.1:4096",
  "--conversation", "ses_abc", "--password-stdin", "extra" }) == nil,
  "extra words are refused")
local function oc_report(result, error_message)
  return cli.run({ "adopt-opencode", "m1", "--endpoint", "http://127.0.0.1:4096",
    "--conversation", "ses_abc", "--password-stdin" },
    { adopt_opencode = function(name, endpoint, conversation, password)
        assert(password == "s3cret", "the password is passed once")
        return result, error_message
      end }, { password = "s3cret\n" })
end
local oc_text = oc_report({ generation = "65f870ac8f9d2" })
assert(oc_text and oc_text:find("OpenCode session m1 is natively bound", 1, true),
  "OpenCode success is explicit")
assert(not oc_text:find("s3cret", 1, true), "the report never repeats the password")
local oc_unavailable_text, oc_unavailable_error = oc_report(nil, "unavailable: auth")
assert(oc_unavailable_text == nil and oc_unavailable_error:find("No binding was published", 1, true),
  "OpenCode unavailable is reported without a retry")
local no_stdin = cli.run({ "adopt-opencode", "m1", "--endpoint",
  "http://127.0.0.1:4096", "--conversation", "ses_abc", "--password-stdin" },
  { adopt_opencode = function() error("must not be called") end }, {})
assert(no_stdin == nil, "a missing password is refused before the helper")

print("ok - Codex and OpenCode adoption are fenced, opt-in and reported without endpoints")
