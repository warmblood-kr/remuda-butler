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
  return assert(conf, "config must parse")
end

assert(switch("").status_commands == true, "absent status key is on")
-- approve_text and typed_lines are legacy switches: the owner no longer turns
-- them off, so read_config ignores the config value and keeps them on.
for _, key in ipairs({ "approve_text", "typed_lines" }) do
  assert(switch("")[key] == true, key .. " defaults on")
  assert(switch(key .. "=true\n")[key] == true, key .. " explicit true")
  assert(switch(key .. "=false\n")[key] == true, key .. " legacy false is ignored")
  for _, bad in ipairs({ "off", "0", "no", "", "TRUE", "yes" }) do
    assert(switch(key .. "=" .. bad .. "\n")[key] == true, key .. " legacy invalid value is ignored: " .. bad)
  end
end
-- shell_lines still has a working switch.
assert(switch("").shell_lines == true, "shell_lines defaults on")
assert(switch("shell_lines=true\n").shell_lines == true, "shell_lines explicit true")
assert(switch("shell_lines=false\n").shell_lines == false, "shell_lines explicit false stays off")
for _, bad in ipairs({ "off", "0", "no", "", "TRUE", "yes" }) do
  assert(switch("shell_lines=" .. bad .. "\n").shell_lines == false, "shell_lines invalid value fails closed: " .. bad)
end
assert(switch("status_commands=true\n").status_commands == true)
assert(switch("status_commands=false\n").status_commands == false)
for _, bad in ipairs({ "off", "0", "no", "", "TRUE", "yes" }) do
  assert(switch("status_commands=" .. bad .. "\n").status_commands == false, "invalid value fails closed: " .. bad)
end
print("ok - status_commands switch")

local docs = assert(io.open("docs/butler.md")):read("a")
assert(docs:find("any value other than `true` or `false` turns it off", 1, true), "docs state the fail-closed rule")
print("ok - docs state the rule")
