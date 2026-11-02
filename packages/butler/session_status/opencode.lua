-- OpenCode-specific interpretation of its captured TUI screen.
local remuda = assert(_G.remuda)
local config = assert(remuda._butler_sessions_config)
local detectors = remuda._butler_session_status_detectors or {}
remuda._butler_session_status_detectors = detectors

detectors.opencode = function(screen)
  local entry = config.registered_agent_kind("opencode")
  if not (entry and type(entry.ready) == "function" and type(entry.working) == "function") then return "other" end
  local working_ok, working = config.call_callback(entry.working, screen)
  if not working_ok then return "other" end
  if working then return "working" end
  local ready_ok, ready = config.call_callback(entry.ready, screen)
  return ready_ok and ready and "idle" or "other"
end
