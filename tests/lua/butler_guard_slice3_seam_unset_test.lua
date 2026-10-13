-- Run the same installed-production CLI/MCP matrix with the real legacy flag absent.
assert(loadfile(assert(os.getenv('REMUDA_LUA_REPO')) .. '/tests/lua/butler_guard_slice3_seam_isolation_test.lua'))()
T.child_env = {}
