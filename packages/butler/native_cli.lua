-- Owner-facing native adoption CLI parsing and honest reporting.
-- Pure: the daemon glue is injected, so argv and messages are unit-testable.
-- A socket and thread are accepted only on argv for this one explicit owner
-- action; the success line never repeats either value.
local M = {}

local USAGE = "  remuda butler native adopt-codex ALIAS --socket PATH --thread UUID\n"
  .. "  Adopt an existing Codex TUI by the local socket and thread UUID from its"
  .. " fresh /status. Requires `codex.enabled: true` in native.json."
  .. " Example: remuda butler native adopt-codex m1 --socket unix:///private/tmp/codex.sock --thread 0123...cdef"

local function take_value(args, index, flag)
  local value = args[index + 1]
  if type(value) ~= "string" or value == "" or value:sub(1, 2) == "--" then
    return nil, flag .. " needs a value"
  end
  return value
end

function M.parse(args)
  args = args or {}
  for _, word in ipairs(args) do
    if word == "--help" or word == "help" then return nil, "help" end
  end
  if args[1] ~= "adopt-codex" then return nil, "usage" end
  local session, socket, thread
  local index = 2
  while index <= #args do
    local word = args[index]
    if word == "--socket" then
      if socket then return nil, "--socket was given twice" end
      socket = take_value(args, index, "--socket")
      if not socket then return nil, "usage" end
      index = index + 2
    elseif word == "--thread" then
      if thread then return nil, "--thread was given twice" end
      thread = take_value(args, index, "--thread")
      if not thread then return nil, "usage" end
      index = index + 2
    elseif word:sub(1, 2) == "--" then
      return nil, "unknown option " .. word
    elseif session then
      return nil, "unexpected argument " .. word
    else
      session = word
      index = index + 1
    end
  end
  if not session or not socket or not thread then return nil, "usage" end
  return { session = session, socket = socket, thread = thread }
end

local function safe_reason(value)
  return tostring(value or "unknown"):gsub("[^%w_%-%.: ]", "?"):sub(1, 300)
end

-- One attempt, one report. `unavailable`/`uncertain` never trigger an
-- automatic retry and never fall back to a PTY write.
function M.run(args, adopt)
  local parsed, why = M.parse(args)
  if not parsed then
    if why == "help" then return USAGE end
    return nil, why == "usage" and USAGE or (why .. "\n" .. USAGE)
  end
  if not adopt or type(adopt.adopt_codex) ~= "function" then
    return nil, "native adoption is unavailable on this build"
  end
  local ok, result, error_message = pcall(adopt.adopt_codex, parsed.session,
    parsed.socket, parsed.thread)
  if not ok then return nil, "adoption call failed: " .. safe_reason(result) end
  if type(result) == "table" and result.generation then
    return "codex session " .. parsed.session .. " is natively bound (generation "
      .. tostring(result.generation):sub(1, 12) .. "). Delivery uses only the canonical pointer."
  end
  error_message = safe_reason(error_message)
  if error_message:find("unavailable", 1, true) then
    return nil, "Codex adoption is unavailable: " .. error_message
      .. ". No binding was published; the session keeps ordinary delivery."
  end
  if error_message:find("uncertain", 1, true) then
    return nil, "Codex adoption result is uncertain: " .. error_message
      .. ". Do not retry automatically; inspect the session first."
  end
  return nil, "Codex adoption was not applied: " .. error_message
end

M.USAGE = USAGE
remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_cli = M
return M
