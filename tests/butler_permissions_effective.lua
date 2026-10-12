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
print("butler_permissions_effective ok")
