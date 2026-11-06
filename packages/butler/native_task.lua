-- New-task routing for known native-capable members.
-- A known kind, or any sticky native binding, must never receive the task body
-- through the frozen helper or the composer. The whole task is written to
-- durable Butler mail; only the ordinary canonical pointer is admitted by the
-- common send policy. A failed write is reported, never typed instead. Pure
-- seams are injected so this policy is unit-tested without a daemon.
local M = {}

local KNOWN_KINDS = { opencode = true, codex = true, claude = true }

-- Native mode is sticky. Disabled still owns the task (mail + policy outcome);
-- an unbound known kind also routes to mail + the audited legacy wakeup.
function M.binding(agent)
  local native = type(agent) == "table" and agent.native or nil
  if type(native) == "table"
      and (native.mode == "native" or native.mode == "disabled") then
    return native
  end
end

-- Known three kinds always route; an unknown kind routes only when it already
-- has a sticky native binding (never fall back to body typing). Unknown unbound
-- kinds keep the legacy typed path unchanged.
function M.route(agent, kind)
  if M.binding(agent) ~= nil then return true end
  kind = kind or (type(agent) == "table" and agent.kind) or ""
  return KNOWN_KINDS[kind] == true
end

local function clean(reason)
  return tostring(reason or "unknown"):gsub("%c+", " "):sub(1, 300)
end

local function report(self, name, parent, text)
  if type(self.send) == "function" then
    pcall(self.send, "butler", parent or "butler", text)
  end
end

local function trace(self, event, detail)
  if self.trace then pcall(self.trace, event, detail) end
end

local function storage_failure(self, name, parent, reason)
  trace(self, "first_task_native_mail_failed", name .. " " .. reason)
  report(self, name, parent,
    "the initial task for " .. name .. " could not be saved as durable mail ("
      .. reason .. "). It was not typed into the member session;"
      .. " resend it after checking the mailbox.")
  return nil, reason, { saved = false, stage = "storage" }
end

local function notify_status(called, returned, reason)
  if not called then return "error", clean(returned) end
  if returned == false then return "error", clean(reason or "notify_refused") end
  -- The shared notify contract returns the stored message; nil is not a
  -- supported success shape.
  if returned == nil then return "error", "notify_unavailable" end
  return "attempted", nil
end

local function notify_failure(self, name, parent, message, why)
  trace(self, "first_task_native_notify_failed",
    name .. " message=" .. tostring(message.id) .. " " .. tostring(why))
  report(self, name, parent,
    "the initial task for " .. name .. " was saved as durable mail ("
      .. tostring(message.id) .. "), but the pointer notification outcome could not be confirmed ("
      .. tostring(why) .. "). Read the existing inbox; do not resend the body.")
end

-- Durable success returns (saved_id, nil, info); storage failure returns
-- (nil, reason, info with stage="storage"). Notify failure/defer keeps the
-- saved id and info.stage="notify"; it is never a delivery success claim.
function M.queue(self, name, parent, task)
  if type(task) ~= "string" or task == "" then
    return nil, "empty_task", { saved = false, stage = "input" }
  end
  if not self or type(self.queue_message) ~= "function"
      or type(self.mail_address) ~= "function" then
    return nil, "mail_unavailable", { saved = false, stage = "input" }
  end
  local from, to = self.mail_address(parent or "butler"), self.mail_address(name)
  local queued, message, err = pcall(self.queue_message, from, to, task, "Task")
  if not (queued and type(message) == "table" and message.id) then
    return storage_failure(self, name, parent,
      clean(queued and (err or "no message id") or message))
  end
  trace(self, "first_task_native_mail", name .. " message=" .. tostring(message.id))
  local info = { saved = true, message = message, stage = "notify" }
  if type(self.notify) == "function" then
    local called, returned, reason = pcall(self.notify,
      { from = from, to = to, text = task, subject = "Task" }, message)
    info.notice, info.notice_error = notify_status(called, returned, reason)
  else
    info.notice, info.notice_error = "unavailable", "notify seam missing"
  end
  if info.notice ~= "attempted" then
    notify_failure(self, name, parent, message, info.notice_error)
  end
  return message.id, nil, info
end

remuda = remuda or {}
remuda.butler = remuda.butler or {}
remuda.butler.native_task = M
return M
