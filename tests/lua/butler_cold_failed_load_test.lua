-- Cold first-load failure: the candidate dies after consuming its own policy
-- factory; a corrected same-daemon load must rebuild a fresh bundle and start
-- the exact root, without reusing the failed candidate factory.
T.test("cold failed load retries with a fresh candidate", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  local err = T.eval([[
    local root = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/"
    local function read(name)
      local file = assert(io.open(root .. name, "r"))
      local source = file:read("*a")
      file:close()
      return source
    end
    local function write(name, source)
      local file = assert(io.open(root .. name, "w"))
      file:write(source)
      file:close()
    end
    local source = read("send_policy.lua")
    write("send_policy.lua", (source:gsub("\nreturn M%s*$",
      "\nerror('cold barrier after policy install')\nreturn M")))
    local ok, why = pcall(remuda.exec, "butler")
    write("send_policy.lua", source)
    assert(not ok, "cold load did not fail")
    return tostring(why)
  ]])
  T.ok(tostring(err):find("cold barrier after policy install", 1, true),
    "original cold error lost: " .. tostring(err))

  T.eval([[
    remuda._butler_argv = {"sh", "-c", "sleep 60"}
    remuda._butler_skip_relay = true
    remuda._butler_readiness_timeout = 1
    remuda.exec("butler")
  ]])
  T.wait_until(function()
    return T.eval('return remuda._butler_bus and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "corrected cold root")

  local ready = T.eval([[
    local policy = remuda.butler.send_policy
    if type(policy) ~= "table" or type(policy.readiness) ~= "function" then return "no-policy" end
    local ready = policy.readiness()
    return tostring(ready.owner == remuda._butler_notice and ready.bound == true
      and ready.transport_acquired == true)
  ]])
  T.eq(ready, "true")
end)
