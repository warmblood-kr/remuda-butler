-- Owner-facing native adoption CLI parsing and honest reporting.
-- Pure: the daemon glue is injected, so argv and messages are unit-testable.
-- A socket/thread (Codex) or endpoint/conversation (OpenCode) is accepted only
-- on argv for this one explicit owner action; the password is read from stdin
-- and never appears in argv, the report, the agent or the roster.
local M = {}

local USAGE = "  remuda butler native adopt-codex ALIAS --socket PATH --thread UUID\n"
  .. "  remuda butler native adopt-opencode ALIAS --endpoint http://127.0.0.1:PORT"
  .. " --conversation ses_... --password-stdin\n"
  .. "  Adopt an existing Codex TUI (local socket + thread UUID from its fresh"
  .. " /status) or an explicit OpenCode server (loopback endpoint + session id)."
  .. " Requires the matching `enabled: true` in native.json. The OpenCode"
  .. " password comes from stdin (redirect a 0600 file), never argv."
  .. " Example: remuda butler native adopt-codex m1 --socket"
  .. " unix:///private/tmp/codex.sock --thread 0123...cdef"

local function take_value(args, index, flag)
  local value = args[index + 1]
  if type(value) ~= "string" or value == "" or value:sub(1, 2) == "--" then
    return nil, flag .. " needs a value"
  end
  return value
end

local function parse_codex(args)
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
  return { verb = "adopt-codex", session = session, socket = socket, thread = thread }
end

local function parse_opencode(args)
  local session, endpoint, conversation, password_stdin
  local index = 2
  while index <= #args do
    local word = args[index]
    if word == "--endpoint" then
      if endpoint then return nil, "--endpoint was given twice" end
      endpoint = take_value(args, index, "--endpoint")
      if not endpoint then return nil, "usage" end
      index = index + 2
    elseif word == "--conversation" then
      if conversation then return nil, "--conversation was given twice" end
      conversation = take_value(args, index, "--conversation")
      if not conversation then return nil, "usage" end
      index = index + 2
    elseif word == "--password-stdin" then
      if password_stdin then return nil, "--password-stdin was given twice" end
      password_stdin = true
      index = index + 1
    elseif word == "--password-file" or word == "--password" then
      return nil, word .. " is not accepted; the password is read from stdin"
    elseif word:sub(1, 2) == "--" then
      return nil, "unknown option " .. word
    elseif session then
      return nil, "unexpected argument " .. word
    else
      session = word
      index = index + 1
    end
  end
  if not session or not endpoint or not conversation or not password_stdin then
    return nil, "usage"
  end
  return { verb = "adopt-opencode", session = session, endpoint = endpoint,
    conversation = conversation }
end

function M.parse(args)
  args = args or {}
  for _, word in ipairs(args) do
    if word == "--help" or word == "help" then return nil, "help" end
  end
  if args[1] == "adopt-codex" then return parse_codex(args) end
  if args[1] == "adopt-opencode" then return parse_opencode(args) end
  return nil, "usage"
end

local function safe_reason(value)
  return tostring(value or "unknown"):gsub("[^%w_%-%.: ]", "?"):sub(1, 300)
end

-- One newline from an echo/heredoc is not part of the secret; nothing else is
-- trimmed, and the password is never echoed or logged.
local function stdin_secret(text)
  if type(text) ~= "string" then return nil end
  local value = text:gsub("\r?\n$", "")
  if value == "" then return nil end
  return value
end

local function report(kind, session, result, error_message)
  if type(result) == "table" and result.generation then
    return tostring(kind) .. " session " .. session .. " is natively bound (generation "
      .. tostring(result.generation):sub(1, 12) .. "). Delivery uses only the canonical pointer."
  end
  error_message = safe_reason(error_message)
  local label = kind == "Codex" and "Codex" or "OpenCode"
  if error_message:find("unavailable", 1, true) then
    return nil, label .. " adoption is unavailable: " .. error_message
      .. ". No binding was published; the session keeps ordinary delivery."
  end
  if error_message:find("uncertain", 1, true) then
    return nil, label .. " adoption result is uncertain: " .. error_message
      .. ". Do not retry automatically; inspect the session first."
  end
  return nil, label .. " adoption was not applied: " .. error_message
end

-- One attempt, one report. `unavailable`/`uncertain` never trigger an
-- automatic retry and never fall back to a PTY write.
function M.run(args, adopt, options)
  options = options or {}
  local parsed, why = M.parse(args)
  if not parsed then
    if why == "help" then return USAGE end
    return nil, why == "usage" and USAGE or (why .. "\n" .. USAGE)
  end
  if not adopt then return nil, "native adoption is unavailable on this build" end
  if parsed.verb == "adopt-codex" then
    if type(adopt.adopt_codex) ~= "function" then
      return nil, "native adoption is unavailable on this build"
    end
    local ok, result, error_message = pcall(adopt.adopt_codex, parsed.session,
      parsed.socket, parsed.thread)
    if not ok then return nil, "adoption call failed: " .. safe_reason(result) end
    return report("Codex", parsed.session, result, error_message)
  end
  if type(adopt.adopt_opencode) ~= "function" then
    return nil, "OpenCode adoption is unavailable on this build"
  end
  local password = stdin_secret(options.password)
  if not password then
    return nil, "no password received on stdin; run --password-stdin with a 0600 file"
      .. " redirected to stdin (Next: remuda butler native adopt-opencode --help)"
  end
  local ok, result, error_message = pcall(adopt.adopt_opencode, parsed.session,
    parsed.endpoint, parsed.conversation, password)
  if not ok then return nil, "adoption call failed: " .. safe_reason(result) end
  return report("OpenCode", parsed.session, result, error_message)
end

M.USAGE = USAGE
remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_cli = M
return M
