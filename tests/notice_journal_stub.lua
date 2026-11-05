-- Shared in-memory delivery journal for standalone notice tests.
-- The production module is loaded unchanged; only its storage, clock, codec and
-- hash seams are injected, so tests exercise the real validation and states.
local journal_module = dofile("packages/butler/delivery_journal.lua")
local files = {}

local function literal(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = literal(item) end
    local keys = {}
    for key in pairs(value) do
      if type(key) ~= "number" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("[%q]=%s", key, literal(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

local codec = {
  encode = literal,
  decode = function(text) return assert(loadstring("return " .. text))() end,
  array = function(value) return value end,
  object = function(value) return value end,
}

local function new_journal()
  return journal_module.new({ path = "notice-test-journal",
    read = function(path)
      if files[path] == nil then return nil, "missing" end
      return files[path]
    end,
    write = function(path, text) files[path] = text; return true end,
    now = function()
      local clock = remuda._butler_notice_clock
      return type(clock) == "function" and clock() or os.time()
    end,
    hash = function(body) return string.format("%x", #body) end,
    json = codec })
end

remuda._butler_notice_test_journal = { files = files, new = new_journal }
remuda._butler_delivery_journal = new_journal()
