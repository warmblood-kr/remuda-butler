-- Run from the repository root: luajit tests/butler_native_identity.lua
-- Canonical id resolution: direct row.id, or one official `ls --json` query
-- proven to describe the same daemon, matched by exact name + instance_id,
-- with a full Lua snapshot check after the client yield. No cache, no alias,
-- no instance-as-id, no lookup on the normal path.
local function literal(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = literal(item) end
    local keys = {}
    for key in pairs(value) do if type(key) ~= "number" then keys[#keys + 1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("[%q]=%s", key, literal(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

local codec = {
  encode = literal,
  decode = function(text) return assert(loadstring("return " .. text))() end,
}

remuda = {}
local module = dofile("packages/butler/native_identity.lua")

local function snapshot(rows)
  local copy = {}
  for index, row in ipairs(rows) do
    copy[index] = { name = row.name, instance_id = row.instance_id, alive = row.alive }
  end
  return copy
end

local rows = {
  { name = "lead", instance_id = "instance-1", alive = true },
  { name = "worker", instance_id = "instance-2", alive = false },
}
local listed = {
  { id = "core-id-lead", name = "lead", instance_id = "instance-1", alive = true,
    extra = "ignored" },
  { id = "core-id-worker", name = "worker", instance_id = "instance-2", alive = false },
}
local function listing(value) return function() return snapshot(value) end end
local function answer(value, code)
  return function() return { code = code or 0, stdout = codec.encode(value) } end
end
local function options(value, overrides)
  overrides = overrides or {}
  return { rows = overrides.rows or rows, list = overrides.list or listing(rows),
    runner = overrides.runner or answer(value), json = codec }
end

-- 1. A direct row.id never spawns the helper.
local calls = 0
local direct = { name = "lead", instance_id = "instance-1", alive = true, id = "ses_direct" }
assert(module.resolve(direct, { rows = rows, list = listing(rows), json = codec,
  runner = function() calls = calls + 1; return { code = 0, stdout = "" } end }) == "ses_direct")
assert(calls == 0, "no lookup when the projection already has an id")

-- 2. The official answer is trusted only when it describes the same daemon
-- and the full Lua fleet is unchanged after the client yield.
assert(module.resolve(rows[1], options(listed)) == "core-id-lead",
  "the canonical id is returned")

-- 3. Wrong daemon: identical names, different instances.
local _, why = module.resolve(rows[1], options({
  { id = "core-id-lead", name = "lead", instance_id = "instance-9", alive = true },
  { id = "core-id-worker", name = "worker", instance_id = "instance-8", alive = false },
}))
assert(why == "identity_unverified", "identical names on another daemon are refused")

-- 4. Target matches but another row drifted in the CLI listing.
_, why = module.resolve(rows[1], options({
  listed[1],
  { id = "x", name = "worker", instance_id = "instance-2", alive = true },
}))
assert(why == "identity_unverified", "a sibling alive drift is refused")

-- 5. The FULL Lua snapshot must be unchanged after the CLI yield.
_, why = module.resolve(rows[1], options(listed, { list = function()
  return snapshot({ rows[1], { name = "worker", instance_id = "instance-3", alive = false } })
end }))
assert(why == "identity_unverified", "post-yield fleet drift is refused")
_, why = module.resolve(rows[1], options(listed, { list = function()
  return snapshot({ rows[1] })
end }))
assert(why == "identity_unverified", "a post-yield count change is refused")
_, why = module.resolve(rows[1], options(listed, { list = function()
  return snapshot({ { name = "lead", instance_id = "instance-1", alive = false }, rows[2] })
end }))
assert(why == "identity_unverified", "a post-yield target death is refused")

-- 6. Missing/ambiguous/empty rows fail closed.
_, why = module.resolve(rows[1], options({ listed[2] }))
assert(why == "identity_unverified", "a missing target is refused")
local empty_runner = function() return { code = 0, stdout = "{}" } end
_, why = module.resolve(rows[1], { rows = {}, list = function() return {} end,
  runner = empty_runner, json = codec })
assert(why == "identity_unverified", "an empty fleet cannot prove a daemon")
_, why = module.resolve(rows[1], options({ listed[1], listed[2], listed[1] }))
assert(why == "identity_unverified", "a duplicate row is refused")
_, why = module.resolve(rows[1], options({
  { name = "lead", instance_id = "instance-1", alive = true }, listed[2] }))
assert(why == "missing_row_id", "a target without an id is refused")
_, why = module.resolve({ name = "lead", instance_id = "", alive = true }, options(listed))
assert(why == "missing_row_identity", "an empty instance is never resolved")
_, why = module.resolve({ name = "lead", instance_id = "instance-1", alive = true },
  options({ { id = "core-id-lead", name = "lead", instance_id = "instance-1", alive = false },
    listed[2] }))
assert(why == "identity_unverified", "a dead target is refused")
_, why = module.resolve(rows[1], options(listed, { rows = {
  { name = "lead", instance_id = "instance-1", alive = true },
  { name = "lead", instance_id = "instance-2", alive = true },
} }))
assert(why == "identity_unverified", "duplicate names are refused")
_, why = module.resolve(rows[1], options(listed, { rows = {
  { name = "lead", instance_id = "instance-1", alive = true },
  { name = "worker", instance_id = "instance-2", alive = "yes" },
} }))
assert(why == "identity_unverified", "a non-boolean alive is refused")

-- 7. A lookup that cannot answer safely never becomes an id.
local target = rows[1]
_, why = module.resolve(target, options(listed, { runner = function()
  return { timed_out = true }
end }))
assert(why == "identity_unavailable", "a timeout is unavailable")
_, why = module.resolve(target, options(listed, { runner = function()
  return { code = 2, stdout = "" }
end }))
assert(why == "identity_unavailable", "a nonzero exit is unavailable")
_, why = module.resolve(target, options(listed, { runner = function() error("boom") end }))
assert(why == "identity_unavailable", "a runner failure is unavailable")
_, why = module.resolve(target, options(listed, { runner = function()
  return { code = 0, stdout = "not json" }
end }))
assert(why == "identity_invalid", "malformed output is invalid")
_, why = module.resolve(target, options(listed, { runner = function()
  return { code = 0, stdout = string.rep("x", 70000) }
end }))
assert(why == "identity_invalid", "oversized output is invalid")

-- 8. No cached authority: two resolutions both prove again.
local proof_calls = 0
local proof = options(listed, { runner = function(call)
  proof_calls = proof_calls + 1
  return { code = 0, stdout = codec.encode(listed) }
end })
assert(module.resolve(target, proof) == "core-id-lead")
assert(module.resolve(target, proof) == "core-id-lead")
assert(proof_calls == 2, "every resolution proves the current fleet")

-- 9. The fixed helper command carries no caller text.
local seen
module.resolve(target, options(listed, { runner = function(call)
  seen = call
  return { code = 0, stdout = codec.encode(listed) }
end }))
assert(seen.argv[1] == "remuda" and seen.argv[2] == "ls" and seen.argv[3] == "--json"
  and #seen.argv == 3, "only the fixed read-only listing runs")
assert(seen.timeout == 5, "the lookup is bounded")

print("ok - native identity resolves only proven canonical core ids")
