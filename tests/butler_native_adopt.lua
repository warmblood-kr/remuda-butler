-- Run from the repository root: luajit tests/butler_native_adopt.lua
-- Owner-declared Codex adoption glue and CLI: identity fence, no partial
-- binding, no endpoint persistence and honest typed reports. No daemon.
remuda = {}
local adopt_module = dofile("packages/butler/native_adopt.lua")
local cli = dofile("packages/butler/native_cli.lua")
local UUID = "01234567-89ab-cdef-0123-456789abcdef"
local SOCKET = "unix:///private/tmp/codex-daemon-501/abcd.sock"

-- The shipped path installs the facade, which publishes exactly this instance
-- under both ownership aliases. A bare module-table call is not the
-- composition and is refused by the identity fence.
local function installed(self)
  return adopt_module.install(self)
end

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

-- 0. A bare module-table call is not the installed composition: the helper is
-- never reached while the public table still points at the module itself.
local bare = fixture({ outcome = "adopted", generation = string.rep("cd", 32) })
local bare_result, bare_why = adopt_module.codex(bare, "m1", SOCKET, UUID)
assert(bare_result == nil and bare_why == "session_replaced_during_adopt",
  "a bare module call is refused")
assert(bare.bus.agents.m1.native == nil, "a bare module call publishes no binding")

-- 1. Success binds exactly the fenced identity; the endpoint/thread stay on
-- the request only and never reach the agent or the roster.
local self, bus, calls, saved = fixture({ outcome = "adopted", generation = string.rep("cd", 32) })
local result, why = installed(self).adopt_codex("m1", SOCKET, UUID)
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
local result2, why2 = installed(self2).adopt_codex("m1", SOCKET, UUID)
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
local _, replaced_agent_why = installed(replaced_agent).adopt_codex("m1", SOCKET, UUID)
assert(replaced_agent_why == "session_replaced_during_adopt",
  "a replaced agent object is refused after the yield")
assert(replaced_agent.bus.agents.m1.native == nil, "the new agent gets no stale binding")

local concurrent
concurrent = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { during = function()
      concurrent.bus.agents.m1.native = { mode = "native", kind = "codex",
        path = "/already/bound", row_id = "ses_row", instance = "instance-1" }
    end })
local _, concurrent_why = installed(concurrent).adopt_codex("m1", SOCKET, UUID)
assert(concurrent_why == "session_replaced_during_adopt",
  "a concurrent adoption wins")
assert(concurrent.bus.agents.m1.native.path == "/already/bound",
  "the newer decision is not overwritten")

local reloaded = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { during = function() remuda.butler.native_adopt = {} end })
local reloaded_facade = installed(reloaded)
local module_live = remuda.butler.native_adopt
local _, reloaded_why = reloaded_facade.adopt_codex("m1", SOCKET, UUID)
remuda.butler.native_adopt = module_live
assert(reloaded_why == "session_replaced_during_adopt",
  "a reloaded module never installs through the old image")
assert(reloaded.bus.agents.m1.native == nil, "the stale module attaches no binding")

-- 2b2. Replacing only the private ownership alias is refused the same way.
local private_alias = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { during = function() remuda._butler_native_adopt = {} end })
local private_facade = installed(private_alias)
local private_live = remuda._butler_native_adopt
local _, private_alias_why = private_facade.adopt_codex("m1", SOCKET, UUID)
remuda._butler_native_adopt = private_live
assert(private_alias_why == "session_replaced_during_adopt",
  "a replaced private alias is refused")
assert(private_alias.bus.agents.m1.native == nil, "no binding under a replaced alias")

-- 2b3. A reinstall during the helper publishes a new instance; the old
-- instance must not install through it.
local reinstalled = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { during = function()
      installed(fixture({ outcome = "adopted", generation = "10" }))
    end })
local reinstalled_facade = installed(reinstalled)
local _, reinstalled_why = reinstalled_facade.adopt_codex("m1", SOCKET, UUID)
assert(reinstalled_why == "session_replaced_during_adopt",
  "a reinstall during the helper is refused")
assert(reinstalled.bus.agents.m1.native == nil, "the old instance attaches no binding")

