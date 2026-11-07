T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
-- Real-core scheduler proof: the refill timer may be canceled (as a failed
-- resume would) while the watchdog survives, and a lone queued request must
-- still recover without another enqueue. No network: only remuda.http.request
-- is replaced; remuda.schedule/remuda.clock are the real core primitives.
T.test("a lone Matrix request recovers when only the refill timer is retired", function()
  local paths = T.eval([[
    local config_path, token_path = os.tmpname(), os.tmpname()
    local f = assert(io.open(config_path, "w"))
    f:write("http://matrix.invalid\n!room:example.org\n@bot:example.org\n")
    f:close()
    f = assert(io.open(token_path, "w"))
    f:write("token")
    f:close()
    remuda.butler = remuda.butler or {}
    remuda.butler.matrix = remuda.butler.matrix or {}
    remuda._butler_matrix_config = { config_path = config_path, token_path = token_path }
    remuda._mq = { dispatched = 0, first = false, second = false,
      config_path = config_path, token_path = token_path }
    remuda._mq.real_http = remuda.http.request
    remuda.http.request = function(spec)
      remuda._mq.dispatched = remuda._mq.dispatched + 1
      local callback = spec.callback
      if type(callback) == "function" then
        callback({ status = 200, headers = {}, body = "{}" })
      end
      return { cancel = function() end }
    end
    remuda.exec("butler/matrix_request")
    local matrix = assert(remuda.butler.matrix)
    matrix.request_json({ method = "GET", path = "/_matrix/client/versions" },
      function(result) remuda._mq.first = result and not result.error or false end)
    matrix.request_json({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
      function(result) remuda._mq.second = result and not result.error or false end)
    local refill
    for handle, spec in pairs(remuda.schedules or {}) do
      if type(spec) == "table" and spec.name == "matrix-request-refill" then refill = handle end
    end
    assert(refill, "real core armed a refill timer")
    remuda.cancel(refill)
    return table.concat({ config_path, token_path }, "\n")
  ]])
  T.ok(type(paths) == "string" and paths ~= "", "fixture paths")
  T.wait_until(function()
    return T.eval([[
      return tostring(remuda._mq.second == true and remuda._mq.dispatched == 2)
    ]]):match("^%s*true%s*$") ~= nil
  end, 10, "watchdog recovers the lone queued request")
  local result = T.eval([[
    local refills, watchdogs = 0, 0
    for _, spec in pairs(remuda.schedules or {}) do
      if type(spec) == "table" and spec.name == "matrix-request-refill" then refills = refills + 1 end
      if type(spec) == "table" and spec.name == "matrix-request-watchdog" then watchdogs = watchdogs + 1 end
    end
    return table.concat({ tostring(remuda._mq.first), tostring(remuda._mq.second),
      tostring(remuda._mq.dispatched), tostring(refills), tostring(watchdogs) }, "|")
  ]])
  T.eq(result, "true|true|2|0|0", "one dispatch each, timers retire after the queue drains")
  T.eval([[
    if remuda._mq and remuda._mq.real_http then remuda.http.request = remuda._mq.real_http end
    for _, path in ipairs({ remuda._mq and remuda._mq.config_path,
        remuda._mq and remuda._mq.token_path }) do
      if type(path) == "string" then pcall(os.remove, path) end
    end
  ]])
end)
