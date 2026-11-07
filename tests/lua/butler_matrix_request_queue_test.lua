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
    -- The returned handle is not a registry key on real cores; the test seam
    -- exposes the exact handle this generation armed.
    local state = assert(remuda._butler_matrix_request_state(),
      "real core lacks the Matrix request test seam")
    assert(state.timer, "real core armed a refill timer")
    remuda.cancel(state.timer)
    return table.concat({ config_path, token_path }, "\n")
  ]])
  T.ok(type(paths) == "string" and paths ~= "", "fixture paths")
  T.wait_until(function()
    return T.eval([[
      return tostring(remuda._mq.second == true and remuda._mq.dispatched == 2)
    ]]):match("^%s*true%s*$") ~= nil
  end, 10, "watchdog recovers the lone queued request")
  local result = T.eval([[
    local state = assert(remuda._butler_matrix_request_state())
    return table.concat({ tostring(remuda._mq.first), tostring(remuda._mq.second),
      tostring(remuda._mq.dispatched), tostring(state.timer == nil),
      tostring(state.watchdog == nil), tostring(state.queued == 0) }, "|")
  ]])
  T.eq(result, "true|true|2|true|true|true",
    "one dispatch each, timers retire after the queue drains")
  T.eval([[
    if remuda._mq and remuda._mq.real_http then remuda.http.request = remuda._mq.real_http end
    for _, path in ipairs({ remuda._mq and remuda._mq.config_path,
        remuda._mq and remuda._mq.token_path }) do
      if type(path) == "string" then pcall(os.remove, path) end
    end
  ]])
end)
