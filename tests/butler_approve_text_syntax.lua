-- Syntax checks for the prepared-text wiring. Run from the repository root:
--   luajit tests/butler_approve_text_syntax.lua
for _, path in ipairs({
  "packages/butler/approval.lua", "packages/butler/approve_text.lua",
  "packages/butler/commands.lua", "packages/butler/doctor.lua",
  "packages/butler/init.lua", "packages/butler/main.lua",
  "packages/butler/matrix.lua", "packages/butler/matrix_relay.lua",
  "packages/butler/matrix_request.lua", "packages/butler/typed_lines_cli.lua",
}) do
  local chunk, err = loadfile(path)
  assert(chunk, path .. ": " .. tostring(err))
end
print("ok - approval-text Lua syntax")
