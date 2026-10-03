local config = { typed_lines = true, shell_lines = false, approve_text = false,
  approval_room = "all", home_room = "!room:example.org",
  all_room = "!all:example.org", rooms = { ["!all:example.org"] = "all" } }
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
assert(rendered:find("Approval room: all -> !all:example.org", 1, true), "doctor should show the configured approval room")
config.typed_lines, config.shell_lines = false, true
rendered = output()
assert(rendered:find("Typed lines: off", 1, true), "doctor should show typed-lines off")
assert(rendered:find("Shell lines: on", 1, true), "doctor should show shell-lines on")
config.approval_room, config.all_room, config.rooms = "home", nil, {}
rendered = output()
assert(rendered:find("Approval room: home -> HOME", 1, true), "doctor should show the HOME selection")
config.approval_room = "all"
rendered = output()
assert(rendered:find("Approval room: all -> HOME (lounge not joined)", 1, true), "doctor should show the HOME fallback")
print("ok - doctor typed-line switch status")

-- The setup hint appears only while Matrix is not configured.
local ready = { installed = true, logged_in = true }
local function lines_with(matrix_configured)
  return table.concat(doctor.render({ claude = ready, codex = ready, matrix_configured = matrix_configured }, "macos"), "\n")
end
assert(lines_with(false):find("Next: remuda butler matrix setup", 1, true), "unconfigured Matrix points to setup")
assert(not lines_with(true):find("Next:", 1, true), "configured Matrix gets no setup hint")
assert(doctor.probe().matrix_configured == true, "a readable Matrix config counts as configured")
print("ok - doctor setup hint only when Matrix is unconfigured")