-- 2c. A replacement during the FIRST listing never reaches the helper, and a
-- new disabled decision made while the helper runs is never overwritten.
local first_list, _, first_list_calls = fixture({ outcome = "adopted",
  generation = string.rep("cd", 32) })
first_list.list = function()
  first_list.bus.agents.m1 = { kind = "codex", id = "id-fresh" }
  return { { name = "m1", alive = true, id = "ses_row", instance_id = "instance-1" } }
end
local _, first_list_why = installed(first_list).adopt_codex("m1", SOCKET, UUID)
assert(first_list_why == "session_replaced_during_adopt",
  "a replacement during the first listing is refused")
assert(first_list_calls.fields == nil, "no helper call for a replaced agent")

local new_disabled
new_disabled = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { during = function()
      new_disabled.bus.agents.m1.native = { mode = "disabled", reason = "new_decision" }
    end })
local _, new_disabled_why = installed(new_disabled).adopt_codex("m1", SOCKET, UUID)
assert(new_disabled_why == "session_replaced_during_adopt",
  "a new disabled decision wins over an in-flight adoption")
assert(new_disabled.bus.agents.m1.native.mode == "disabled"
  and new_disabled.bus.agents.m1.native.reason == "new_decision",
  "the new decision is not overwritten")

-- 3. Opt-in, identity and availability failures create no binding.
local off, off_bus = fixture({ outcome = "adopted", generation = string.rep("cd", 32) },
  { config_off = true })
assert(installed(off).adopt_codex("m1", SOCKET, UUID) == nil, "opt-in is required")
assert(off_bus.agents.m1.native == nil, "unopted session stays unbound")
local unavailable, unavailable_bus = fixture({ outcome = "unavailable",
  reason = "thread_not_loaded" })
local unavailable_result, unavailable_why = installed(unavailable).adopt_codex("m1", SOCKET, UUID)
assert(unavailable_result == nil and unavailable_why == "unavailable: thread_not_loaded",
  "the typed unavailable reason is reported")
assert(unavailable_bus.agents.m1.native == nil, "unavailable publishes no binding")
local unknown, unknown_bus = fixture({ outcome = "uncertain", reason = "timeout" })
local unknown_result, unknown_why = installed(unknown).adopt_codex("m1", SOCKET, UUID)
assert(unknown_result == nil and unknown_why == "uncertain: timeout", "unknown is final")
assert(unknown_bus.agents.m1.native == nil, "uncertain attaches no binding")

