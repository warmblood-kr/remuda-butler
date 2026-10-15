-- Production orchestration on synthetic screens in a private daemon.
T.test("Codex compaction preserves the intended session model and effort", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function() return T.eval('return remuda._butler_bus ~= nil') == "true" end, 5)
  T.eq(T.eval('return dofile(assert(os.getenv("REMUDA_LUA_REPO")) .. "/tests/fixtures/codex-compaction-scenarios.lua")'), "ok")
end)
