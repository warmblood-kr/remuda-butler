remuda = {}
dofile("packages/butler/system.lua")
local doctor = dofile("packages/butler/doctor.lua")
local path = os.tmpname()
local rule = "Bash(remuda butler:*)"
local denied = '{"permissions":{"allow":[],"deny":["' .. rule .. '"]}}'
local allowed = '{"permissions":{"allow":["' .. rule .. '"]}}'
remuda.json = { decode = function(text)
  if text == denied then return { permissions = { allow = {}, deny = { rule } } } end
  if text == allowed then return { permissions = { allow = { rule } } } end
  if text == "{}" then return {} end
  error("invalid JSON")
end }
local settings = assert(io.open(path, "w"))
settings:write(denied)
settings:close()

local report = {
  path = path,
  added = {},
  present = { rule },
  withheld = {},
}
local context = { sources = { path } }
local lines = table.concat(doctor.permission_lines(report, "claude", context), "\n")
assert(not lines:find("present " .. rule, 1, true),
  "doctor trusts the launch-time allow report after current settings deny the rule:\n" .. lines)
assert(lines:find("Fix:", 1, true), "doctor must explain how to fix the ineffective close permission")
settings = assert(io.open(path, "w"))
settings:write(allowed)
settings:close()
lines = table.concat(doctor.permission_lines(report, "claude", context), "\n")
assert(lines:find("present " .. rule, 1, true), "current allow must be reported as present")
assert(not lines:find("Fix:", 1, true), "current allow does not need a fix")
os.remove(path)
lines = table.concat(doctor.permission_lines(report, "claude", context), "\n")
assert(lines:find("Fix:", 1, true), "absent current settings must have a Fix line")
assert(not lines:find("present " .. rule, 1, true), "absent settings must not reuse the cached allow")
-- Other settings layers can block an otherwise valid local allow.
local fixtures = {}
local decode = remuda.json.decode
remuda.json.decode = function(text) return fixtures[text] or decode(text) end
local extra = path .. ".user"
local function check(label, settings, want)
  fixtures[label] = settings
  local file = assert(io.open(extra, "w")); file:write(label); file:close()
  file = assert(io.open(path, "w")); file:write(allowed); file:close()
  local result = table.concat(doctor.permission_lines(report, "claude", { sources = { extra, path } }), "\n")
  assert(result:find(want, 1, true), label .. ": " .. result)
  return result
end
check("broad deny", { permissions = { deny = { "Bash(remuda *)" } } }, "under deny")
check("close ask", { permissions = { ask = { "Bash(remuda butler close:*)" } } }, "under ask")
check("classify all", { autoMode = { classifyAllShell = true } }, "classifyAllShell")
check("managed only", { allowManagedPermissionRulesOnly = true }, "managed-only")
check("wrong allow", { permissions = { allow = { bad = rule } } }, "invalid rule list")
local file = assert(io.open(extra, "w")); file:write("broken JSON"); file:close()
lines = table.concat(doctor.permission_lines(report, "claude", { sources = { extra, path } }), "\n")
assert(lines:find("invalid settings", 1, true) and lines:find("Fix:", 1, true), lines)
os.remove(extra)
os.remove(path)
print("butler_permissions_effective ok")
