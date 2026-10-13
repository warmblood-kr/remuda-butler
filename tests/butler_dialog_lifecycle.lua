-- Lifecycle wiring with a fake host; never boots a daemon or real agent.
local ticks, stopped = 0, {}
local host = { butler = {}, schedules = {}, emit = function() end }
host.exec = function(name)
  if name == 'butler/system' then host._butler_system = {} end
  if name == 'butler/main' then
    local id = #stopped + 1
    host.butler.dialogs = { stop = function() stopped[#stopped + 1] = id end }
    host._butler_dialog_tick = function() ticks = ticks + 1 end
  end
end
local function module()
  local globals = setmetatable({remuda = host}, {__index = _G})
  local env = setmetatable({}, {__index = globals})
  env._G = env
  local chunk = assert(loadfile('packages/butler/init.lua', 't', env))
  if setfenv then setfenv(chunk, env) end
  return chunk()
end
local first = module()
local poll, count
count = 0
for _, schedule in ipairs(first.schedules) do
  if schedule.name == 'butler-dialogs' then poll = schedule; count = count + 1 end
end
assert(count == 1 and poll.every == 1, 'one declared dialog schedule')
poll.run(); assert(ticks == 0, 'no dialog probing before activation')
first.start(first.initialize()); poll.run(); assert(ticks == 1, 'active schedule dispatches')
local old = host.butler.dialogs
local second = module(); second.start(second.initialize())
local replacement = host.butler.dialogs
old.stop = function() stopped[#stopped + 1] = 'old' end
replacement.stop = function() stopped[#stopped + 1] = 'replacement' end
first.stop({})
assert(stopped[#stopped] == 'old', 'retirement stops own dispatcher rather than replacement')
second.stop({})
assert(stopped[#stopped] == 'replacement', 'current activation stops its dispatcher')
print('butler dialog lifecycle: PASS')
