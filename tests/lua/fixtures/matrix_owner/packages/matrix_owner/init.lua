-- Real lifecycle owner for the Matrix request client. start execs the module
-- under this activation so the core stamps both request timers with
-- owner="matrix_owner"; the captured client handle survives a failed reload's
-- shared-table overwrite because resume uses the exact compiled closure.
local host = getmetatable(_G).__index.remuda
local client
return {
  api = "remuda-module-v1", state_version = 1,
  initialize = function() return {} end,
  start = function()
    local owner = assert(host._mq_owner, "test must seed host._mq_owner")
    host.exec("butler/matrix_request")
    local matrix = assert(host.butler.matrix)
    client = { retire = matrix.request_retire, resume = matrix.request_resume }
    host._butler_matrix_config = owner.config
    host.http.request = function(spec)
      local method = tostring(spec.method)
      if method == "GET" then owner.gets = owner.gets + 1 else owner.puts = owner.puts + 1 end
      local callback = spec.callback
      if type(callback) == "function" then
        callback({ status = 200, headers = {}, body = "{}" })
      end
      return { cancel = function() end }
    end
    owner.generation = (owner.generation or 0) + 1
    local generation = owner.generation
    matrix.request({ method = "GET", path = "/_matrix/client/versions" }, function(result)
      owner["first" .. generation] = result and not result.error or false
    end)
    if generation == 1 then
      matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
        function(result) owner.old = result end)
      owner.refill, owner.watchdog, owner.ticks = nil, nil, {}
      for handle, spec in pairs(host.schedules or {}) do
        if spec.name == "matrix-request-refill" then
          owner.refill = handle; owner.ticks[#owner.ticks + 1] = spec.run
        elseif spec.name == "matrix-request-watchdog" then
          owner.watchdog = handle; owner.ticks[#owner.ticks + 1] = spec.run
        end
      end
    end
  end,
  stop = function()
    local owner = host._mq_owner
    owner.stop_calls = (owner.stop_calls or 0) + 1
    if client and type(client.retire) == "function" then pcall(client.retire) end
  end,
  resume = function()
    local owner = host._mq_owner
    owner.resume_calls = (owner.resume_calls or 0) + 1
    if client and type(client.resume) == "function" then pcall(client.resume) end
  end,
}
