T.test("shared prompt collapsed paste replacement", function()
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eq(T.eval([[print = function() end; return dofile(os.getenv("REMUDA_LUA_REPO") .. "/tests/prompt_delivery.lua") or "ok"]]), "ok")
end)
