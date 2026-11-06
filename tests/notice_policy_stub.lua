-- Shared unit-test composition for the common notification policy.
-- The audited dialogs wakeup is the legacy transport boundary: this stub keeps
-- its live-row/instance preflight and generation fence, then delegates to the
-- test's remuda.send fake so transport outcomes stay covered.
dofile("packages/butler/send_policy.lua")

remuda.butler = remuda.butler or {}
if type(remuda.butler.dialogs) ~= "table" then remuda.butler.dialogs = {} end
if type(remuda.butler.dialogs.automatic_notice_send) ~= "function" then
  local function notice_bus()
    return remuda._butler_bus
      or (remuda._butler_notice_config and remuda._butler_notice_config.bus) or {}
  end
  remuda.butler.dialogs.automatic_notice_send = function(session, text, ids, still_current)
    local agents = notice_bus().agents or {}
    local agent = agents[session]
    if not agent then return false, "session_unknown" end
    local row
    for _, candidate in ipairs(remuda.ls()) do
      if candidate.name == session then row = candidate end
    end
    if not row or not row.alive then return false, "session_not_live" end
    local expected, actual = agent.instance_id, row.instance_id
    if type(expected) == "string" and expected ~= "" then
      if type(actual) ~= "string" or actual == "" then return false, "session_instance_missing" end
      if actual ~= expected then return false, "session_replaced" end
    end
    if type(still_current) == "function" then
      local ok_guard, current = pcall(still_current, { recipient_id = agent.id,
        agent_instance = agent.instance_id, instance = actual, row_id = row.id })
      if not ok_guard or current ~= true then return false, "journal_generation_changed" end
    end
    local ok, result, detail = pcall(remuda.send, session, text)
    if not ok then error(result, 0) end
    if result ~= false then return true end
    return false, "send_refused: " .. tostring(detail or result or "refused")
  end
end
