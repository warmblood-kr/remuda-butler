-- Actual root/member spec paths, with a spawn-boundary stub: no agent is started.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval([[
  remuda._butler_argv = { "sh", "-c", "sleep 60" }
  remuda._butler_skip_relay = true
  remuda._coordination_spawns = {}
  remuda.new = function(name, argv, cwd)
    local report = remuda._butler_coordination_reports[remuda.fs.realpath(cwd)]
    assert(report and not report.error, "workdir must initialize before spawn")
    for _, rel in ipairs({ "/.claude/settings.local.json", "/.codex/config.toml", "/.codex/rules/remuda.rules" }) do
      local f = assert(io.open(cwd .. rel, "rb"), "both clients must exist before spawn")
      f:close()
    end
    remuda._coordination_spawns[#remuda._coordination_spawns + 1] = { cwd = cwd, kind = report.kind }
    error("fixture stops before starting an agent", 0)
  end
  remuda.exec("butler")
]])

T.test("root candidate specs initialize both clients before the spawn boundary", function()
  T.eq(T.eval([[
    local kinds = {}
    for _, row in ipairs(remuda._coordination_spawns) do kinds[row.kind] = true end
    return tostring(kinds.claude == true) .. "|" .. tostring(kinds.codex == true)
  ]]), "true|true", "both root fallback adapter specs must initialize before spawn")
  T.eq(T.eval([[
    local report = remuda._butler_root_coordination_report
    return tostring(report ~= nil and report.error == nil) .. "|" .. tostring(#report.written + #report.unchanged)
  ]]), "true|3", "root initialization did not plan both client configurations")
end)

T.test("topic delegation initializes its supplied cwd rather than only the topic directory", function()
  T.eq(T.eval([[
    local base = os.getenv("XDG_DATA_HOME") .. "/delegation-overrides"
    for _, kind in ipairs({ "claude", "codex" }) do
      local cwd = base .. "/" .. kind
      remuda.mkdir(cwd)
      remuda._butler_topic_delegate("fixture-topic-" .. kind, "fixture task", nil, kind, "butler", nil, cwd)
      local report = remuda._butler_coordination_reports[remuda.fs.realpath(cwd)]
      assert(report and report.kind == kind and not report.error and #report.written == 3)
    end
    return "both delegated cwd overrides initialized before spawn"
  ]]), "both delegated cwd overrides initialized before spawn")
end)

T.test("registered member launch and relaunch use each actual workdir for both adapters", function()
  T.eq(T.eval([[
    local base = os.getenv("XDG_DATA_HOME") .. "/delegated-fixtures"
    remuda._butler_agent_builders.claude = function(spec)
      for _, rel in ipairs({ "/.claude/settings.local.json", "/.codex/config.toml", "/.codex/rules/remuda.rules" }) do
        local f = assert(io.open(spec.cwd .. rel, "rb")); local text = f:read("*a"); f:close()
        assert(not text:find(spec.token, 1, true), "session token must not enter client config")
      end
      return { "sh", "-c", "sleep 60" }
    end
    remuda._butler_agent_builders.codex = remuda._butler_agent_builders.claude
    for _, kind in ipairs({ "claude", "codex" }) do
      local cwd = base .. "/" .. kind
      remuda.mkdir(cwd)
      remuda._butler_launch_impl.launch_agent(kind, "fixture-" .. kind, cwd, nil, "butler")
      local identity = remuda._butler_bus.identities["fixture-" .. kind]
      assert(identity and identity.id, "registered launch identity absent")
      -- Failed spawn leaves no active alias, so the actual relaunch call can
      -- reuse its durable identity without closing or restarting any agent.
      remuda._butler_launch_impl.launch_agent(kind, "fixture-" .. kind, cwd, nil, "butler", nil, identity.id)
      local report = remuda._butler_coordination_reports[remuda.fs.realpath(cwd)]
      assert(report and not report.error and #report.written == 0 and #report.unchanged == 3)
    end
    local a = remuda.fs.realpath(base .. "/claude")
    local b = remuda.fs.realpath(base .. "/codex")
    assert(a ~= b and remuda._butler_coordination_reports[a] ~= remuda._butler_coordination_reports[b])
    return "two actual workdirs|both adapters|repeat relaunch|no capability config"
  ]]), "two actual workdirs|both adapters|repeat relaunch|no capability config")
end)

T.test("per-launch Claude --settings file carries allow-only Remuda defaults, privately", function()
  T.eq(T.eval([[
    local path = remuda.fs.realpath(os.getenv("XDG_DATA_HOME")) .. "/wcc-session.status"
    local settings_path = remuda._butler_agent_support.status_settings(path)
    local f = assert(io.open(settings_path, "rb")); local text = f:read("*a"); f:close()
    local doc = remuda.json.decode(text)
    local p = doc.permissions
    assert(p and p.allow and #p.allow == 2 and p.allow[1] == "Bash(remuda:*)" and p.allow[2] == "mcp__remuda__*", "allow rules")
    assert(p.deny == nil and p.ask == nil and p.defaultMode == nil, "allow-only: no deny/ask/mode keys")
    assert(doc.hooks and doc.hooks.Stop and doc.statusLine, "telemetry hooks and status line kept")
    assert(not text:find("REMUDA_SESSION_CAPABILITY", 1, true), "no capability serialized")
    local mode = remuda.process.run({ argv = { "ls", "-ld", settings_path }, timeout = 5 }).stdout
    assert(mode:match("^%-rw%-%-%-%-%-%-%-"), "private mode: " .. mode)
    return "ok"
  ]]), "ok")
end)
