-- Convert internal launch reasons into safe, actionable user-facing lines.
local function safe_kind(value)
  if type(value) == "string" and #value >= 1 and #value <= 32
      and value:match("^[%a%d_%.%-]+$") then
    return value
  end
  return "agent"
end

local function next_step(kind, reason)
  if reason == "login" then
    if kind == "claude" then return "claude auth login" end
    if kind == "codex" then return "codex login" end
    return "remuda butler doctor"
  end
  if reason == "dialog" then
    return "run " .. kind .. " in a terminal on this machine and answer the dialog"
  end
  return "remuda butler doctor"
end

local function reason_text(reason)
  if reason == "login" then return "not logged in" end
  if reason == "dialog" then return "stopped at a startup dialog" end
  if reason == "timeout" then return "did not become ready in time" end
  if reason == "exited" then return "exited before it was ready" end
  if reason == "spawn_error" then return "could not be started" end
  if reason == "not_found" then return "not installed" end
  return "did not start"
end

local function render(attempts)
  local lines = {}
  for _, attempt in ipairs(attempts or {}) do
    local kind = safe_kind(type(attempt) == "table" and attempt.kind or nil)
    local reason = type(attempt) == "table" and attempt.reason or nil
    lines[#lines + 1] = kind .. ": " .. reason_text(reason) .. ". Next: " .. next_step(kind, reason)
  end
  return lines
end

remuda.butler = remuda.butler or {}
remuda.butler.launch_failure_lines = render
return render
