-- Secure transaction ID entropy for Matrix writes.
-- Run from the repository root: luajit tests/butler_matrix_write.lua
local matrix = {
  once = function(callback) return callback end,
  path_component = function(value) return value end,
  sanitize_directory_text = function(value) return tostring(value or "") end,
}
local remuda = { butler = { matrix = matrix, approval = { handler = function() end } },
  random_bytes = function(n) return string.rep("r", n) end }
_G.remuda = remuda
local original_open = io.open
io.open = function(path)
  if path == "/dev/urandom" then return nil, "simulated unavailable random source" end
  return original_open(path)
end
assert(pcall(dofile, "packages/butler/matrix_write.lua"), "the core random source should be accepted")
remuda.random_bytes = nil
local loaded, err = pcall(dofile, "packages/butler/matrix_write.lua")
assert(not loaded and tostring(err):find("secure random source unavailable", 1, true),
  "Matrix writes must fail when both secure random sources are unavailable")
io.open = original_open
print("ok - Matrix transaction ID entropy")
