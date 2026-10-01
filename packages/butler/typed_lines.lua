-- Pure validation and parsing for owner-authored Matrix typed lines.
local M = {}

local MAX_AGE_SECONDS = 300
local MAX_LINE_BYTES = 2000
local RATE_WINDOW_SECONDS = 600
local RATE_LIMIT = 10

local function is_agent(sender, cfg)
  if sender == cfg.self_mxid or (cfg.butler_senders or {})[sender] == true then return true end
  local localpart = type(sender) == "string" and sender:match("^@([^:]+):.+$")
  if not localpart then return true end
  local normalized = localpart:lower()
  return normalized:sub(1, 6) == "agent-" or normalized:sub(1, 7) == "butler-"
end

local function has_forbidden_character(text)
  if text:find("[%z\1-\31\127]") or text:find("\194[\128-\159]") then return true end
  -- Unicode directional marks, embeddings, overrides, and isolates.
  return text:find("\216\156") ~= nil
    or text:find("\226\128[\142\143\170-\174]") ~= nil
    or text:find("\226\129[\166-\169]") ~= nil
    or text:find("\226\128[\168\169]") ~= nil
end

local function reject(reason)
  return false, reason
end

function M.gate(state, event, now, cfg)
  state = type(state) == "table" and state or {}
  cfg = type(cfg) == "table" and cfg or {}
  if type(event) ~= "table" then return reject("invalid_event") end

  local sender = event.sender
  if type(sender) ~= "string" or (cfg.allowed_senders or {})[sender] ~= true or is_agent(sender, cfg) then
    return reject("sender_not_allowed")
  end

  local event_time = tonumber(event.origin_server_ts)
  now = tonumber(now)
  if not event_time or not now then return reject("invalid_time") end
  local age = now - event_time / 1000
  if age < -60 or age > MAX_AGE_SECONDS then return reject("event_too_old") end

  local event_id = event.event_id
  if type(event_id) ~= "string" or event_id == "" then return reject("missing_event_id") end
  if (state.processed or {})[event_id] == true then return reject("event_replayed") end

  if event.type ~= "m.room.message" then return reject("unreadable_content") end
  local content = event.content
  if type(content) ~= "table" or content.msgtype ~= "m.text" or type(content.body) ~= "string"
    or (type(content["m.relates_to"]) == "table" and content["m.relates_to"].rel_type == "m.replace")
    or content["m.new_content"] ~= nil then
    return reject("unreadable_content")
  end

  local body = content.body
  if #body > MAX_LINE_BYTES or body:find("[\r\n]") or has_forbidden_character(body) then
    return reject("invalid_line")
  end

  local form, line, payload
  if body:sub(1, 3) == "!!!" then return reject("invalid_prefix")
  elseif body:sub(1, 2) == "!!" then
    form, payload = "!!", body:sub(3)
    if cfg.shell_lines ~= true then return reject("shell_lines_off") end
  elseif body:sub(1, 1) == "!" then
    form, payload = "!", body:sub(2)
  else
    return reject("invalid_prefix")
  end
  if payload:match("^%s*$") then return reject("empty_line") end
  line = form == "!!" and ("!" .. payload) or payload
  if cfg.typed_lines ~= true then return reject("typed_lines_off") end

  local recent = 0
  for _, timestamp in ipairs(state.timestamps or {}) do
    timestamp = tonumber(timestamp)
    if timestamp and timestamp >= now - RATE_WINDOW_SECONDS then recent = recent + 1 end
  end
  if recent >= RATE_LIMIT then return reject("rate_limited") end

  return true, nil, line, form
end

return M
