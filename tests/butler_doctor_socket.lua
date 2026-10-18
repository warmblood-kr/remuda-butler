remuda = {
  _butler_system = { platform = function() return "macos" end, find_command = function() return nil end },
}
local doctor = dofile("packages/butler/doctor.lua")
local function line()
  local rendered = table.concat(doctor.render(doctor.probe(), "macos"), "\n")
  return rendered:match("Socket publication: [^\n]*")
end

remuda.daemon = { socket_publication = function() return { state = "staged" } end }
assert(line() == "Socket publication: staged", "staged daemon: " .. tostring(line()))
remuda.daemon = { socket_publication = function() return { state = "legacy", reason = "path too long\nx" } end }
assert(line() == "Socket publication: legacy: path too long x", "legacy shows its terminal-safe reason: " .. tostring(line()))
remuda.daemon = nil
assert(line() == "Socket publication: unknown (old daemon)", "old core without remuda.daemon: " .. tostring(line()))
remuda.daemon = { socket_publication = function() error("unknown variant") end }
assert(line() == "Socket publication: unknown (old daemon)", "a raising answer is unknown, not a crash")
remuda.daemon = { socket_publication = function() return { state = "unsupported" } end }
assert(line() == "Socket publication: unknown (old daemon)", "unsupported is unknown")
print("ok - doctor socket publication")
