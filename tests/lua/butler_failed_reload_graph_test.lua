-- Private-daemon failed-reload barriers: the notification graph must keep its
-- last-good policy/dispatch/notice owner and the exact root instance.
T.test("failed reload barriers preserve the last-good notification graph", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval([[
    remuda._butler_argv = {"sh", "-c", "sleep 60"}
    remuda._butler_skip_relay = true
    remuda._butler_readiness_timeout = 1
    remuda.exec("butler")
  ]])
  T.wait_until(function()
    return T.eval('return remuda._butler_bus and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "root start")

  local result = T.eval([[
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
    local function instance()
      for _, row in ipairs(remuda.ls()) do
        if row.name == "butler" and row.alive then return row.instance_id end
      end
    end
    local before = assert(instance(), "root instance")
    local function baseline()
      return remuda.butler.send_policy, remuda.butler.native_dispatch, remuda._butler_notice
    end
    local function assert_restored(policy, dispatch, notice, barrier)
      assert(remuda.butler.send_policy == policy, barrier .. ": policy identity")
      assert(remuda.butler.native_dispatch == dispatch, barrier .. ": dispatch identity")
      assert(remuda._butler_notice == notice, barrier .. ": notice identity")
      local ready = assert(policy.readiness(), barrier .. ": readiness")
      assert(ready.owner == notice and ready.bound == true
        and ready.transport_acquired == true, barrier .. ": readiness contents")
      assert(instance() == before, barrier .. ": root instance changed")
      local help = remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {})
      assert(tostring(help):find("Usage:", 1, true), barrier .. ": commands lost")
    end
    local function inject(source, pattern, replacement)
      local changed = source:gsub(pattern, replacement)
      assert(changed ~= source, "barrier pattern did not match")
      return changed
    end

    local barriers = {
      { name = "dispatch-pre", file = "native_dispatch.lua", build = function(source)
        return "error('barrier: dispatch-pre')\n" .. source
      end },
      { name = "policy-pre", file = "send_policy.lua", build = function(source)
        return "error('barrier: policy-pre')\n" .. source
      end },
      -- After the candidate policy consumed its own dispatch factory and
      -- published itself, but before the module load can finish.
      { name = "policy-post", file = "send_policy.lua", build = function(source)
        return inject(source, "\nreturn M%s*$", "\nerror('barrier: policy-post')\nreturn M")
      end },
      -- Candidate notice published, owner binding not yet attempted.
      { name = "notice-pre-bind", file = "notice.lua", build = function(source)
        return inject(source, "\nbind_send_policy%s*%(%s*%)%s*$",
          "\nerror('barrier: notice-pre-bind')\nbind_send_policy()")
      end },
      -- Candidate notice bound to the candidate policy, then failed.
      { name = "notice-post-bind", file = "notice.lua", build = function(source)
        return inject(source, "\nbind_send_policy%s*%(%s*%)%s*$",
          "\nbind_send_policy()\nerror('barrier: notice-post-bind')")
      end },
    }

    for _, barrier in ipairs(barriers) do
      local policy, dispatch, notice = baseline()
      local source = read(barrier.file)
      local broken = barrier.build(source)
      write(barrier.file, broken)
      local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
      assert(not ok, barrier.name .. " did not fail")
      assert(tostring(err):find("barrier:", 1, true), barrier.name .. ": original error lost: " .. tostring(err))
      assert_restored(policy, dispatch, notice, barrier.name)
      write(barrier.file, source)
      remuda._load_extension_command("butler", "butler", true)
      local ready = assert(remuda.butler.send_policy.readiness())
      assert(ready.owner == remuda._butler_notice and ready.bound == true
        and ready.transport_acquired == true, barrier.name .. ": corrected readiness")
      assert(instance() == before, barrier.name .. ": corrected root instance changed")
    end
    return "barriers ok"
  ]])
  T.eq(result, "barriers ok")
end)
