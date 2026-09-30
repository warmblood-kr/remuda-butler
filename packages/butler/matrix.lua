-- Internal inbound Matrix channel. The async L3 relay is a short composite
-- over the L1 request word and owns its lifecycle in the named matrix table.
local butler = remuda.butler or {}
remuda.butler = butler
local matrix = butler.matrix or {}
butler.matrix = matrix

if not matrix.request_json then remuda.exec("butler/matrix_request") end
remuda.exec("butler/matrix_read")
remuda.exec("butler/approval")
if not matrix.send then remuda.exec("butler/matrix_write") end
remuda.exec("butler/matrix_setup")
remuda.exec("butler/matrix_cli")
remuda.exec("butler/matrix_relay")

return matrix
