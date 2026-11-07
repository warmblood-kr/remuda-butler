-- Cold first-load failure: the candidate dies after consuming its own policy
-- factory or after binding its notice; a corrected same-daemon load must
-- rebuild a fresh bundle and start the exact root, without reusing the failed
-- candidate factory.
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
    local barriers = {
      { file = "send_policy.lua", needle = "cold barrier after policy install",
        build = function(source)
          return (source:gsub("\nreturn M%s*$",
            "\nerror('cold barrier after policy install')\nreturn M"))
        end },
      { file = "notice.lua", needle = "cold barrier after notice bind",
        build = function(source)
          return source .. "\nerror('cold barrier after notice bind')\n"
        end },
    }
    for _, barrier in ipairs(barriers) do
      local source = read(barrier.file)
      local broken = barrier.build(source)
      assert(broken ~= source, "barrier pattern did not match: " .. barrier.file)
      write(barrier.file, broken)
      local ok, why = pcall(remuda.exec, "butler")
      write(barrier.file, source)
      assert(not ok, "cold load did not fail: " .. barrier.needle)
      assert(tostring(why):find(barrier.needle, 1, true),
        "original cold error lost: " .. tostring(why))
    end
    return "cold barriers ok"
  ]])
  T.eq(err, "cold barriers ok")

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

  -- A later failed candidate (after notice bind) keeps the live cold root.
  local kept = T.eval([[
    local function instance()
      for _, row in ipairs(remuda.ls()) do
        if row.name == "butler" and row.alive then return row.instance_id end
      end
    end
    local before = assert(instance(), "cold root instance")
    local root = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/notice.lua"
    local file = assert(io.open(root, "r"))
    local source = file:read("*a")
    file:close()
    file = assert(io.open(root, "w"))
    file:write(source .. "\nerror('cold barrier after notice bind')\n")
    file:close()
    local ok, why = pcall(remuda._load_extension_command, "butler", "butler", true)
    file = assert(io.open(root, "w"))
    file:write(source)
    file:close()
    assert(not ok, "post-root candidate did not fail")
    assert(tostring(why):find("cold barrier after notice bind", 1, true),
      "post-root original error lost: " .. tostring(why))
    remuda._load_extension_command("butler", "butler", true)
    assert(instance() == before, "corrected candidate changed the cold root")
    local ready = assert(remuda.butler.send_policy.readiness())
    assert(ready.owner == remuda._butler_notice and ready.bound == true
      and ready.transport_acquired == true, "cold root readiness lost")
    return "kept"
  ]])
  T.eq(kept, "kept")
end)
