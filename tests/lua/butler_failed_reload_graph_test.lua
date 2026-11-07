-- Private-daemon failed-reload barriers: the notification graph must keep its
-- last-good policy/dispatch/notice owner, the exact root instance, durable
-- facts and its registered resources, while a stale candidate callback stays
-- unpublished and unused.
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
    local function registrations()
      local hooks, schedules = 0, 0
      for _, rows in pairs(remuda.hooks) do
        for _, hook in ipairs(rows) do
          if hook.owner == "butler" or hook.group == "remuda-module:butler" then
            hooks = hooks + 1
          end
        end
      end
      for _, schedule in pairs(remuda.schedules) do
        if schedule.owner == "butler" and schedule.name ~= "butler-start-fallback" then
          schedules = schedules + 1
        end
      end
      return hooks .. ":" .. schedules
    end
    local function bytes(path)
      local file = io.open(path, "rb")
      if not file then return "<absent>" end
      local text = file:read("*a")
      file:close()
      return text
    end
    -- Durable facts only: identities, pending tasks, mail, delivery journal.
    -- Runtime handles and diagnostics are deliberately absent.
    local function durable()
      local bus = remuda._butler_bus or {}
      local agents, pending = {}, {}
      for name, agent in pairs(bus.agents or {}) do
        agents[#agents + 1] = name .. ":" .. tostring(agent.id) .. ":" .. tostring(agent.kind)
      end
      for name in pairs(bus.pending_tasks or {}) do pending[#pending + 1] = name end
      table.sort(agents)
      table.sort(pending)
      local data = remuda._butler_paths.data_home .. "/remuda/butler"
      local parts = { table.concat(agents, ","), table.concat(pending, ","),
        bytes(data .. "/agents.jsonl"), bytes(data .. "/roster.json"),
        bytes(data .. "/delivery-journal") }
      local mail = remuda._butler_paths.mail_root
      if mail then
        local pipe = io.popen("find '" .. mail .. "' -type f 2>/dev/null | sort")
        if pipe then
          for path in pipe:lines() do
            parts[#parts + 1] = path:sub(#mail) .. "=" .. bytes(path)
          end
          pipe:close()
        end
      end
      return table.concat(parts, "\n")
    end
    local HELPER_KEYS = { "_butler_notify", "_butler_inbox_delivery",
      "_butler_schedule_tick", "_butler_schedule_env",
      "_butler_cancel_active_choosers" }
    local function helpers()
      local captured = {}
      for _, key in ipairs(HELPER_KEYS) do captured[key] = remuda[key] end
      return captured
    end
    local before
    local function baseline()
      return remuda.butler.send_policy, remuda.butler.native_dispatch, remuda._butler_notice
    end
    local function assert_restored(policy, dispatch, notice, barrier, facts, registered, helper_set)
      assert(remuda.butler.send_policy == policy, barrier .. ": policy identity")
      assert(remuda.butler.native_dispatch == dispatch, barrier .. ": dispatch identity")
      assert(remuda._butler_notice == notice, barrier .. ": notice identity")
      assert(instance() == before, barrier .. ": root instance changed "
        .. tostring(before) .. " -> " .. tostring(instance()))
      assert(registrations() == registered,
        barrier .. ": registrations " .. registered .. " -> " .. registrations())
      assert(durable() == facts, barrier .. ": durable facts changed")
      for key, value in pairs(helper_set) do
        assert(remuda[key] == value, barrier .. ": helper " .. key .. " changed")
      end
      local help = remuda._dispatch_extension_command("butler", {"doctor", "--help"}, {})
      assert(tostring(help):find("Usage:", 1, true), barrier .. ": commands lost")
      -- The restored current callback is the one the runtime uses, exactly once.
      local seen = remuda._current_calls
      assert(remuda.butler.send_policy.readiness == policy.readiness,
        barrier .. ": current callback not restored")
      local again = assert(remuda.butler.send_policy.readiness(), barrier .. ": readiness")
      assert(remuda._current_calls == seen + 1, barrier .. ": current callback count "
        .. tostring(seen) .. " -> " .. tostring(remuda._current_calls))
      assert(again.owner == notice and again.bound == true
        and again.transport_acquired == true, barrier .. ": callback contents")
      -- A stale candidate callback is never published and never called.
      assert(remuda._stale_calls == nil or remuda._stale_calls == 0,
        barrier .. ": stale candidate callback ran")
      if remuda._stale_readiness then
        assert(remuda.butler.send_policy.readiness ~= remuda._stale_readiness,
          barrier .. ": stale callback is the live one")
      end
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
      -- published a stale callback, before the module load can finish.
      { name = "policy-post", file = "send_policy.lua", build = function(source)
        return inject(source, "\nreturn M%s*$",
          "\nremuda._stale_calls = 0\nlocal backed = M.readiness\n" ..
          "remuda._stale_readiness = function()\n" ..
          "  remuda._stale_calls = remuda._stale_calls + 1\n" ..
          "  return backed()\n" ..
          "end\nM.readiness = remuda._stale_readiness\n" ..
          "error('barrier: policy-post')\nreturn M")
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

    before = assert(instance(), "root instance")
    local policy = remuda.butler.send_policy
    local base_readiness = assert(policy.readiness)
    remuda._current_calls = 0
    policy.readiness = function()
      remuda._current_calls = remuda._current_calls + 1
      return base_readiness()
    end
    local registered, facts = registrations(), durable()
    local helper_set = helpers()

    for _, barrier in ipairs(barriers) do
      local current, dispatch, notice = baseline()
      local source = read(barrier.file)
      local broken = barrier.build(source)
      write(barrier.file, broken)
      local ok, err = pcall(remuda._load_extension_command, "butler", "butler", true)
      assert(not ok, barrier.name .. " did not fail")
      assert(tostring(err):find("barrier:", 1, true),
        barrier.name .. ": original error lost: " .. tostring(err))
      assert_restored(current, dispatch, notice, barrier.name, facts, registered, helper_set)
      write(barrier.file, source)
      remuda._load_extension_command("butler", "butler", true)
      local ready = assert(remuda.butler.send_policy.readiness())
      assert(ready.owner == remuda._butler_notice and ready.bound == true
        and ready.transport_acquired == true, barrier.name .. ": corrected readiness")
      assert(instance() == before, barrier.name .. ": corrected root instance changed")
      assert(registrations() == registered,
        barrier.name .. ": corrected registrations " .. registered .. " -> " .. registrations())
      assert(durable() == facts, barrier.name .. ": corrected durable facts changed")
      -- A corrected reload publishes its own current callback, not the stale one.
      if barrier.name == "policy-post" then
        assert(remuda.butler.send_policy.readiness ~= remuda._stale_readiness,
          barrier.name .. ": stale callback republished")
        assert(remuda._stale_calls == 0, barrier.name .. ": stale callback ran after repair")
      end
    end
    return "barriers ok"
  ]])
  T.eq(result, "barriers ok")
end)
