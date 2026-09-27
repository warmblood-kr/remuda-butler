-- remuda-module-v1 entry: makes `remuda.reload("butler")` possible without
-- restarting sessions. Butler state lives on the image's `remuda` table;
-- main.lua re-runs idempotently, so boot it after each activation.

if not getmetatable(_G) then
  -- Cores before warmblood-kr/remuda#98 (3) send this entry as a plain chunk
  -- from `remuda butler` / `remuda exec`; re-enter through the loader. Drop it
  -- once the minimum core includes that fix.
  return remuda.exec("butler")
end

-- `start` runs after activation, with `remuda` unsealed (warmblood-kr/remuda#104).
-- The event keeps boots countable (`remuda.event_counts()["butler-start"]`).
return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return {} end,
  start = function() remuda.emit("butler-start") end,
  hooks = {
    { event = "butler-start", run = function() remuda.exec("butler/main") end },
  },
}
