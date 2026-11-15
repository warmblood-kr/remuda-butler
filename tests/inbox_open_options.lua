-- inbox_open: one activation state and one capability read decide either
-- must_exist options or a refusal. An active inbox must never receive
-- create-capable options, and an unknown or vanished marker is not fresh.
remuda = {}
local function fresh()
  remuda = {}
  return assert(loadfile("packages/butler/inbox_open.lua"))()
end

local function eq(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

-- No marker: a fresh install keeps the create path and reads no capability.
local M = fresh()
M.observe("absent")
local read = 0
local old_core = { capabilities = function() read = read + 1; return nil end }
local options, refusal = M.prepare(old_core)
eq(refusal, nil, "fresh install is not refused")
eq(options.must_exist, nil, "fresh install must keep the create path")
eq(options.migrations, true, "migrations stay enabled")
eq(read, 0, "a fresh install does not read the capability")
eq(M.status().protection, "precheck", "fresh protection")

-- No capability: an active inbox refuses before any open.
M = fresh()
M.observe("present")
options, refusal = M.prepare(old_core)
eq(options, nil, "old core active options")
assert(type(refusal) == "string", "old core must refuse an active inbox")
assert(refusal:find("Upgrade remuda", 1, true), refusal)
assert(refusal:find("must_exist", 1, true), refusal)
eq(M.status().protection, "refused", "old core protection")
eq(M.status().active, true, "old core active")

-- Partial, raising and non-table reports are not support.
for _, core in ipairs({
  { capabilities = function() return { other = true } end },
  { capabilities = function() error("boom") end },
  { capabilities = function() return "yes" end },
}) do
  M = fresh()
  M.observe("present")
  options, refusal = M.prepare(core)
  eq(options, nil, "unsupported core active options")
  assert(refusal, "unsupported core must refuse an active inbox")
end

-- Supported + active: must_exist, and exactly one capability read.
M = fresh()
M.observe("present")
local calls = 0
local modern = { capabilities = function()
  calls = calls + 1
  return { must_exist = true }
end }
options, refusal = M.prepare(modern)
eq(refusal, nil, "supported core must not refuse")
eq(options.must_exist, true, "supported active inbox must pass must_exist")
eq(calls, 1, "capability is read once")
eq(M.status().protection, "must_exist", "supported protection")

-- A second answer cannot undo the first: the cached answer is used.
modern.capabilities = function() error("second read") end
options, refusal = M.prepare(modern)
eq(refusal, nil, "cached support keeps the decision")
eq(options.must_exist, true, "cached support keeps must_exist")
eq(calls, 1, "no second capability read")

-- A first refusal cannot be undone by a later support report.
M = fresh()
M.observe("present")
local late = { capabilities = function() return { must_exist = false } end }
options, refusal = M.prepare(late)
eq(options, nil, "first refusal stands")
assert(refusal, "first refusal message")
late.capabilities = function() return { must_exist = true } end
options, refusal = M.prepare(late)
eq(options, nil, "a later support report cannot open a refused process")
assert(refusal, "the refusal is stable")

-- Unknown marker state refuses and is not cleared by a later absence.
M = fresh()
M.observe(nil, "denied: test")
options, refusal = M.prepare({ capabilities = function() return { must_exist = true } end })
eq(options, nil, "unknown marker options")
assert(refusal and refusal:find("denied: test", 1, true), tostring(refusal))
M.observe("absent")
options, refusal = M.prepare({ capabilities = function() return { must_exist = true } end })
eq(options, nil, "an unknown state is not cleared by a later absence")
assert(refusal, "unknown marker stays refused")

-- Once active, a vanished marker never returns to the create path.
M = fresh()
M.observe("present")
M.observe("absent")
options, refusal = M.prepare({ capabilities = function() return { must_exist = true } end })
eq(refusal, nil, "a vanished marker is not a fresh refusal")
eq(options.must_exist, true, "a vanished marker stays active")

-- Re-executing the module in the same process reuses the latch and the
-- capability answer, as a butler reload does.
M = fresh()
M.observe("present")
M.prepare({ capabilities = function() return { must_exist = true } end })
local reloaded = assert(loadfile("packages/butler/inbox_open.lua"))()
eq(reloaded.status().active, true, "reload keeps the active latch")
reloaded.observe("absent")
local reload_options, reload_refusal = reloaded.prepare(
  { capabilities = function() error("second read") end })
eq(reload_refusal, nil, "reload does not re-read the capability")
eq(reload_options and reload_options.must_exist, true, "reload keeps must_exist")

-- Activation after the first import latches the same state.
M = fresh()
M.observe("absent")
M.activate()
options, refusal = M.prepare({ capabilities = function() return { must_exist = true } end })
eq(refusal, nil, "activation does not refuse")
eq(options.must_exist, true, "activation uses must_exist")

print("ok")
