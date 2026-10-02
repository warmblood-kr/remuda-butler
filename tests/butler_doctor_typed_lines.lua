local config = { typed_lines = true, shell_lines = false, approve_text = false }
remuda = {
  _butler_system = {
    platform = function() return "macos" end,
    find_command = function() return nil end,
  },
  _butler_matrix_config = { config_path = "/test/matrix-config" },
  butler = { matrix = { read_config = function(path)
    assert(path == "/test/matrix-config")
    return config
  end } },
}

local doctor = dofile("packages/butler/doctor.lua")
local function output()
  return table.concat(doctor.render(doctor.probe(), "macos"), "\n")
end

local rendered = output()
assert(rendered:find("Typed lines: on", 1, true), "doctor should show typed-lines on")
assert(rendered:find("Shell lines: off", 1, true), "doctor should show shell-lines off")
assert(rendered:find("Approve text: off", 1, true), "doctor should show approve-text off")
config.typed_lines, config.shell_lines = false, true
rendered = output()
assert(rendered:find("Typed lines: off", 1, true), "doctor should show typed-lines off")
assert(rendered:find("Shell lines: on", 1, true), "doctor should show shell-lines on")
print("ok - doctor typed-line switch status")
