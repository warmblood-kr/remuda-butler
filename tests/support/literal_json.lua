-- A stand-in for remuda.json that round-trips Lua values as Lua literals, for
-- standalone tests. decode raises on text that is not a literal, as the real
-- one does on malformed JSON; it also refuses an empty table that is not marked with array or object,
-- as the real encoder does. The daemon tests cover the real encoder.
local M = {}

local marked = setmetatable({}, { __mode = "k" })
function M.array(value) marked[value] = true; return value end
function M.object(value) marked[value] = true; return value end

local function literal(value)
  if type(value) == "string" then return ("%q"):format(value) end
  if type(value) ~= "table" then return tostring(value) end
  if next(value) == nil and not marked[value] then
    error("empty tables are ambiguous; use remuda.json.array or remuda.json.object", 0)
  end
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
