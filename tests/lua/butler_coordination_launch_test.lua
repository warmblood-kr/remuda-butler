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
    remuda._wcc_real_claude_builder = remuda._wcc_real_claude_builder or remuda._butler_agent_builders.claude
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
    local dir_mode = remuda.process.run({ argv = { "ls", "-ldH", settings_path:match("^(.*)/[^/]+$") }, timeout = 5 }).stdout
    assert(dir_mode:match("^drwx%-%-%-%-%-%-"), "exclusive private directory: " .. dir_mode)
    return "ok"
  ]]), "ok")
end)

T.test("settings file failure returns no path and never falls back to a plain write", function()
  T.eq(T.eval([[
    local path = remuda.fs.realpath(os.getenv("XDG_DATA_HOME")) .. "/wcc-fail.status"
    local status_settings = remuda._butler_agent_support.status_settings
    local real_atomic, real_mkdir_new, real_open = remuda.fs.write_atomic, remuda.fs.mkdir_new, io.open
    local function expect_failure(label, setup, restore)
      local plain_opens = 0
      io.open = function(p, mode, ...)
        if type(p) == "string" and p:find("settings.json", 1, true) and mode and mode:find("w", 1, true) then
          plain_opens = plain_opens + 1
        end
        return real_open(p, mode, ...)
      end
      setup()
      local ok, got, why = pcall(status_settings, path)
      restore(); io.open = real_open
      assert(ok and got == nil and type(why) == "string" and why ~= "", label .. ": no path, reason given")
      assert(plain_opens == 0, label .. ": no plain-write fallback")
    end
    expect_failure("missing atomic support", function() remuda.fs.write_atomic = nil end,
      function() remuda.fs.write_atomic = real_atomic end)
    expect_failure("atomic write error", function() remuda.fs.write_atomic = function() return nil, "injected" end end,
      function() remuda.fs.write_atomic = real_atomic end)
    expect_failure("atomic write raises", function() remuda.fs.write_atomic = function() error("boom", 0) end end,
      function() remuda.fs.write_atomic = real_atomic end)
    expect_failure("no exclusive mkdir", function() remuda.fs.mkdir_new = nil end,
      function() remuda.fs.mkdir_new = real_mkdir_new end)
    expect_failure("directory is a link", function()
      remuda.fs.mkdir_new = function(dir)
        os.execute("ln -s " .. os.getenv("XDG_DATA_HOME") .. " '" .. dir .. "'")
        return true
      end
    end, function() remuda.fs.mkdir_new = real_mkdir_new end)
    return "ok"
  ]]), "ok")
end)

-- Boundary: the real telemetry adapter + argv builder the chooser calls for a
-- Claude candidate (root, member, delegation and relaunch all go through
-- them). A builder error becomes a spawn_error for that candidate and the
-- chooser never reaches remuda.new (agents_launch.lua start_next).
local GUARD_ON = [[
  local real_policy = remuda.butler.guard_policy
  remuda.butler.guard_policy = setmetatable({
    enabled = function() return true end,
    approvals_enabled = function() return true end,
    deny_enabled = function() return true end,
  }, { __index = real_policy })
  local function restore() remuda.butler.guard_policy = real_policy end
]]

T.test("settings persistence failure: Claude argv builder refuses (no argv without guard hooks)", function()
  T.eq(T.eval(GUARD_ON .. [[
    local real_atomic = remuda.fs.write_atomic
    remuda.fs.write_atomic = function() return nil, "injected persistence failure" end
    local telemetry = remuda._butler_telemetry_adapters.claude.setup({ name = "bf-member" })
    remuda.fs.write_atomic = real_atomic
    local ok, err = pcall(remuda._wcc_real_claude_builder or remuda._butler_agent_builders.claude,
      { name = "bf-member", token = "t", model = "opus", cwd = os.getenv("XDG_DATA_HOME"),
        settings_path = telemetry.settings_path, telemetry = telemetry })
    restore()
    assert(telemetry.settings_path == nil and telemetry.settings_error, "adapter reports the failure")
    assert(not ok and tostring(err):find("refusing to start Claude", 1, true), "builder refuses with a reason: " .. tostring(err))
    return "refused"
  ]]), "refused")
end)

