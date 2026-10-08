-- `remuda butler status-hook STATUS_PATH`: the target of Claude Code's
-- UserPromptSubmit/Stop/Notification hooks. It reads the hook JSON on stdin and
-- writes `<word> <unix time>` to `STATUS_PATH.state`; hook text is never kept.
-- The path rule is statusline's: absolute and ending in `.status`.
local M = {}

local NOTIFICATION = { permission_prompt = "needs you", elicitation_dialog = "needs you", idle_prompt = "idle" }
local EVENTS = { UserPromptSubmit = "working", Stop = "idle" }

-- One fixed word for a decoded hook payload, or nil to ignore it. A
-- Notification without a type (older Claude Code) counts as needs-you.
function M.word(hook)
  if type(hook) ~= "table" then return nil end
  local event = hook.hook_event_name
  if event == "Notification" then
    if hook.notification_type == nil then return "needs you" end
    return NOTIFICATION[hook.notification_type]
  end
  return EVENTS[event]
end

function M.run(args, caller)
  local principal = remuda._butler_caller_principal and remuda._butler_caller_principal.resolve(caller)
  if not principal or principal.tag ~= "member" then
    return "Butler cannot identify this caller for status telemetry. Next: run from a registered Butler session or upgrade Remuda core."
  end
  local path, input = args[2], caller and caller.stdin
  local absolute = type(path) == "string" and (path:sub(1, 1) == "/" or path:sub(1, 2) == "\\\\"
    or (path:match("^%a:") ~= nil and (path:sub(3, 3) == "/" or path:sub(3, 3) == "\\")))
  -- A "." or ".." component would let the written file land beside another status file.
  local plain = absolute and not ("/" .. path:gsub("\\", "/") .. "/"):find("/%.%.?/")
  if plain and path == principal.status_path and path:match("%.status$") and type(input) == "string" then
    local decoded_ok, decoded = pcall(remuda.json.decode, input)
    local word = decoded_ok and M.word(decoded)
    if word then
      pcall(remuda.fs.write_atomic, path .. ".state", word .. " " .. string.format("%d", os.time()) .. "\n",
        { private = true })
    end
  end
  return "" -- exit 0 always; the hook command also discards stdout
end

remuda.butler = remuda.butler or {}
remuda.butler.status_hook = M
return M
