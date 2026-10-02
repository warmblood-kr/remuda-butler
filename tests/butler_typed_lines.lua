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
  { name = "allowlisted Butler sender refused", event = event("!hello", { sender = "@remuda-bot:example.org" }), cfg = {
    allowed_senders = { ["@remuda-bot:example.org"] = true },
    butler_senders = { ["@remuda-bot:example.org"] = true }, typed_lines = true, shell_lines = true,
  }, ok = false },
  { name = "allowlisted agent prefix refused", event = event("!hello", { sender = "@agent-worker:example.org" }), cfg = {
    allowed_senders = { ["@agent-worker:example.org"] = true }, typed_lines = true, shell_lines = true,
  }, ok = false },
  { name = "non-message sender kind refused", event = event("!hello", { sender = "@member-agent:example.org" }), ok = false },
  { name = "event older than five minutes refused", event = event("!hello", { origin_server_ts = (now - 301) * 1000 }), ok = false },
  { name = "event exactly five minutes old accepted", event = event("!hello", { origin_server_ts = (now - 300) * 1000 }), ok = true, line = "hello", form = "!" },
  { name = "event 60 seconds ahead accepted", event = event("!hello", { origin_server_ts = (now + 60) * 1000 }), ok = true, line = "hello", form = "!" },
  { name = "event over 60 seconds ahead refused", event = event("!hello", { origin_server_ts = (now + 61) * 1000 }), ok = false },
  { name = "replayed event refused", event = event("!hello"), state = { processed = { ["$event-1"] = true }, timestamps = {} }, ok = false },
  { name = "encrypted content refused", event = event("!hello", { content = nil, type = "m.room.encrypted" }), ok = false },
  { name = "non-text message refused", event = event("!hello", { content = { msgtype = "m.image", body = "!hello" } }), ok = false },
  { name = "formatted message refused", event = event("!hello", { content = {
    msgtype = "m.text", body = "!hello", format = "org.matrix.custom.html", formatted_body = "<b>!hello</b>",
  } }), ok = false },
  { name = "multiline refused", event = event("!one\ntwo"), ok = false },
  { name = "Unicode line separator refused", event = event("!one\226\128\168two"), ok = false, reason = "invalid_line" },
  { name = "Unicode paragraph separator refused", event = event("!one\226\128\169two"), ok = false, reason = "invalid_line" },
  { name = "zero-width space refused", event = event("!one\226\128\139two"), ok = false, reason = "invalid_line" },
  { name = "zero-width non-joiner refused", event = event("!one\226\128\140two"), ok = false, reason = "invalid_line" },
  { name = "zero-width joiner refused", event = event("!one\226\128\141two"), ok = false, reason = "invalid_line" },
  { name = "word joiner refused", event = event("!one\226\129\160two"), ok = false, reason = "invalid_line" },
  { name = "tag block start refused", event = event("!one\243\160\128\128two"), ok = false, reason = "invalid_line" },
  { name = "tag character refused", event = event("!one\243\160\129\161two"), ok = false, reason = "invalid_line" },
  { name = "tag block end refused", event = event("!one\243\160\129\191two"), ok = false, reason = "invalid_line" },
  { name = "space-only plain payload refused", event = event("! "), ok = false, reason = "empty_line" },
  { name = "space-only shell payload refused", event = event("!!  "), ok = false, reason = "empty_line" },
  { name = "control character refused", event = event("!one\ttwo"), ok = false },
  { name = "direction character refused", event = event("!one\226\128\143two"), ok = false },
  { name = "2000 byte line accepted", event = event("!" .. string.rep("a", 1999)), ok = true, line = string.rep("a", 1999), form = "!" },
  { name = "over 2000 byte line refused", event = event("!" .. string.rep("a", 2000)), ok = false },
  { name = "triple bang refused", event = event("!!!ls"), ok = false },
  { name = "eleventh line in ten minutes refused", event = event("!hello"), state = { processed = {}, timestamps = { now - 10, now - 9, now - 8, now - 7, now - 6, now - 5, now - 4, now - 3, now - 2, now - 1 } }, ok = false },
  { name = "typed lines switch off", event = event("!hello"), cfg = {
    allowed_senders = { [owner] = true }, typed_lines = false, shell_lines = true,
  }, ok = false, reason = "typed_lines_off" },
  { name = "shell line requires typed lines too", event = event("!!ls"), cfg = {
    allowed_senders = { [owner] = true }, typed_lines = false, shell_lines = true,
  }, ok = false, reason = "typed_lines_off" },
  { name = "shell lines switch off", event = event("!!ls"), cfg = {
    allowed_senders = { [owner] = true }, typed_lines = true, shell_lines = false,
  }, ok = false, reason = "shell_lines_off" },
}

for index, case in ipairs(cases) do
  local ok, reason, line, form = typed_lines.gate(case.state or empty, case.event, now, case.cfg or cfg)
  assert(ok == case.ok, ("case %d (%s): expected ok=%s, got %s (%s)"):format(
    index, case.name, tostring(case.ok), tostring(ok), tostring(reason)))
  if case.reason then
    assert(reason == case.reason, ("case %d (%s): expected reason %q, got %q"):format(
      index, case.name, case.reason, tostring(reason)))
  end
  if case.line ~= nil then
    assert(line == case.line, ("case %d (%s): expected line %q, got %q"):format(
      index, case.name, case.line, tostring(line)))
    assert(form == case.form, ("case %d (%s): expected form %q, got %q"):format(
      index, case.name, case.form, tostring(form)))
  end
end

assert(next(empty.processed) == nil and #empty.timestamps == 0, "gate must not mutate replay or rate state")
print(("ok - %d typed-line gate cases"):format(#cases))
