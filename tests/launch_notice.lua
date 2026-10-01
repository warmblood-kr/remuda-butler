-- The owner-facing text for "no agent could start".
-- Run from the repo root: luajit tests/launch_notice.lua
local notice = dofile("packages/butler/launch_notice.lua")

local HEAD = "Butler could not start an agent on this machine."
local TAIL = "Butler keeps retrying; no restart is needed after the fix."

local function lines_of(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  return lines
end

local function one(kind, reason, detail)
  local lines = lines_of(notice.text({ { kind = kind, reason = reason, detail = detail } }))
  assert(#lines == 3 and lines[1] == HEAD and lines[3] == TAIL, table.concat(lines, "|"))
  return lines[2]
end

local function eq(got, want)
  if got ~= want then error(("\n want: %s\n  got: %s"):format(want, tostring(got)), 2) end
end

-- One exact line per reason.
eq(one("claude", "login"), "claude: not logged in. Next: claude auth login")
eq(one("codex", "login"), "codex: not logged in. Next: codex login")
eq(one("gemini", "login"), "gemini: not logged in. Next: remuda butler doctor")
eq(one("claude", "dialog"),
  "claude: stopped at a startup dialog. Next: run claude in a terminal on this machine and answer the dialog")
eq(one("claude", "timeout"), "claude: did not become ready in time. Next: remuda butler doctor")
eq(one("claude", "exited"), "claude: exited before it was ready. Next: remuda butler doctor")
eq(one("claude", "spawn_error"), "claude: could not be started. Next: remuda butler doctor")
eq(one("claude", "not_found"), "claude: not installed. Next: remuda butler doctor")
-- A reason outside the list prints the fixed fallback, never the reason text.
eq(one("claude", "rm -rf / \27[31m"), "claude: did not start. Next: remuda butler doctor")
eq(one("claude", nil), "claude: did not start. Next: remuda butler doctor")

-- The screen detail never reaches the text.
local secret = "Please log in to continue. prompt: the launch codes are 1234"
local with_detail = notice.text({
  { kind = "claude", reason = "login", detail = secret },
  { kind = "codex", reason = "timeout", detail = "last screen: " .. secret },
})
assert(not with_detail:find("1234", 1, true) and not with_detail:find("Please log in", 1, true), with_detail)
eq(#lines_of(with_detail), 4)

-- A kind outside letters, digits, _ . - (or too long) is printed as "agent".
eq(one("my agent\27[2J", "login"), "agent: not logged in. Next: remuda butler doctor")
eq(one("a@b:c/d", "timeout"), "agent: did not become ready in time. Next: remuda butler doctor")
eq(one(("k"):rep(33), "exited"), "agent: exited before it was ready. Next: remuda butler doctor")
eq(one(nil, "exited"), "agent: exited before it was ready. Next: remuda butler doctor")
eq(one("claude-code_2.1", "exited"), "claude-code_2.1: exited before it was ready. Next: remuda butler doctor")
eq(one("agent", "dialog"),
  "agent: stopped at a startup dialog. Next: run agent in a terminal on this machine and answer the dialog")

-- A ready attempt is not a failure; with no failure there is no notice.
eq(notice.text({ { kind = "claude", reason = "ready" } }), nil)
eq(notice.text({}), nil)
eq(#lines_of(notice.text({ { kind = "claude", reason = "login" }, { kind = "codex", reason = "ready" } })), 3)

-- More than eight failed attempts are summarized.
local many = {}
for i = 1, 11 do many[i] = { kind = "k" .. i, reason = "timeout" } end
local summarized = lines_of(notice.text(many))
eq(#summarized, 11)
eq(summarized[9], "k8: did not become ready in time. Next: remuda butler doctor")
eq(summarized[10], "and 3 more")
assert(#notice.text(many) <= 1024, "the notice stays under the cap")

-- The signature changes with kind or reason only.
local base = notice.signature({ { kind = "claude", reason = "login", detail = "a" } })
eq(notice.signature({ { kind = "claude", reason = "login", detail = "another screen" } }), base)
assert(notice.signature({ { kind = "codex", reason = "login" } }) ~= base)
assert(notice.signature({ { kind = "claude", reason = "timeout" } }) ~= base)
assert(notice.signature({ { kind = "claude", reason = "login" }, { kind = "codex", reason = "login" } }) ~= base)

print("ok: launch notice lines, no detail, safe kind, summary, signature")
