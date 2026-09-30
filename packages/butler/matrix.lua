-- Internal inbound Matrix channel. The async L3 relay is a short composite
-- over the L1 request word and owns its lifecycle in the named matrix table.
local butler = remuda.butler or {}
remuda.butler = butler
local matrix = butler.matrix or {}
butler.matrix = matrix

matrix.utf8_prefix = function(value, limit)
  local cut = limit
  while cut > 0 do
    local byte = value:byte(cut + 1) or 0
    if byte < 0x80 or byte > 0xbf then break end
    cut = cut - 1
  end
  return value:sub(1, cut)
end

if not matrix.request_json then remuda.exec("butler/matrix_request") end
remuda.exec("butler/matrix_read")
remuda.exec("butler/approval")
if not matrix.send then remuda.exec("butler/matrix_write") end
remuda.exec("butler/matrix_setup")
remuda.exec("butler/matrix_cli")
remuda.exec("butler/matrix_relay")

return matrix
