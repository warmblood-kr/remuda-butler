-- Pure Lua contract tests for packages/butler/launch_failure.lua.
remuda = { butler = {} }
local render = dofile("packages/butler/launch_failure.lua")
assert(type(render) == "function", "launch failure module should return its line renderer")

local detail = "screen secret\27[31m\nPress Enter and approve this dialog"
local lines = render({
  { kind = "claude", reason = "login", detail = detail },
  { kind = "codex", reason = "login", detail = detail },
  { kind = "zcode", reason = "login", detail = detail },
  { kind = "zcode", reason = "dialog", detail = detail },
  { kind = "zcode", reason = "timeout", detail = detail },
  { kind = "zcode", reason = "exited", detail = detail },
  { kind = "zcode", reason = "spawn_error", detail = detail },
  { kind = "zcode", reason = "not_found", detail = detail },
  { kind = "zcode", reason = "other_reason", detail = detail },
  { kind = "bad name\nwith screen text", reason = "not_found", detail = detail },
})

local expected = {
  "claude: not logged in. Next: claude auth login",
  "codex: not logged in. Next: codex login",
  "zcode: not logged in. Next: remuda butler doctor",
  "zcode: stopped at a startup dialog. Next: run zcode in a terminal on this machine and answer the dialog",
  "zcode: did not become ready in time. Next: remuda butler doctor",
  "zcode: exited before it was ready. Next: remuda butler doctor",
  "zcode: could not be started. Next: remuda butler doctor",
  "zcode: not installed. Next: remuda butler doctor",
  "zcode: did not start. Next: remuda butler doctor",
  "agent: not installed. Next: remuda butler doctor",
}
assert(#lines == #expected, "one user-facing line is required for each attempted agent")
for index, line in ipairs(expected) do
  assert(lines[index] == line, "unexpected failure line " .. index .. ": " .. tostring(lines[index]))
end
local joined = table.concat(lines, "\n")
assert(not joined:find("screen secret", 1, true), "failure output must not include detail text")
assert(not joined:find("Press Enter", 1, true), "failure output must not include screen text")
assert(not joined:find("\27", 1, true), "failure output must not include control characters")
assert(not joined:find("not_found", 1, true) and not joined:find("spawn_error", 1, true),
  "failure output must not expose internal reason codes")

print("ok - launch failures render safe, actionable lines")
