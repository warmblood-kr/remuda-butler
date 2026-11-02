-- Preserve the existing downstream action tests while using core's real parser.
-- Each file gets a separate environment because its action doubles replace remuda.
for _, file in ipairs({ "butler_approve_text.lua", "butler_status_hook.lua", "butler_guard.lua", "butler_adopt.lua", "butler_approval_retry.lua", "butler_schedule_cli.lua", "butler_typed_lines_cli.lua" }) do
  T.test(file .. " with the real shared parser", function()
    local environment = {}
    for key, value in pairs(_G) do
      if key ~= "remuda" and key ~= "_G" then environment[key] = value end
    end
    local parser = remuda.cli
    local values = {}
    setmetatable(environment, {
      __index = function(_, key)
        if key == "remuda" and values.remuda then return values.remuda end
        return _G[key]
      end,
      __newindex = function(target, key, value)
        if key == "remuda" then
          value.cli = parser
          values.remuda = value
        else
          rawset(target, key, value)
        end
      end,
    })
    environment._G = environment
    environment.dofile = function(path)
      return assert(loadfile(path, "t", environment))()
    end
    environment.dofile("tests/" .. file)
  end)
end
