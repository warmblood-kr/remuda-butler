-- Read-only rendering of the automatic-delivery journal for `butler doctor`.
-- It never mutates the journal, never reads notice bodies, and never prints a
-- path, endpoint, nonce or credential: only states, counts, ages, recipient and
-- message IDs, and the recorded reason.
local M = {}

local MAX_ITEMS = 5

local function age_text(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds < 60 then return tostring(seconds) .. "s" end
  if seconds < 3600 then return tostring(math.floor(seconds / 60)) .. "m" end
  if seconds < 86400 then return tostring(math.floor(seconds / 3600)) .. "h" end
  return tostring(math.floor(seconds / 86400)) .. "d"
end

local function usable_line(status)
  if status.entries == 0 then
    return "Automatic delivery: journal ok (no reserved or uncertain attempts)"
  end
  local parts = { tostring(status.uncertain or 0) .. " uncertain",
    tostring(status.accepted_unread or 0) .. " accepted-unread",
    tostring(status.dispatching or 0) .. " dispatching" }
  return "Automatic delivery: " .. table.concat(parts, ", ")
    .. " (oldest " .. age_text(status.oldest_seconds) .. "; journal ok)"
end

local function problem_line(status)
  if status.corrupt then
    return "Automatic delivery: journal CORRUPT (" .. tostring(status.corrupt)
      .. "); automatic notices are blocked, mail stays unread. Next: inspect "
      .. "the delivery journal, then restart Butler"
  end
  if status.blocked then
    return "Automatic delivery: journal blocked (" .. tostring(status.blocked)
      .. "); no automatic notice is being written"
  end
  if status.full then
    return "Automatic delivery: journal full (" .. tostring(status.entries or 0)
      .. " attempts); automatic notices stay blocked until capacity is freed"
  end
  if status.digests_unverified then
    return "Automatic delivery: journal waiting for its hash module; no automatic "
      .. "notice is written until the persisted bodies verify"
  end
end

local function item_lines(status)
  local lines = {}
  for index, item in ipairs(status.items or {}) do
    if index > MAX_ITEMS then break end
    local ids = {}
    for _, id in ipairs(item.message_ids or {}) do ids[#ids + 1] = tostring(id) end
    lines[#lines + 1] = "  " .. tostring(item.state or "unknown") .. " for "
      .. tostring(item.recipient_id or "unknown") .. " ids=" .. table.concat(ids, ",")
      .. " age=" .. age_text(item.age_seconds)
      .. (item.reason and item.reason ~= "" and (" reason=" .. tostring(item.reason)) or "")
  end
  if #lines > 0 then lines[#lines + 1] = "  (no automatic resend; mail stays unread)" end
  return lines
end

-- `status` is the journal's own read-only snapshot. A nil journal means the
-- module is unavailable, which blocks notice delivery; say so plainly.
function M.lines(journal, now)
  if not journal or type(journal.status) ~= "function" then
    return { "Automatic delivery: journal unavailable; automatic notices are blocked" }
  end
  local ok, status = pcall(journal.status, now)
  if not ok or type(status) ~= "table" then
    return { "Automatic delivery: journal status unavailable; automatic notices are blocked" }
  end
  local lines = { problem_line(status) or usable_line(status) }
  for _, line in ipairs(item_lines(status)) do lines[#lines + 1] = line end
  return lines
end

remuda.butler = remuda.butler or {}
remuda.butler.delivery_status = M
return M
