-- Matrix `?status` and `?help`: read-only answers built by code, no LLM.
local butler = type(remuda) == "table" and remuda.butler or nil
if not butler then butler = {} end
if type(remuda) == "table" then remuda.butler = butler end
local M = butler.status_command or {}
if type(remuda) == "table" then butler.status_command = M end

local MAX_LINES = 14
local MAX_BYTES = 1500
local STALE_SECONDS = 600
local NAME_LIMIT = 24

-- Session names and kinds come from agents; only plain name characters reach Matrix.
local function safe_word(value)
  return (tostring(value or ""):gsub("[^%w%._%-]", ""):sub(1, NAME_LIMIT))
end

local function percent_text(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then return "n/a" end
  return string.format("%.0f%%", value)
end

local function session_line(session)
  local line = string.format("%-8s %-6s ctx %s  %s", safe_word(session.name), safe_word(session.kind),
    percent_text(session.context_percent), session.busy and "task" or "idle")
  local unread = tonumber(session.unread)
  if unread and unread > 0 then line = line .. string.format("  ✉%d", unread) end
  return line
end

local function age_text(seconds)
  if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
  return string.format("%dh", math.floor(seconds / 3600))
end

local function quota_line(quota, now)
  local parts = {}
  for _, limit in ipairs(type(quota) == "table" and quota.limits or {}) do
    local label = limit.name == "5-hour limit" and "5h" or limit.name == "Weekly limit" and "7d" or nil
    if label and tonumber(limit.used) then parts[#parts + 1] = label .. " " .. percent_text(limit.used) end
  end
  local claude = #parts > 0 and table.concat(parts, " · ") or "n/a"
  local at = type(quota) == "table" and tonumber(quota.at)
  if #parts > 0 and at and now - at > STALE_SECONDS then
    claude = claude .. " (as of " .. age_text(now - at) .. " ago)"
  end
  return "quota    claude " .. claude .. "  codex n/a"
end

local function compose(rows, hidden, quota, now, total)
  local out = { "butler status · " .. total .. " sessions" }
  for _, row in ipairs(rows) do out[#out + 1] = row end
  if hidden > 0 then out[#out + 1] = "+" .. hidden .. " more" end
  out[#out + 1] = quota_line(quota, now)
  out[#out + 1] = "load     cpu n/a · mem n/a · disk n/a"
  out[#out + 1] = "Answered by code, no LLM. More: ?help"
  return table.concat(out, "\n"), #out
end

-- data = { sessions = { {name, kind, context_percent, busy, unread} }, quota = {at, limits}|nil, now }
function M.status_format(data)
  data = type(data) == "table" and data or {}
  local sessions = type(data.sessions) == "table" and data.sessions or {}
  local now = tonumber(data.now) or 0
  local rows = {}
  for index, session in ipairs(sessions) do rows[index] = session_line(session) end
  local text
  for shown = #rows, 0, -1 do
    local head, count = {}, nil
    for i = 1, shown do head[i] = rows[i] end
    text, count = compose(head, #rows - shown, data.quota, now, #rows)
    if count <= MAX_LINES and #text <= MAX_BYTES then break end
  end
  return text
end

function M.help_text()
  return table.concat({
    "?status  sessions, context, quota",
    "?help    this list",
    "Each command is one whole line. Answered by code, no LLM.",
  }, "\n")
end

return M
