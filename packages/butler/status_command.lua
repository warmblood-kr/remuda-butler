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
  if not value or value ~= value or value < 0 or value > 1000 then return "n/a" end
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
  local limits = type(quota) == "table" and type(quota.limits) == "table" and quota.limits or {}
  for _, limit in ipairs(limits) do
    local label = type(limit) == "table"
      and (limit.name == "5-hour limit" and "5h" or limit.name == "Weekly limit" and "7d" or nil)
    if label and tonumber(limit.used) then parts[#parts + 1] = label .. " " .. percent_text(limit.used) end
  end
  local claude = #parts > 0 and table.concat(parts, " · ") or "n/a"
  local at = type(quota) == "table" and tonumber(quota.at)
  if #parts > 0 and at and now - at > STALE_SECONDS and now - at < 1e9 then
    claude = claude .. " (as of " .. age_text(now - at) .. " ago)"
  end
  return "quota    claude " .. claude .. "  codex n/a"
end

local function metric_text(value, percent)
  if type(value) ~= "string" or #value > 12 then return "n/a" end
  local number
  if percent then
    number = value:match("^(%d+)%%$")
  else
    number = value:match("^(%d+%.?%d*)$")
  end
  number = tonumber(number)
  local limit = percent and 100 or 1000
  if not number or number ~= number or number < 0 or number > limit then
    return "n/a"
  end
  return value
end

local function metrics_line(metrics)
  metrics = type(metrics) == "table" and metrics or {}
  return "load     cpu " .. metric_text(metrics.cpu, false)
    .. " · mem " .. metric_text(metrics.mem, true)
    .. " · disk " .. metric_text(metrics.disk, true)
end

local function compose(rows, hidden, quota, metrics, now, total)
  local out = { "butler status · " .. total .. " sessions" }
  for _, row in ipairs(rows) do out[#out + 1] = row end
  if hidden > 0 then out[#out + 1] = "+" .. hidden .. " more" end
  out[#out + 1] = quota_line(quota, now)
  out[#out + 1] = metrics_line(metrics)
  out[#out + 1] = "Answered by code, no LLM. More: ?help"
  return table.concat(out, "\n"), #out
end

local TRUNCATED = "(truncated)"

-- Final bound on the whole reply; cuts on a line and UTF-8 boundary and ends with a marker line.
local function clamp(text)
  local count = select(2, text:gsub("\n", "")) + 1
  if count <= MAX_LINES and #text <= MAX_BYTES then return text end
  local kept, used = {}, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if #kept >= MAX_LINES - 1 then break end
    kept[#kept + 1] = line
  end
  local head = table.concat(kept, "\n")
  local room = MAX_BYTES - #TRUNCATED - 1
  if #head > room then
    local cut = room
    while cut > 0 and head:byte(cut + 1) and head:byte(cut + 1) >= 0x80 and head:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    head = head:sub(1, cut)
  end
  return head .. "\n" .. TRUNCATED
end

-- data = { sessions = { {name, kind, context_percent, busy, unread} }, quota = {at, limits}|nil, now }
function M.status_format(data)
  data = type(data) == "table" and data or {}
  local sessions = type(data.sessions) == "table" and data.sessions or {}
  local now = tonumber(data.now) or 0
  local rows = {}
  for index, session in ipairs(sessions) do rows[index] = session_line(type(session) == "table" and session or {}) end
  local text
  local head = {}
  for i, row in ipairs(rows) do head[i] = row end
  for shown = #rows, 0, -1 do
    head[shown + 1] = nil
    local count
    text, count = compose(head, #rows - shown, data.quota, data.metrics, now, #rows)
    if count <= MAX_LINES and #text <= MAX_BYTES then break end
  end
  return clamp(text)
end

function M.help_text()
  return table.concat({
    "?status  sessions, context, quota",
    "?help    this list",
    "Each command is one whole line. Answered by code, no LLM.",
  }, "\n")
end

local COMMANDS = { ["?status"] = "status", ["?help"] = "help" }
local REPLY_INTERVAL_SECONDS = 10

-- A whole line that is exactly one known command; anything else is ordinary mail.
function M.parse(body)
  return COMMANDS[body]
end

-- One reply per interval per sender; `last` maps sender to the last reply time.
function M.rate_check(last, sender, now)
  local previous = last[sender]
  return not (previous and now - previous >= 0 and now - previous < REPLY_INTERVAL_SECONDS)
end

function M.rate_allow(last, sender, now)
  if not M.rate_check(last, sender, now) then return false end
  last[sender] = now
  return true
end

-- Folds the pcall of M.handle into the relay's decision. A handle that raised on
-- a line that parses as a command still consumes the event, with no reply; a
-- line that is not a command is left to the ordinary path. A consumed raise
-- returns the trace reason as the fourth result.
function M.outcome(ok, matched, text, commit, body)
  if ok then return matched == true, text, commit end
  if M.parse(body) == nil then return false end
  return true, nil, nil, "handler_error"
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function session_names(agents)
  local names = {}
  for name in pairs(agents) do names[#names + 1] = tostring(name) end
  table.sort(names, function(a, b)
    if (a == "butler") ~= (b == "butler") then return a == "butler" end
    return a < b
  end)
  return names
end

-- Reads live Butler state only: no process, no shell, no screen text. A source
-- that fails leaves its own field empty.
function M.gather(now)
  local host = type(remuda) == "table" and remuda or {}
  local bus = type(host._butler_bus) == "table" and host._butler_bus or {}
  local agents = type(bus.agents) == "table" and bus.agents or {}
  local pending = type(bus.pending_tasks) == "table" and bus.pending_tasks or {}
  local mail = type(host._butler_mail) == "table" and host._butler_mail or {}
  local system = type(host._butler_system) == "table"
    and host._butler_system or {}
  local metrics = try(system.status_metrics)
  local sessions = {}
  for _, name in ipairs(session_names(agents)) do
    local agent = agents[name]
    if type(agent) == "table" then
      local telemetry = try(host._butler_telemetry_for, agent)
      sessions[#sessions + 1] = {
        name = name, kind = agent.kind,
        context_percent = type(telemetry) == "table" and tonumber(telemetry.context_percent) or nil,
        busy = pending[name] ~= nil,
        unread = type(agent.id) == "string" and agent.id ~= "" and try(mail.unread, agent.id) or nil,
      }
    end
  end
  local quota = type(host._butler_quota) == "table" and try(host._butler_quota.claude_reading) or nil
  return { sessions = sessions, quota = quota, metrics = metrics, now = now }
end

local function accept(state, event, now, cfg)
  return butler.typed_lines.accept(state, event, now, cfg)
end

-- Decides one Matrix event. Returns matched, text: matched is true when the
-- event is a status command that must not reach mail or a session; text is
-- nil when the sender is inside the reply window. An unmatched event returns
-- false, nil, reason. The third result is a commit
-- function the caller runs once the reply is durable: it opens the sender's
-- reply window. scope = { live, room_allowed, rate }.
function M.handle(state, event, now, cfg, scope)
  if cfg.status_commands ~= true then return false, nil, "switch_off" end
  if scope.live ~= true then return false, nil, "not_live" end
  if scope.room_allowed ~= true then return false, nil, "room_not_allowed" end
  local accepted, reason, body = accept(state, event, now, cfg)
  if not accepted then return false, nil, reason end
  local command = M.parse(body)
  if not command then return false, nil, "unknown_command" end
  if not M.rate_check(scope.rate, event.sender, now) then return true end
  local function commit() scope.rate[event.sender] = now end
  if command == "help" then return true, M.help_text(), commit end
  -- An internal error still consumes the event; the reply stays a bare line.
  local ok, text = pcall(function() return M.status_format(M.gather(now)) end)
  return true, ok and text or "status unavailable", commit
end

return M