-- 4. A live PTY session of another kind is refused before any helper call.
local wrong, wrong_bus = fixture({ outcome = "adopted", generation = string.rep("cd", 32) })
wrong_bus.agents.m1.kind = "opencode"
local wrong_result, wrong_why = installed(wrong).adopt_codex("m1", SOCKET, UUID)
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
local oc_result = assert(installed(oc).adopt_opencode("m1", "http://127.0.0.1:4096",
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
assert(installed(oc_wrong).adopt_opencode("m1", "http://127.0.0.1:4096",
  "ses_abc", "x") == nil, "only OpenCode sessions adopt")
local oc_off, oc_off_bus = fixture({ outcome = "adopted", generation = "10" },
  { config_off = true })
oc_off_bus.agents.m1.kind = "opencode"
local _, oc_off_why = installed(oc_off).adopt_opencode("m1", "http://127.0.0.1:4096",
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
local _, oc_replaced_why = installed(oc_replaced).adopt_opencode("m1",
  "http://127.0.0.1:4096", "ses_abc", "x")
assert(oc_replaced_why == "session_replaced_during_adopt",
  "a replaced OpenCode row is refused")
assert(oc_replaced.bus.agents.m1.native == nil, "no half-binding for OpenCode")
local oc_unavailable = fixture({ outcome = "unavailable", reason = "auth" })
oc_unavailable.bus.agents.m1.kind = "opencode"
local _, oc_unavailable_why = installed(oc_unavailable).adopt_opencode("m1",
  "http://127.0.0.1:4096", "ses_abc", "x")
assert(oc_unavailable_why == "unavailable: auth", "the typed refusal is reported")

-- 7b. The same post-yield fences apply to OpenCode.
local oc_replaced_agent = fixture({ outcome = "adopted", generation = "10" })
oc_replaced_agent.bus.agents.m1.kind = "opencode"
oc_replaced_agent.opencode.adopt = function()
  oc_replaced_agent.bus.agents.m1 = { kind = "opencode", id = "id-fresh" }
  return { outcome = "adopted", generation = "10" }
end
local _, oc_replaced_agent_why = installed(oc_replaced_agent).adopt_opencode("m1",
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
local _, oc_concurrent_why = installed(oc_concurrent).adopt_opencode("m1",
  "http://127.0.0.1:4096", "ses_abc", "x")
assert(oc_concurrent_why == "session_replaced_during_adopt",
  "a concurrent OpenCode adoption wins")
assert(oc_concurrent.bus.agents.m1.native.path == "/already/bound",
  "the newer OpenCode decision is not overwritten")

-- 7c. An old projection (no row.id) adopts with the resolved canonical id.
local oc_nil, _, oc_nil_calls = fixture({ outcome = "adopted", generation = "10" })
oc_nil.bus.agents.m1.kind = "opencode"
oc_nil.list = function()
  return { { name = "m1", alive = true, instance_id = "instance-1" } }
end
oc_nil.identity = { resolve = function(row, options)
  assert(type(options.rows) == "table" and type(options.list) == "function",
    "adoption proves the pre fleet and re-lists after")
  return "core-id-m1"
end }
local oc_nil_result = assert(installed(oc_nil).adopt_opencode("m1",
  "http://127.0.0.1:4096", "ses_abc", "x"))
assert(oc_nil_result.generation == "10", "the nil-id adoption succeeds")
assert(oc_nil_calls.fields.session == "core-id-m1",
  "the helper receives the resolved canonical id")
assert(oc_nil.bus.agents.m1.native.row_id == "core-id-m1"
  and oc_nil.bus.agents.m1.native.session_token == "core-id-m1",
  "the binding stores the resolved id")
assert(oc_nil.bus.agents.m1.native.session_token ~= "instance-1",
  "the session is never the opaque instance id")

-- 7d. A nil-id row replaced during the helper is still refused.
local oc_nil_replaced = fixture({ outcome = "adopted", generation = "10" })
oc_nil_replaced.bus.agents.m1.kind = "opencode"
local oc_nil_calls = 0
oc_nil_replaced.list = function()
  oc_nil_calls = oc_nil_calls + 1
  if oc_nil_calls == 1 then
    return { { name = "m1", alive = true, instance_id = "instance-1" } }
  end
  return { { name = "m1", alive = true, instance_id = "instance-2" } }
end
oc_nil_replaced.identity = { resolve = function() return "core-id-m1" end }
local _, oc_nil_replaced_why = installed(oc_nil_replaced).adopt_opencode("m1",
  "http://127.0.0.1:4096", "ses_abc", "x")
assert(oc_nil_replaced_why == "session_replaced_during_adopt",
  "a nil-id replacement is refused after the helper")
assert(oc_nil_replaced.bus.agents.m1.native == nil, "no half-binding for a nil id")

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

-- 9. The exported CLI catalog publishes `native` and forwards the exact argv
-- and caller to the owner-checked command runner. A verb that commands.lua
-- registers but the catalog omits is unreachable from `remuda butler`.
remuda.schedule = function() return {} end
remuda.cancel = function() end
remuda.exec = function() end
remuda.cli = remuda.cli or { parse = function() return {} end }
setmetatable(_G, { __index = { remuda = remuda } })
local lifecycle = dofile("packages/butler/init.lua")
local native_entry
for _, row in ipairs(lifecycle.contributes["butler.command"]) do
  if row.verb == "native" then native_entry = row end
end
assert(native_entry, "the exported catalog lists native")
assert(native_entry.order > 5 and native_entry.order < 6, "native sits between doctor and quota")
local forwarded
remuda._butler_command_run = function(verb, args, caller)
  forwarded = { verb = verb, args = args, caller = caller }
  return "ran"
end
local caller = {}
local args = { "native", "adopt-codex", "m1", "--socket", SOCKET, "--thread", UUID }
assert(native_entry.run({}, args, caller) == "ran", "the exported entry runs through the command runner")
assert(forwarded.verb == "native" and forwarded.args == args and forwarded.caller == caller,
  "the exported entry forwards argv and caller unchanged")

print("ok - Codex and OpenCode adoption are fenced, opt-in and reported without endpoints")
