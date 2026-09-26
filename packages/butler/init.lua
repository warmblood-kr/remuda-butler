-- remuda-module-v1 entry: makes `remuda.reload("butler")` possible without
-- restarting sessions. Butler's state already lives on the image's `remuda`
-- table (`remuda._butler_bus` and friends), and `butler/main` re-runs
-- idempotently, so this declaration only has to run it again after each
-- activation. `butler/main` stays a plain entry, which keeps rollback to a
-- legacy manifest a file swap plus `remuda.exec("butler")`.

-- The manifest seals `remuda` until activation succeeds, and the contract has
-- no post-activation step. A no-op child's exit is delivered as an event only
-- after this activation returns, and then reaches the hook declared below;
-- if activation fails, the previous version's hook boots instead.
-- The hook also needs the unsealed table: the sealed proxy's `__index` still
-- errors after activation (it expects a key but receives the proxy first).
-- ponytail: process-exit kick via the unsealed global table; replace it with a
-- core start/`mod_activated` hook once remuda's lifecycle contract has one.
local sealed = getmetatable(_G)
if not sealed then
  -- The CLI (`remuda butler`, `remuda exec`) sends this file as a plain chunk,
  -- bypassing the lifecycle loader; hand it to the in-image loader instead.
  return remuda.exec("butler")
end
local host = sealed.__index.remuda
host.process({ argv = { "true" }, on_exit = "butler-start" })

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return {} end,
  hooks = {
    { event = "butler-start", run = function() host.exec("butler/main") end },
  },
}
