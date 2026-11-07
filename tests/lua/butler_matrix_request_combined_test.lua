-- Actual Butler module path: a lone queued Matrix request whose refill and
-- watchdog timers are both dead must settle once at generation teardown, and
-- rollback must serve a fresh read through the retained captured client
-- without replaying the retired request or dispatching another generation.
T.test("actual Butler teardown settles a lone queued request once", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  local paths = T.eval([[
    local config_path, token_path = os.tmpname(), os.tmpname()
    local f = assert(io.open(config_path, "w"))
    f:write("http://matrix.invalid\n!room:example.org\n@bot:example.org\n")
    f:close()
    f = assert(io.open(token_path, "w"))
    f:write("token")
    f:close()
    remuda._mq_paths = { config_path, token_path }
    remuda._butler_argv = {"sh", "-c", "sleep 60"}
    remuda._butler_skip_relay = true
    remuda._butler_readiness_timeout = 1
    remuda.exec("butler")
    return config_path .. "\n" .. token_path
  ]])
  T.ok(type(paths) == "string" and paths ~= "", "matrix fixture paths")
  T.wait_until(function()
    return T.eval('return remuda._butler_bus and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "butler root")

  local result = T.eval([[
    local function instance()
      for _, row in ipairs(remuda.ls()) do
        if row.name == "butler" and row.alive then return row.instance_id end
      end
    end
    local before = assert(instance(), "root instance")
    local cfg = assert(remuda._mq_paths, "matrix fixture paths")
    remuda._butler_matrix_config = { config_path = cfg[1], token_path = cfg[2] }
    if type(remuda.http) ~= "table" then remuda.http = {} end
    local real_http = remuda.http.request
    local mq = { dispatched = 0, retired = 0, paths = {} }
    remuda._mq_actual = mq
    remuda.http.request = function(spec)
      mq.dispatched = mq.dispatched + 1
      mq.paths[#mq.paths + 1] = tostring(spec.path)
      local callback = spec.callback
      if type(callback) == "function" then
        callback({ status = 200, headers = {}, body = "{}" })
      end
      return { cancel = function() end }
    end
    local matrix = assert(remuda.butler and remuda.butler.matrix, "matrix missing")
    assert(type(matrix.request_json) == "function", "request_json missing")
    -- The first request consumes the initial credit and completes.
    matrix.request_json({ method = "GET", path = "/_matrix/client/versions" },
      function(value)
        mq.first = value and value.status or nil
        mq.first_error = value and value.error or nil
      end)
    local early = remuda._butler_matrix_request_state()
    assert(mq.dispatched == 1, "initial request did not dispatch: "
      .. tostring(mq.dispatched) .. " queued=" .. tostring(early and early.queued)
      .. " retired=" .. tostring(early and early.retired)
      .. " timer=" .. tostring(early and early.timer ~= nil)
      .. " error=" .. tostring(mq.first_error))
    -- The second has no credit and is the lone queued item.
    matrix.request_json({ method = "GET", path = "/_matrix/client/v3/account/whoami" },
      function(value)
        mq.retired = mq.retired + 1
        mq.retired_value = value
      end)
    local state = assert(remuda._butler_matrix_request_state(),
      "real core lacks the Matrix request seam")
    assert(state.queued == 1, "lone request did not queue: " .. tostring(state.queued))
    assert(state.timer and state.watchdog, "both timers were not armed")
    -- Kill both timers: the lone queued item now has no refill and no watchdog.
    remuda.cancel(state.timer)
    remuda.cancel(state.watchdog)
    -- A failed activation retires the captured generation; rollback resumes it.
    local root = os.getenv("XDG_DATA_HOME")
      .. "/remuda/mods/butler/packages/butler/send_policy.lua"
    local file = assert(io.open(root, "r"))
    local source = file:read("*a")
    file:close()
    file = assert(io.open(root, "w"))
    file:write((source:gsub("\nreturn M%s*$",
      "\nerror('combined teardown barrier')\nreturn M")))
    file:close()
    local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
    file = assert(io.open(root, "w"))
    file:write(source)
    file:close()
    assert(not ok and tostring(err):find("combined teardown barrier", 1, true),
      "candidate did not fail: " .. tostring(err))
    assert(instance() == before, "rollback changed the root instance")
    -- The lone request settled terminally exactly once, with no dispatch.
    assert(mq.retired == 1, "lone request settle count: " .. tostring(mq.retired))
    assert(type(mq.retired_value) == "table"
      and mq.retired_value.queue_retired == true
      and mq.retired_value.not_sent == true, "wrong retirement result")
    assert(mq.dispatched == 1, "retired request was dispatched: " .. tostring(mq.dispatched))
    assert(remuda._butler_request_retire_failed == nil,
      "retire reported a failure: " .. tostring(remuda._butler_request_retire_failed))
    -- The rollback republishes a usable captured client; a fresh read answers.
    matrix = assert(remuda.butler and remuda.butler.matrix)
    matrix.request_json({ method = "GET", path = "/_matrix/client/versions" },
      function(value) mq.fresh = value and value.status or nil end)
    remuda.http.request = real_http
    return "started"
  ]])
  T.eq(result, "started")

  T.wait_until(function()
    return T.eval("return tostring(remuda._mq_actual.fresh)") == "200"
  end, 10, "fresh read after rollback answers")

  local final = T.eval([[
    local mq = assert(remuda._mq_actual)
    return table.concat({ tostring(mq.dispatched), tostring(mq.retired),
      tostring(mq.fresh), tostring(mq.paths[#mq.paths]) }, "|")
  ]])
  T.eq(final, "2|1|200|/_matrix/client/versions",
    "one initial dispatch, one terminal settle, one fresh read, no replay")
end)
