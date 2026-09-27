-- remuda-module-v1 entry: makes `remuda.reload("butler")` possible without
-- restarting sessions. Butler state lives on the image's `remuda` table;
-- main.lua re-runs idempotently, so boot it after each activation.

if not getmetatable(_G) then
  -- Cores before warmblood-kr/remuda#98 (3) send this entry as a plain chunk
  -- from `remuda butler` / `remuda exec`; re-enter through the loader. Drop it
  -- once the minimum core includes that fix.
  return remuda.exec("butler")
end

-- Boot once per activation. `start` does it right after activation
-- (warmblood-kr/remuda#104). A core before #104 ignores `start`, so a one-shot
-- schedule boots Butler on the next tick instead and says to upgrade; on a
-- current core it finds this activation already booted and does nothing.
-- ponytail: `host` is the unsealed table, the one handle that works on both
-- cores (pre-#104 hooks cannot use the `remuda` proxy). Drop it with the
-- fallback once the minimum core includes #104 everywhere.
local host = getmetatable(_G).__index.remuda
local booted = false
local function boot()
  if booted then return end
  booted = true
  host.emit("butler-start")
end
local fallback
fallback = host.schedule({ name = "butler-start-fallback", every = 0.05, run = function()
  host.cancel(fallback)
  if not booted then
    io.stderr:write("butler: this remuda core ignores the lifecycle start hook"
      .. " (warmblood-kr/remuda#104); booted by fallback -- run `remuda upgrade`\n")
    boot()
  end
end })

return {
  api = "remuda-module-v1",
  state_version = 1,
  initialize = function() return {} end,
  start = boot,
  hooks = {
    { event = "butler-start", run = function() host.exec("butler/main") end },
  },
}
