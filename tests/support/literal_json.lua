-- A stand-in for remuda.json that round-trips Lua values as Lua literals, for
-- standalone tests. decode raises on text that is not a literal, as the real
-- one does on malformed JSON; the daemon tests cover the real encoder.
local M = {}

local function literal(value)
  if type(value) == "string" then return ("%q"):format(value) end
  if type(value) ~= "table" then return tostring(value) end
  local out = {}
  for key, item in pairs(value) do out[#out + 1] = "[" .. literal(key) .. "]=" .. literal(item) end
  return "{" .. table.concat(out, ",") .. "}"
end

function M.encode(value) return literal(value) end

function M.decode(text)
  local chunk = assert(loadstring("return " .. text))
  setfenv(chunk, {})
  return chunk()
end

return M
