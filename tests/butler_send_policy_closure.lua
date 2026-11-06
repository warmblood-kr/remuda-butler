-- Run from the repository root: luajit tests/butler_send_policy_closure.lua
-- The common policy accepts only target+intent from a caller. Raw adapters are
-- private, and the genuine journal/current/outcome seams are bound once from
-- the live notice image; neither a forged attempt nor caller callbacks can run
-- the helper without crossing that reservation.
local root = "."
local calls = 0
local codec = { encode = function() return "{}" end,
  decode = function() return { outcome = "accepted_queue" } end }
local native = { mode = "native", kind = "opencode",
  path = "/private/tmp/fake/manifest.json", nonce = string.rep("ab", 16),
  row_id = "row-1", instance = "instance-1" }
local agent = { id = "member-id", kind = "opencode", instance_id = "instance-1",
  native = native }
remuda = { json = codec, _butler_notice = {},
  _butler_bus = { agents = { member = agent } },
  process = { run = function()
    calls = calls + 1
    return { code = 0, stdout = "{}", stderr = "" }
  end } }
local dispatch_module = assert(loadfile(root .. "/packages/butler/native_dispatch.lua"))()
local policy = assert(loadfile(root .. "/packages/butler/send_policy.lua"))()

-- The one-shot transport factory is consumed synchronously during policy
-- module initialization: no caller can take it after load, before any send.
assert(dispatch_module.install == nil, "the transport factory door is already closed")
local took, factory = pcall(function() return dispatch_module.install(policy) end)
assert(not took or factory == nil, "a later factory takeover yields no factory")

-- Raw constructors/adapters are not public, so a caller cannot obtain a send
-- handle nor substitute callbacks for the genuine journal authority.
assert(policy.construct == nil, "no public adapter constructor")
assert(policy.observe == nil and policy.decide == nil and policy.result == nil,
  "only typed admission and one-shot binding are public")
local function forged_attempt()
  return { ids = { "m1" }, request_id = "msg_forged",
    still_current = function() return true end,
    target = function() return {} end,
    text = "Butler message m1 arrived. Read it: MCP butler_inbox (or remuda butler inbox)" }
end
local forged = policy.send_message("member", { intent = "mail_notice",
  reserve = function() return forged_attempt() end,
  native_outcome = function() return true end,
  unavailable = function() end, resolve = function() return true end })
assert(forged == false and calls == 0, "caller seam callbacks never dispatch")

-- The notice image binds its genuine seam once; every later binding is refused.
local journal = { reserved = false, resolved = false, fail = false }
local seam = {
  blocked = function() return false end,
  unavailable = function() return false end,
  reserve = function()
    if journal.fail then return nil, "journal_full" end
    journal.reserved = true
    return { ids = { "m1" }, request_id = "msg_bound",
      text = "Butler message m1 arrived. Read it: MCP butler_inbox (or remuda butler inbox)",
      target = function() return { id = "row-1", instance_id = "instance-1" } end,
      still_current = function() return true end }
  end,
  native_outcome = function()
    assert(journal.reserved, "the journal reservation precedes the transport")
    journal.resolved = true
    return true
  end,
  resolve = function(sent)
    assert(journal.resolved, "the outcome seam follows the transport")
    return sent
  end,
}
assert(policy.bind(remuda._butler_notice, function(session)
  if session == "member" then return seam end
end) == true, "the current notice image binds once")
assert(policy.bind(remuda._butler_notice, function() end) == false,
  "a second binding is refused")
assert(policy.send_message("member", "mail_notice") == true,
  "the bound image reserves, dispatches and resolves")
assert(calls == 1 and journal.reserved and journal.resolved,
  "one helper call after the real reservation")

-- A journal failure is pre-write: zero helper invocations.
calls, journal.reserved, journal.resolved, journal.fail = 0, false, false, true
assert(policy.send_message("member", "mail_notice") == false,
  "a failed reservation refuses the notice")
assert(calls == 0 and not journal.resolved, "no helper without a reservation")

print("ok - policy admission is data-only and the bound journal seam gates the transport")
