-- Explicit test subject, never installed. Derive from production instead of duplicating algorithms.
local M = {}
local function replace(source, anchor, value)
  local first, last = source:find(anchor, 1, true)
  assert(first and not source:find(anchor, last + 1, true), 'guard subject anchor drift: ' .. anchor)
  return source:sub(1, first - 1) .. value .. source:sub(last + 1)
end

function M.build(source, name)
  if name == 'guard_policy' then
    return replace(source, 'function M.time() return os.time() end',
      'function M.time() return (M.now and M.now()) or os.time() end')
  end
  assert(name == 'guard_grants', 'unknown guard subject')
  source = replace(source, 'local function now() return os.time() end',
    'local function now() return (M.now or os.time)() end')
  source = replace(source, 'local function insensitive(real) return probe(real) end',
    'local function insensitive(real) return (M.insensitive or probe)(real) end')
  source = replace(source, 'local function verified(e)\n',
    'local function verified(e)\n  if M.verified then return M.verified(e) end\n')
  return replace(source, '    deadline = os.time() + GIT_BUDGET', [[
    local budget = M.git_budget_s
    if type(budget) ~= 'number' or not (budget > 0 and budget <= 60) then budget = GIT_BUDGET end
    deadline = os.time() + budget]])
end

-- Redirect only during this evaluation, and restore the native loader even if the test throws.
function M.wrap(code, directory)
  return ([=[
    local native_exec = remuda.exec
    local subjects = { ['butler/guard_policy'] = %q, ['butler/guard_grants'] = %q }
    remuda.exec = function(name, ...)
      if subjects[name] then return assert(loadfile(subjects[name]))() end
      return native_exec(name, ...)
    end
    local result = table.pack(pcall(function()
      %s
    end))
    remuda.exec = native_exec
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
  ]=]):format(directory .. '/guard_policy.lua', directory .. '/guard_grants.lua', code)
end

return M
