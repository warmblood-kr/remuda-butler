-- Preserve the existing downstream action tests while using core's real parser.
-- Each file gets a separate environment because its action doubles replace remuda.
for _, file in ipairs({ "butler_adopt.lua", "butler_approval_retry.lua", "butler_schedule_cli.lua", "butler_typed_lines_cli.lua" }) do
  T.test(file .. " with the real shared parser", function()
    local environment = {}
    local parser = remuda.cli
    setmetatable(environment, {
      __index = _G,
      __newindex = function(target, key, value)
        if key == "remuda" then value.cli = parser end
        rawset(target, key, value)
      end,
    })
    environment._G = environment
    environment.dofile = function(path)
      return assert(loadfile(path, "t", environment))()
    end
    environment.dofile("tests/" .. file)
  end)
end
