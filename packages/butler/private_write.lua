-- Report once when Butler asks a core to make a file private.
local state = remuda._butler_private_write_state or { warned = false }
remuda._butler_private_write_state = state

local M = {}
function M.install()
  local fs = remuda.fs
  if not fs or type(fs.write_atomic) ~= "function" then return false end
  if fs.write_atomic == state.wrapper then return true end
  local write_atomic = fs.write_atomic
  state.wrapper = function(path, text, options)
    if options and options.private == true and not state.warned then
      state.warned = true
      local message = "Butler requested private file writes, but this Remuda core does not report whether it enforces mode 0600; verify the core before treating Butler files as private."
      if type(remuda.log) == "function" then
        pcall(remuda.log, "warn", message)
      else
        pcall(function() io.stderr:write(message .. "\n") end)
      end
      local trace = remuda._butler_session_trace or _G._butler_session_trace
      if type(trace) == "function" then pcall(trace, "private_write_unverified") end
    end
    return write_atomic(path, text, options)
  end
  fs.write_atomic = state.wrapper
  return true
end

remuda._butler_private_write = M
return M
