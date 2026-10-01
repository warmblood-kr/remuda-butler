-- The owner-facing text for "no agent could start": one line per failed
-- attempt, built from the kind and the reason only. The attempt's screen
-- detail is never read here, so prompt text cannot reach a Matrix room.
-- Check: luajit tests/launch_notice.lua
local M = {}

local HEAD = "Butler could not start an agent on this machine."
local TAIL = "Butler keeps retrying; no restart is needed after the fix."
local DOCTOR = "remuda butler doctor"
local LOGIN = { claude = "claude auth login", codex = "codex login" }
local MAX_ATTEMPT_LINES = 8

-- reason -> what happened, and what to do next for that kind.
local REASONS = {
  login = { "not logged in", function(kind) return LOGIN[kind] or DOCTOR end },
  dialog = { "stopped at a startup dialog", function(kind)
    return "run " .. kind .. " in a terminal on this machine and answer the dialog"
  end },
  timeout = { "did not become ready in time" },
  exited = { "exited before it was ready" },
  spawn_error = { "could not be started" },
  not_found = { "not installed" },
}
local OTHER = { "did not start" }

-- The kind comes from the operator's agent order; print it only when it is
-- plainly a name.
local function safe_kind(kind)
  if type(kind) == "string" and #kind >= 1 and #kind <= 32 and not kind:find("[^%w_.%-]") then
    return kind
  end
  return "agent"
end

local function failed(attempts)
  local list = {}
  for _, attempt in ipairs(attempts or {}) do
    if type(attempt) == "table" and attempt.reason ~= "ready" then list[#list + 1] = attempt end
  end
  return list
end

-- The notice for these attempts, or nil when none of them failed.
function M.text(attempts)
  local list = failed(attempts)
  if #list == 0 then return nil end
  local lines = { HEAD }
  for index, attempt in ipairs(list) do
    if index > MAX_ATTEMPT_LINES then
      lines[#lines + 1] = "and " .. (#list - MAX_ATTEMPT_LINES) .. " more"
      break
    end
    local kind = safe_kind(attempt.kind)
    local entry = REASONS[attempt.reason] or OTHER
    local next_step = entry[2] and entry[2](kind) or DOCTOR
    lines[#lines + 1] = kind .. ": " .. entry[1] .. ". Next: " .. next_step
  end
  lines[#lines + 1] = TAIL
  return table.concat(lines, "\n")
end

-- What makes two failures "the same" for dedupe: kinds and reasons, in order.
function M.signature(attempts)
  local parts = {}
  for _, attempt in ipairs(failed(attempts)) do
    parts[#parts + 1] = safe_kind(attempt.kind) .. "=" .. (REASONS[attempt.reason] and attempt.reason or "other")
  end
  return table.concat(parts, ",")
end

if type(remuda) == "table" then
  remuda.butler = remuda.butler or {}
  remuda.butler.launch_notice = M
end
return M
