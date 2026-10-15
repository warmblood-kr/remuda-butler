-- Cold root (no remuda._butler_argv override), guard policy on, per-launch
-- settings file cannot be persisted: module init must finish, Claude must not
-- be spawned, and the remaining candidate/failure reporting stays available.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.test("guard on + failed settings write: init completes, no Claude spawn, fallback reachable", function()
  T.eq(T.eval([[
    local guard_dir = os.getenv("XDG_DATA_HOME") .. "/guard-cold"
    remuda.mkdir(guard_dir)
    remuda._butler_guard_dir = guard_dir
    local marker = assert(io.open(guard_dir .. "/guard-observe", "wb")); marker:write("on\n"); marker:close()
    remuda._butler_skip_relay = true
    remuda._cold_spawns = {}
    remuda.new = function(name, argv)
      remuda._cold_spawns[#remuda._cold_spawns + 1] = tostring(argv and argv[1])
      error("fixture stops before starting an agent", 0)
    end
    local real_atomic = remuda.fs.write_atomic
    remuda.fs.write_atomic = function(path, text, opts)
      if tostring(path):find("settings.json", 1, true) then return nil, "injected persistence failure" end
      return real_atomic(path, text, opts)
    end
    local ok, err = pcall(remuda.exec, "butler")
    remuda.fs.write_atomic = real_atomic
    assert(ok, "module init aborted: " .. tostring(err))
    assert(remuda._butler_reconcile_retry ~= nil, "reconcile/launch entry points exist")
    for _, first in ipairs(remuda._cold_spawns) do
      assert(not first:match("claude$"), "Claude spawned without its guard hooks: " .. first)
    end
    return "ok"
  ]]), "ok")
end)
