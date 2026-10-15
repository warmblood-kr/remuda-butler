-- Claude-specific interpretation of its captured screen.
local remuda = assert(_G.remuda)
local config = assert(remuda._butler_sessions_config)
local detectors = remuda._butler_session_status_detectors or {}
remuda._butler_session_status_detectors = detectors

detectors.claude = function(screen)
  local entry = config.registered_agent_kind("claude")
  if not (entry and type(entry.ready) == "function" and type(entry.working) == "function") then return "other" end
  local startup = (remuda._butler_agent_startup or {}).claude or {}
  local chooser = remuda._butler_chooser
  local modal_ok, modal = false, false
  if chooser and type(chooser.known_startup_modal) == "function" then
    modal_ok, modal = pcall(chooser.known_startup_modal, startup, screen)
  end
  if modal_ok and modal then return "needs you" end
  local working_ok, working = config.call_callback(entry.working, screen)
  if not working_ok then return "other" end
  if working then return "working" end
  local ready_ok, ready = config.call_callback(entry.ready, screen)
  return ready_ok and ready and "idle" or "other"
end
