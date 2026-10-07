-- Run from the repo root: luajit tests/caller_identity.lua
remuda = {
  _butler_caller_principal_config = { bus = { agents = {
    member = { id = "01ABCDEF0123456789ABCDEFGH", alias = "member", session_name = "session-member", kind = "codex" },
  } } },
  butler = { guard_policy = { append = function(row)
    assert(row.event == "caller_policy" and row.class == "identity")
    return true
  end } },
}
dofile("packages/butler/caller_principal.lua")
local resolver = remuda._butler_caller_principal

local caller = { kind = "session", session = "session-member", env = { REMUDA_BUTLER_AGENT_ID = "forged" } }
local principal = resolver.resolve(caller)
assert(principal.tag == "member" and principal.id == "01ABCDEF0123456789ABCDEFGH")
assert(resolver.current_agent(caller) == principal.id)
assert(resolver.resolve({ kind = "session", session = "session-member" }).id == principal.id)
assert(resolver.resolve({ kind = "outside", env = { REMUDA_BUTLER_AGENT_ID = principal.id } }).tag == "operator")
assert(resolver.current_agent({ kind = "outside" }) == nil)

for _, unknown in ipairs({
  { kind = "session", session = "unregistered" },
  { kind = "unknown" },
  { session = "session-member" },
}) do
  local ok, err = pcall(resolver.current_agent, unknown)
  assert(not ok and tostring(err):find("Next:", 1, true), "unknown caller must fail closed")
end
local ok, err = pcall(resolver.current_agent, nil)
assert(not ok and tostring(err):find("Next:", 1, true), "missing caller must fail closed")

print("ok")

-- Operator authority is refused if its required audit cannot be written.
remuda.butler.guard_policy.append = function() return nil, "disk unavailable" end
assert(resolver.resolve({kind = "outside"}).tag == "unidentified")
assert(not pcall(resolver.current_agent, {kind = "outside"}))
remuda.butler.guard_policy.append = function() error("old sink unavailable") end
assert(resolver.resolve({kind = "outside"}).tag == "unidentified")
