-- remuda-module-v1 entry: makes `remuda.reload("butler")` possible without
-- restarting sessions. Butler's state already lives on the image's `remuda`
-- table (`remuda._butler_bus` and friends), and `butler/main` re-runs
-- idempotently, so this declaration only has to run it again after each
-- activation. `butler/main` stays a plain entry, which keeps rollback to a
-- legacy manifest a file swap plus `remuda.exec("butler")`.

-- The manifest seals `remuda` until activation succeeds, and the contract has
-- no post-activation step. A one-shot schedule first fires on a later tick,
-- after this activation returns, and emits to the hook declared below; if
-- activation fails, the previous version's hook boots instead. (Not a child
-- process: a child's exit kills a CLI-auto-started daemon, remuda#98 (d).)
-- The hook also needs the unsealed table: the sealed proxy's `__index` still
-- errors after activation (it expects a key but receives the proxy first).
-- ponytail: one-shot schedule via the unsealed global table sidesteps the seal;
-- replace it with the start hook asked for in warmblood-kr/remuda#98 (1).
local sealed = getmetatable(_G)
if not sealed then
  -- The CLI (`remuda butler`, `remuda exec`) sends this file as a plain chunk,
  -- bypassing the lifecycle loader; hand it to the in-image loader instead.
  return remuda.exec("butler")
end
local host = sealed.__index.remuda
local kick
kick = host.schedule({ name = "butler-start", every = 0.05, run = function()
  host.cancel(kick)
  host.emit("butler-start")
end })

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return {} end,
  hooks = {
    { event = "butler-start", run = function() host.exec("butler/main") end },
  },
}
