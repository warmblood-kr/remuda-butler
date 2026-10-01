-- Unit tests for packages/butler/typed_lines.lua. Run from the repository root:
--   luajit tests/butler_typed_lines.lua
local typed_lines = dofile("packages/butler/typed_lines.lua")

local owner = "@owner:example.org"
local now = 1800000000
local cfg = {
  allowed_senders = { [owner] = true },
  butler_senders = { ["@remuda-bot:example.org"] = true },
  typed_lines = true,
  shell_lines = true,
}

local function event(body, overrides)
  local value = {
    event_id = "$event-1",
    sender = owner,
    type = "m.room.message",
    origin_server_ts = now * 1000,
    content = { msgtype = "m.text", body = body },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local empty = { processed = {}, timestamps = {} }
local cases = {
  { name = "plain form strips one bang", event = event("!hello"), ok = true, line = "hello", form = "!" },
  { name = "shell form leaves one bang", event = event("!!ls"), ok = true, line = "!ls", form = "!!" },
  { name = "leading slash is allowed", event = event("!/status"), ok = true, line = "/status", form = "!" },
  { name = "owner allowlist required", event = event("!hello", { sender = "@other:example.org" }), ok = false },
  { name = "Butler sender refused", event = event("!hello", { sender = "@remuda-bot:example.org" }), ok = false },
  { name = "non-message sender kind refused", event = event("!hello", { sender = "@member-agent:example.org" }), ok = false },
  { name = "event older than five minutes refused", event = event("!hello", { origin_server_ts = (now - 301) * 1000 }), ok = false },
  { name = "event exactly five minutes old accepted", event = event("!hello", { origin_server_ts = (now - 300) * 1000 }), ok = true, line = "hello", form = "!" },
  { name = "replayed event refused", event = event("!hello"), state = { processed = { ["$event-1"] = true }, timestamps = {} }, ok = false },
  { name = "encrypted content refused", event = event("!hello", { content = nil, type = "m.room.encrypted" }), ok = false },
  { name = "non-text message refused", event = event("!hello", { content = { msgtype = "m.image", body = "!hello" } }), ok = false },
  { name = "multiline refused", event = event("!one\ntwo"), ok = false },
  { name = "control character refused", event = event("!one\ttwo"), ok = false },
  { name = "direction character refused", event = event("!one\226\128\143two"), ok = false },
  { name = "2000 byte line accepted", event = event("!" .. string.rep("a", 1999)), ok = true, line = string.rep("a", 1999), form = "!" },
  { name = "over 2000 byte line refused", event = event("!" .. string.rep("a", 2000)), ok = false },
  { name = "triple bang refused", event = event("!!!ls"), ok = false },
  { name = "eleventh line in ten minutes refused", event = event("!hello"), state = { processed = {}, timestamps = { now - 10, now - 9, now - 8, now - 7, now - 6, now - 5, now - 4, now - 3, now - 2, now - 1 } }, ok = false },
  { name = "typed lines switch off", event = event("!hello"), cfg = { typed_lines = false, shell_lines = true }, ok = false },
  { name = "shell lines switch off", event = event("!!ls"), cfg = { typed_lines = true, shell_lines = false }, ok = false },
}

for index, case in ipairs(cases) do
  local ok, reason, line, form = typed_lines.gate(case.state or empty, case.event, now, case.cfg or cfg)
  assert(ok == case.ok, ("case %d (%s): expected ok=%s, got %s (%s)"):format(
    index, case.name, tostring(case.ok), tostring(ok), tostring(reason)))
  if case.line ~= nil then
    assert(line == case.line, ("case %d (%s): expected line %q, got %q"):format(
      index, case.name, case.line, tostring(line)))
    assert(form == case.form, ("case %d (%s): expected form %q, got %q"):format(
      index, case.name, case.form, tostring(form)))
  end
end

print(("ok - %d typed-line gate cases"):format(#cases))
