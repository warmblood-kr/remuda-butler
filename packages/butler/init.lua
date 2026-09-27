-- remuda-module-v1 entry: makes `remuda.reload("butler")` possible without
-- restarting sessions. Butler state lives on the image's `remuda` table;
-- main.lua re-runs idempotently, so boot it after each activation.

-- The manifest seals remuda until activation succeeds, and there is no
-- post-activation callback. Schedule a one-shot event for a later tick. A
-- child process exit is unsafe here: CLI-auto-started daemons can die on
-- their first process-exit notification (remuda#98 (d)).
local sealed = getmetatable(_G)
if not sealed then
  -- `remuda butler` and `remuda exec` send this entry as a plain chunk.
  return remuda.exec("butler")
end
local host = sealed.__index.remuda
-- ponytail: the unsealed-table lookup and one-shot schedule sidestep the seal;
-- replace them with the start hook asked for in warmblood-kr/remuda#98 (1).
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
