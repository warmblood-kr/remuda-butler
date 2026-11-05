-- Run from the repository root: luajit tests/butler_roster_native.lua
-- Native binding persistence and sticky adoption: the roster stores only the
-- private path and nonce, and adoption requires the exact live instance id.
-- A missing session row id disables delivery instead of falling back to PTY.
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

local bus = { agents = {}, tokens = {}, identity_ids = {} }
local token_seq, saved = 0, nil
remuda = {
  _butler_roster_config = { data_home = "/data", bus = bus,
    new_ulid = function() return "01MARKER" end,
    next_token = function(alias) token_seq = token_seq + 1; return "token-" .. alias .. token_seq end },
  json = codec,
  mkdir = function() return true end,
  fs = { write_atomic = function(path, text, options)
    assert(path == "/data/remuda/butler/roster.json", "roster path")
    assert(options.private == true, "the roster is private")
    saved = text
    return true
  end },
}
dofile("packages/butler/roster.lua")
local M = assert(remuda._butler_roster)
local binding = "/data/remuda/butler/bindings/lead/" .. string.rep("ab", 16) .. "/manifest.json"
local rows

local function reset(native, overrides)
  bus.agents, bus.tokens, bus.identity_ids = {}, {}, {}
  bus.identity_ids["lead-id"] = { state = "running", alias = "lead" }
  bus.agents.lead = { id = "lead-id", alias = "lead", session_name = "lead", kind = "opencode",
    instance_id = "instance-1", instance_binding = 1, native = native }
  for key, value in pairs(overrides or {}) do bus.agents.lead[key] = value end
end
local function persist()
  saved = nil
  assert(M.save() == true, "the roster saves")
  if saved then
    local decoded = codec.decode(saved)
    assert(decoded.version == 1, "the versioned roster")
    rows = decoded.rows
  else
    rows = M.rows()
  end
end
local function adopt(session)
  bus.agents, bus.tokens = {}, {}
  bus.identity_ids["lead-id"] = { state = "running", alias = "lead" }
  token_seq = 0
  M.load = function() return rows end
  return M.adopt({ session })
end

-- 1. rows() persists only a complete path + nonce pair, never live identity.
reset({ mode = "native", path = binding, nonce = string.rep("ab", 16),
  row_id = "ses_abc", instance = "instance-1" })
persist()
assert(#rows == 1 and rows[1].native and rows[1].native.path == binding
  and rows[1].native.nonce == string.rep("ab", 16), "path and nonce persist")
assert(rows[1].native.mode == nil and rows[1].native.row_id == nil,
  "the live row id and mode are not persisted")

reset({ mode = "native", path = binding })
assert(#M.rows() == 1 and M.rows()[1].native == nil,
  "an incomplete native binding is not persisted")
reset({ mode = "native", nonce = string.rep("ab", 16) })
assert(M.rows()[1].native == nil, "a binding without a path is not persisted")

-- 2. Adoption keeps the bound identity and takes the exact live row id.
reset({ mode = "native", path = binding, nonce = string.rep("ab", 16) })
persist()
local adopted = adopt({ name = "lead", alive = true, instance_id = "instance-1", id = "ses_live" })
assert(#adopted == 1, "the matching instance is adopted")
local agent = bus.agents.lead
assert(agent.native.mode == "native" and agent.native.row_id == "ses_live"
  and agent.native.instance == "instance-1" and agent.native.path == binding
  and agent.native.nonce == string.rep("ab", 16), "native adoption is exact")
assert(bus.tokens[agent.token].instance_id == "instance-1", "the token keeps the instance")

-- 3. A missing session row id disables, keeps the binding and never uses PTY.
reset({ mode = "native", path = binding, nonce = string.rep("ab", 16) })
persist()
assert(#adopt({ name = "lead", alive = true, instance_id = "instance-1" }) == 1,
  "the instance is still adopted")
agent = bus.agents.lead
assert(agent.native.mode == "disabled" and agent.native.reason == "missing_row_id",
  "a missing row id disables delivery")
assert(agent.native.path == binding and agent.native.nonce == string.rep("ab", 16),
  "the binding survives for inspection")

-- 4. A reused name with another instance is never adopted as bound.
reset({ mode = "native", path = binding, nonce = string.rep("ab", 16) })
persist()
assert(#adopt({ name = "lead", alive = true, instance_id = "instance-2", id = "ses_new" }) == 0,
  "an instance mismatch is not adopted")

print("ok - native binding persists privately and adopts only the exact instance")
