-- First-task routing for a native-selected session.
-- A native binding, including a sticky disabled one, must never receive the
-- task body through the frozen helper or the composer. The whole task is
-- written to durable Butler mail; only the ordinary canonical pointer reaches
-- the session. A failed write is reported, never typed instead. Pure seams are
-- injected so this policy is unit-tested without a daemon.
local M = {}

-- Native mode is sticky: disabled still owns the first task (mail + alert),
-- while a PTY/unbound session keeps the legacy typed first prompt.
function M.binding(agent)
  local native = type(agent) == "table" and agent.native or nil
  if type(native) == "table"
      and (native.mode == "native" or native.mode == "disabled") then
    return native
  end
end

function M.route(agent)
  return M.binding(agent) ~= nil
end

local function clean(reason)
  return tostring(reason or "unknown"):gsub("%c+", " "):sub(1, 300)
end

-- Returns the durable message id on success, or nil plus a short reason.
function M.queue(self, name, parent, task)
  if type(task) ~= "string" or task == "" then return nil, "empty_task" end
  if not self or type(self.queue_message) ~= "function"
      or type(self.mail_address) ~= "function" then
    return nil, "mail_unavailable"
  end
  local queued, message, err = pcall(self.queue_message,
    self.mail_address(parent or "butler"), self.mail_address(name), task, "Task")
  if queued and type(message) == "table" and message.id then
    if self.trace then
      pcall(self.trace, "first_task_native_mail", name .. " message=" .. tostring(message.id))
    end
    return message.id
  end
  local reason = clean(queued and (err or "no message id") or message)
  if self.trace then
    pcall(self.trace, "first_task_native_mail_failed", name .. " " .. reason)
  end
  if type(self.send) == "function" then
    pcall(self.send, "butler", parent or "butler",
      "the initial task for " .. name .. " could not be saved as durable mail ("
        .. reason .. "). It was not typed into the native session;"
        .. " resend it after checking the mailbox.")
  end
  return nil, reason
end

remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_task = M
return M
