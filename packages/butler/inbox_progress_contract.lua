-- ABSTRACT factory; product target inbox_progress.lua, actual inbox SQLite only.
local M = { contract_version = 1 }
function M.open(config)
  return nil, { code = "contract_unimplemented", operation = "progress.open" }
end
return M