T.test("settings persistence failure with guard policy off degrades without --settings, traced", function()
  T.eq(T.eval([[
    local real_atomic = remuda.fs.write_atomic
    remuda.fs.write_atomic = function() return nil, "injected persistence failure" end
    local telemetry = remuda._butler_telemetry_adapters.claude.setup({ name = "bf-off" })
    remuda.fs.write_atomic = real_atomic
    local policy = remuda.butler.guard_policy
    assert(not policy.enabled(), "fixture expects guard policy off by default")
    local ok, argv = pcall(remuda._wcc_real_claude_builder or remuda._butler_agent_builders.claude,
      { name = "bf-off", token = "t", model = "opus", cwd = os.getenv("XDG_DATA_HOME"),
        settings_path = telemetry.settings_path, telemetry = telemetry })
    assert(ok and type(argv) == "table", "builds without guard dependency")
    for _, word in ipairs(argv) do assert(word ~= "--settings", "no --settings without a file") end
    return "ok"
  ]]), "ok")
end)

T.test("normal Claude argv carries --settings with guard hooks, defaults and status, in any cwd", function()
  T.eq(T.eval(GUARD_ON .. [[
    local base = os.getenv("XDG_DATA_HOME") .. "/boundary-ok"
    remuda.mkdir(base); remuda.mkdir(base .. "/.git"); remuda.mkdir(base .. "/sub"); remuda.mkdir(base .. "/wt")
    local f = assert(io.open(base .. "/wt/.git", "wb")); f:write("gitdir: /elsewhere"); f:close()
    local problems = {}
    for _, cwd in ipairs({ base, base .. "/sub", base .. "/wt" }) do
      local telemetry = remuda._butler_telemetry_adapters.claude.setup({ name = "bo-member" })
      local ok, argv = pcall(remuda._wcc_real_claude_builder or remuda._butler_agent_builders.claude,
        { name = "bo-member", token = "t", model = "opus", cwd = cwd,
          settings_path = telemetry.settings_path, telemetry = telemetry })
      if not ok then problems[#problems + 1] = "builder failed in " .. cwd
      else
        local path
        for i, word in ipairs(argv) do if word == "--settings" then path = argv[i + 1] end end
        local fh = path and io.open(path, "rb")
        local text = fh and fh:read("*a") or ""
        if fh then fh:close() end
        for _, needle in ipairs({ "PreToolUse", "PermissionRequest", "Bash(remuda:*)", "mcp__remuda__*", "statusLine" }) do
          if not text:find(needle, 1, true) then problems[#problems + 1] = cwd .. " lacks " .. needle end
        end
      end
    end
    restore()
    assert(#problems == 0, table.concat(problems, "; "))
    return "ok"
  ]]), "ok")
end)

T.test("relaunching a member replaces its settings and status directories (no accumulation)", function()
  T.eq(T.eval([[
    local adapter = remuda._butler_telemetry_adapters.claude
    local first = adapter.setup({ name = "lc-member" })
    local first_dir = first.settings_path:match("^(.*)/[^/]+$")
    local first_status_dir = first.status_path:match("^(.*)/[^/]+$")
    local second = adapter.setup({ name = "lc-member" })
    assert(second.settings_path and second.settings_path ~= first.settings_path, "fresh settings file")
    local function exists(dir)
      local r = remuda.process.run({ argv = { "ls", "-d", dir }, timeout = 5 })
      return r.code == 0
    end
    assert(not exists(first_dir), "previous settings directory removed")
    assert(not exists(first_status_dir), "previous status directory removed")
    assert(exists(second.settings_path:match("^(.*)/[^/]+$")), "current settings directory kept")
    return "ok"
  ]]), "ok")
end)

