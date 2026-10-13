-- #460: exercise Codex's actual launch confirmation callbacks with fake screens,
-- without starting an agent or depending on scheduler timing.
T.test("Codex first task refuses replacement collapsed pastes after the human pauses", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "Butler root ready")
  T.eq(T.eval([[
    local bus = remuda._butler_bus
    local task = "START complete delegated task\nsecond task line"
    local chooser = remuda._butler_chooser
    local polls, composer, writes, returns, paused = {}, "", 0, 0, false
    local name, paste = "paste-member", "[Pasted text #1 +2 lines]"
    chooser.choose = function(_, opts, done) done(opts.name, "codex", {}, "fake-instance") end
    chooser.instance_live = function() return true end
    remuda._butler_agent_startup.codex = { ready = function() return true end }
    remuda.schedule = function(spec)
      -- Drive task delivery only; independent observers do not own this fixture.
      if spec.every == 0.5 then polls[#polls + 1] = spec end
      return spec
    end
    remuda.cancel = function(spec) spec.cancelled = true end
    remuda.ls = function() return {{ name = name, alive = true }} end
    remuda.capture = function() return "› " .. composer end
    remuda._butler_composer_decision = function()
      return composer == "" and "EMPTY" or "NON-EMPTY", composer
    end
    remuda._butler_notify_policy = function() return true end
    remuda._butler_task_retry_policy = function() return paused end
    remuda.session = function() return { is_busy = false } end
    remuda.type_text = function(_, text)
      assert(text == task); writes = writes + 1
      composer = task
      return true
    end
    local reports = {}
    remuda._butler_send = function(_, _, text) reports[#reports + 1] = text end
    remuda.key = function(_, key)
      assert(key == "RET"); assert(paused, "Return sent while human active")
      returns = returns + 1; composer = ""
    end
    remuda.exec("butler/launch") -- bind the fake chooser, keeping the production callbacks
    remuda._butler_launch_impl.launch_agent("codex", "paste-member",
      os.getenv("XDG_DATA_HOME"), nil, "butler", task)
    assert(#polls == 1, "first-task poll missing")
    polls[1].run()
    assert(writes == 1 and #polls == 2, "confirmation poll missing: writes=" .. writes
      .. " polls=" .. #polls .. " state=" .. bus.first_task_delivery["paste-member"].state)
    polls[2].run() -- seeing the original task does not own a later paste
    composer = paste -- human replaces the pending task with an opaque paste
    for _ = 1, 4 do if not polls[2].cancelled then polls[2].run() end end
    assert(returns == 0, "human pause guard ignored")
    paused = true
    for _ = 1, 4 do if not polls[2].cancelled then polls[2].run() end end
    assert(returns == 0, "replacement collapsed paste submitted")
    assert(bus.first_task_delivery[name].state == "failed", "opaque paste not failed closed")
    assert(bus.agents[name].task == task, "original task not preserved")
    assert(reports[#reports]:find("Could not verify delivery", 1, true)
      and reports[#reports]:find(task, 1, true), "original resend not reported")
    assert(writes == 1 and polls[2].cancelled, "task duplicated or poll left running")
    for index, text in ipairs({ "[Pasted Content 2048 chars]", task,
        "START complete delegated task\nsecond task line HUMAN follow-up",
        "START complete delegated" }) do
      name, paste = "paste-case-" .. index, text
      polls, composer, writes, returns, paused = {}, "", 0, 0, true
      remuda._butler_launch_impl.launch_agent("codex", name,
        os.getenv("XDG_DATA_HOME"), nil, "butler", task)
      polls[1].run()
      if index == 2 then
        paused = false
        for _ = 1, 4 do polls[2].run() end
        assert(returns == 0, "visible task ignored human pause guard")
        paused = true
      end
      composer = paste
      for _ = 1, 4 do if not polls[2].cancelled then polls[2].run() end end
      if index == 2 then
        assert(returns == 1, "complete visible task not submitted")
        polls[2].run()
        assert(bus.first_task_delivery[name].state == "delivered", "submission not confirmed")
      elseif index == 1 then
        assert(returns == 0, "replacement Content paste submitted")
        assert(bus.first_task_delivery[name].state == "failed", "opaque Content paste not failed")
        assert(bus.agents[name].task == task, "original task not preserved")
      else
        assert(returns == 0, "mixed or partial composer submitted")
        assert(bus.first_task_delivery[name].state == "waiting", "draft marked delivered")
      end
      assert(writes == 1, "whole task pasted twice")
    end
    return "ok"
  ]]), "ok")
end)
