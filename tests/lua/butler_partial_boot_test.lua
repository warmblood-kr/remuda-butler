-- Rust helper restricted boot: boolean `_butler_test_mode` is an explicit
-- commands-only partial image. The exact `remuda -s s exec butler` path must
-- succeed without claiming production readiness, starting Matrix/relay or
-- leaving a request-candidate cleanup pending.
T.test("restricted boolean test-mode CLI boot is an explicit partial image", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval("remuda._butler_test_mode=true; remuda._butler_skip_relay=true")
  local r = remuda.process.run {
    argv = { assert(os.getenv("REMUDA_BIN")), "-s",
      assert(os.getenv("REMUDA_LUA_CHILD_SERVER")), "exec", "butler" },
    timeout = 10,
  }
  T.eq(r.code, 0, "CLI partial-mode boot: " .. tostring(r.stderr))
  local state = T.eval([==[
    return table.concat({
      tostring(remuda._butler_partial_image),
      tostring(remuda._butler_runtime_refusal),
      tostring(remuda._butler_standby),
      tostring(remuda.butler and remuda.butler.send_policy),
      tostring(remuda.butler and remuda.butler.matrix),
      tostring(remuda._butler_request_retire_blocked),
    }, "|")
  ]==])
  T.eq(state, "test_mode|nil|nil|nil|nil|nil",
    "partial image must not claim policy/matrix/refusal or pending cleanup")
end)
