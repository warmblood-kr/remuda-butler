-- status_commands switch in matrix_request.read_config. Run from the repository root:
--   luajit tests/butler_status_switch.lua
remuda = { json = { null = {}, array = function(t) return t end }, butler = {} }
dofile("packages/butler/matrix_request.lua")
local matrix = remuda.butler.matrix

local function switch(extra)
  local path = os.tmpname()
  local f = assert(io.open(path, "w"))
  f:write("https://matrix.example.org\n!room:example.org\n@bot:example.org\n\n\n\n" .. extra)
  f:close()
  local old_stderr = io.stderr
  io.stderr = { write = function() end }
  local conf = matrix.read_config(path)
  io.stderr = old_stderr
  os.remove(path)
  return assert(conf, "config must parse").status_commands
end

assert(switch("") == true, "absent key is on")
assert(switch("status_commands=true\n") == true)
assert(switch("status_commands=false\n") == false)
for _, bad in ipairs({ "off", "0", "no", "", "TRUE", "yes" }) do
  assert(switch("status_commands=" .. bad .. "\n") == false, "invalid value fails closed: " .. bad)
end
print("ok - status_commands switch")

local docs = assert(io.open("docs/butler.md")):read("a")
assert(docs:find("any value other than `true` or `false` turns it off", 1, true), "docs state the fail-closed rule")
print("ok - docs state the rule")
