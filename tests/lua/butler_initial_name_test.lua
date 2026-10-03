T.child_env = { PWD = "/home/x/my-project/" }

T.test("Butler initial name ignores the launch directory basename", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.expect(T.eval("return os.getenv('PWD')") == "/home/x/my-project/",
    "child daemon did not receive T.child_env",
    "ok - child daemon received T.child_env")
  T.eval("remuda._butler_test_mode = true")
  T.eval('return remuda.exec("butler")')
  T.expect(T.eval("return remuda._butler_initial_name") == "butler",
    "Butler initial name followed the launch directory",
    "ok - Butler initial name stays 'butler' with a launch directory")
end)
