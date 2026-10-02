-- `remuda butler status-hook` and the Claude `.state` reader. Run from the repo root:
--   luajit tests/butler_status_hook.lua
local payloads = {
  ['{"e":"submit"}'] = { hook_event_name = "UserPromptSubmit", prompt = "SECRET" },
  ['{"e":"stop"}'] = { hook_event_name = "Stop" },
  ['{"e":"perm"}'] = { hook_event_name = "Notification", notification_type = "permission_prompt", message = "SECRET" },
  ['{"e":"elicit"}'] = { hook_event_name = "Notification", notification_type = "elicitation_dialog" },
  ['{"e":"idle"}'] = { hook_event_name = "Notification", notification_type = "idle_prompt" },
  ['{"e":"old"}'] = { hook_event_name = "Notification", message = "Claude needs your permission" },
  ['{"e":"auth"}'] = { hook_event_name = "Notification", notification_type = "auth_success" },
  ['{"e":"other"}'] = { hook_event_name = "PreToolUse" },
  ['[1]'] = { 1 },
}
local written = {}
_G.remuda = {
  json = { decode = function(text)
    if text == "{broken" then error("bad json") end
    return payloads[text]
  end },
  fs = { write_atomic = function(path, text, opts)
    written[#written + 1] = { path = path, text = text, private = opts and opts.private }
    return true
  end },
  butler = {},
}
local hook = dofile("packages/butler/status_hook.lua")
local function check(got, want, what) assert(got == want, what .. ": expected " .. tostring(want) .. ", got " .. tostring(got)) end
local function fire(stdin, path)
  written = {}
  check(hook.run({ "status-hook", path or "/tmp/x.status" }, { stdin = stdin }), "", "always returns empty output")
  return written[1]
end
local function word_of(stdin)
  local w = fire(stdin)
  return w and w.text:match("^(%a[%a ]*) %d+\n$")
end

check(word_of('{"e":"submit"}'), "working", "UserPromptSubmit")
check(word_of('{"e":"stop"}'), "idle", "Stop")
check(word_of('{"e":"perm"}'), "needs you", "permission prompt")
check(word_of('{"e":"elicit"}'), "needs you", "elicitation dialog")
check(word_of('{"e":"idle"}'), "idle", "idle prompt")
check(word_of('{"e":"old"}'), "needs you", "Notification without a type")
check(word_of('{"e":"auth"}'), nil, "auth_success ignored")
check(word_of('{"e":"other"}'), nil, "unknown event ignored")
check(word_of("{broken"), nil, "malformed JSON ignored")
check(word_of("[1]"), nil, "non-object JSON ignored")
check(word_of("nothing mapped"), nil, "undecodable input ignored")

local w = fire('{"e":"perm"}')
check(w.path, "/tmp/x.status.state", "state file beside the status file")
check(w.private, true, "state file is private")
assert(not w.text:find("SECRET"), "hook text is never written")
assert(w.text:match("^needs you %d+\n$"), "fixed word and a number only")
check(fire('{"e":"stop"}', "relative.status"), nil, "relative path refused")
check(fire('{"e":"stop"}', "/tmp/x.txt"), nil, "non-.status path refused")
check(fire('{"e":"stop"}', "/tmp/../../x/f.status"), nil, "a .. component is refused")
check(fire('{"e":"stop"}', "/tmp/./f.status"), nil, "a . component is refused")
check(fire('{"e":"stop"}', "C:\\a\\..\\f.status"), nil, "a .. component is refused with backslashes")
assert(fire('{"e":"stop"}', "/tmp/..x/.f/f.status"), "names that merely contain dots are accepted")
written = {}
hook.run({ "status-hook" }, { stdin = '{"e":"stop"}' })
check(written[1], nil, "missing path refused")
check(hook.run({ "status-hook", "/tmp/x.status" }, nil), "", "no stdin still exits clean")
remuda.fs.write_atomic = function() error("disk full") end
check(hook.run({ "status-hook", "/tmp/x.status" }, { stdin = '{"e":"stop"}' }), "", "write failure is swallowed")

-- The Claude adapter reads the `.state` file back, strictly.
local support = {}
remuda._butler_agent_builders, remuda._butler_agent_support = {}, { status_settings = function(p) return p end }
remuda._butler_telemetry_adapters = {}
remuda._butler_agent_startup = { claude = { modals = {} } }
dofile("packages/butler/agents/claudecode.lua")
local base = os.tmpname()
local function state_of(content)
  local f = assert(io.open(base .. ".state", "w")); f:write(content); f:close()
  local t = remuda._butler_telemetry_adapters.claude.read({ status_path = base })
  return t.hook_state, t.hook_at
end
local s, at = state_of("needs you 1700\n")
check(s, "needs you", "reader word"); check(at, 1700, "reader time")
check(state_of("idle 5\n"), "idle", "reader idle")
check(state_of("bogus 5\n"), nil, "reader rejects unknown letters-only words")
check(state_of("rm -rf 5\n"), nil, "reader rejects unknown words")
check(state_of("idle\n"), nil, "reader needs a time")
os.remove(base .. ".state")
check(remuda._butler_telemetry_adapters.claude.read({ status_path = base }).hook_state, nil, "no file")
print("ok")
