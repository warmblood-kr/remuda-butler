-- #452: inspect production candidate specs without launching agent CLIs.
T.test("fallback candidates and roster use their own model defaults", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
  end, 5, "Butler root ready")
  T.eq(T.eval([[
    local chooser = remuda._butler_chooser
    local bus = remuda._butler_bus
    remuda._butler_claude_default_model = "sonnet"
    remuda._butler_codex_default_model = nil
    remuda._butler_compaction_config = {}
    chooser.configured_agent_order = function() return { "claude", "codex" } end
    chooser.instance_live = function() return true end
    chooser.setup_telemetry = function(_, spec) return { model = spec.model } end
    chooser.choose = function(candidates, opts, done)
      assert(candidates[1] == "claude" and candidates[2] == "codex")
      assert(opts.spec("claude").model == "sonnet", "Claude default lost")
      assert(opts.spec("codex").model == nil, "Codex inherited Claude model")
      done(opts.name, "codex", {}, "fake-instance")
    end
    remuda.exec("butler/launch")
    remuda._butler_launch_impl.launch_agent(nil, "default-fallback", os.getenv("XDG_DATA_HOME"), nil, "butler")
    assert(bus.agents["default-fallback"].model == nil, "roster retained Claude model")
    assert(bus.agents["default-fallback"].telemetry.model == nil, "telemetry retained Claude model")
    remuda._butler_codex_default_model = "gpt-6-luna"
    chooser.choose = function(_, opts, done)
      assert(opts.spec("codex").model == "gpt-6-luna", "Codex default ignored")
      assert(opts.spec("claude").model == "sonnet", "Claude default changed")
      done(opts.name, "codex", {}, "fake-instance")
    end
    remuda.exec("butler/launch")
    remuda._butler_launch_impl.launch_agent(nil, "configured-fallback", os.getenv("XDG_DATA_HOME"), nil, "butler")
    assert(bus.agents["configured-fallback"].model == "gpt-6-luna", "selected model not recorded")
    local spawned = false
    chooser.choose = function() spawned = true end
    remuda.exec("butler/launch")
    local ok, why = pcall(remuda._butler_launch_impl.launch_agent,
      "codex", "wrong-model", os.getenv("XDG_DATA_HOME"), "opus", "butler")
    assert(not ok and tostring(why):find("--model", 1, true), "known model mismatch accepted")
    assert(not spawned and bus.agents["wrong-model"] == nil, "mismatch started a pane")
    local polls, rejected = {}, false
    chooser.choose = function(_, opts, done) done(opts.name, "codex", {}, "fake-instance") end
    remuda.schedule = function(spec) polls[#polls + 1] = spec; return spec end
    remuda.cancel = function(spec) spec.cancelled = true end
    remuda.ls = function() return {{ name = "model-error", alive = true,
      instance_id = "fake-instance" }} end
    remuda.capture = function()
      return rejected and 'The "gpt-custom" model is not supported when using Codex with a ChatGPT account.'
        or "› Ask Codex to do anything"
    end
    local task = "Read and follow the assigned task"
    remuda.exec("butler/launch")
    remuda._butler_launch_impl.launch_agent("codex", "model-error",
      os.getenv("XDG_DATA_HOME"), "gpt-custom", "butler", task)
    assert(#polls >= 2, "early model-rejection monitor missing")
    rejected = true
    polls[#polls].run()
    assert(bus.launch_failures["model-error"], "model rejection absent from FAILED LAUNCHES")
    assert(bus.first_task_delivery["model-error"].state == "failed", "task delivery not stopped")
    local kept, warned = false, false
    for _, message in pairs(bus.messages) do
      local content = bus.objects[message.body.object_id].content
      if message.to[1].id == bus.agents["model-error"].id and content == task then kept = true end
      if message.to[1].id == bus.agents.butler.id and content:find("--model", 1, true) then warned = true end
    end
    assert(kept and warned, "rejected task or actionable leader warning missing")
    assert(chooser.model_rejection('› The "opus" model is not supported') == nil,
      "composer text classified as a model error")
    assert(chooser.model_rejection("Error: model_not_found: model does not exist"),
      "model-not-found error missed")
    assert(chooser.model_rejection("Error: ordinary network failure") == nil,
      "unrelated error classified as model rejection")
    polls = {}
    remuda._butler_launch_impl.launch_agent("codex", "replaced-model",
      os.getenv("XDG_DATA_HOME"), "gpt-custom", "butler")
    bus.agents["replaced-model"] = { session_start_marker = "replacement" }
    polls[#polls].run()
    assert(polls[#polls].cancelled and bus.launch_failures["replaced-model"] == nil,
      "model observer reported another incarnation")
    return "ok"
  ]]), "ok")
end)
