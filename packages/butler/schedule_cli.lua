-- `remuda butler schedule list|add|rm`. list is open to everyone; add and rm
-- are for a person at the terminal, because a schedule keeps injecting its
-- text after the agent has forgotten it and across restarts. add asks for
-- `yes` like turning typed-lines on; rm, like turning it off, does not.
local schedule = assert(remuda.butler and remuda.butler.schedule,
  "load butler/schedule before butler/schedule_cli")
local M = {}

local USAGE = "Usage: remuda butler schedule list\n"
  .. '       remuda butler schedule add NAME "M H * * *" TEXT [--to SESSION]\n'
  .. "       remuda butler schedule rm NAME\n"
  .. "TEXT may be - to read it from stdin. A schedule is minute N or */N (N one of 5, 6, 10, 12, 15, 20, 30) at hour N or *."
local WARNING = "From now on this text arrives as mail from the reserved sender `schedule` at every due time, until the schedule is removed, also after restarts. The receiving agent reads it like any mail and may act on it."
local LIST_TEXT_BYTES = 80

local function fail(message)
  if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
  return nil, message
end

local function terminal_safe(value)
  return (tostring(value or ""):gsub("%c", " "):gsub("\194[\128-\159]", " "))
end

-- shortened(text, limit): at most `limit` bytes, cut on a character boundary,
-- ending in "..." when it is not complete.
local function shortened(text, limit)
  if #text <= limit then return text end
  local cut = limit - 3
  while cut > 0 and text:byte(cut + 1) >= 128 and text:byte(cut + 1) < 192 do cut = cut - 1 end
  return text:sub(1, cut) .. "..."
end

-- describe(entry) -> one list line.
function M.describe(entry)
  local fired = entry.last_fired > 0 and os.date("%Y-%m-%d %H:%M", entry.last_fired * 60) or "never"
  return table.concat({
    terminal_safe(entry.name), terminal_safe(entry.spec), "-> " .. terminal_safe(entry.target),
    entry.enabled and "on" or "off", "last " .. fired,
    shortened(terminal_safe(entry.text), LIST_TEXT_BYTES),
  }, "  ")
end

-- load_list(env) -> list | nil, reason. A file that cannot be read is never
-- overwritten by add or rm.
local function load_list(env)
  local list, problem = schedule.load(env.path, env.trace)
  if problem then
    return nil, (env.path or "schedules.json") .. " is unusable (" .. problem
      .. "). Delete the file, or fix its contents, to use schedules again; nothing was changed."
  end
  return list
end

-- parse_add(args, stdin) -> { name, spec, text, target } | nil, reason
local function parse_add(args, stdin)
  local n = #args
  if n ~= 5 and not (n == 7 and args[6] == "--to" and args[7] ~= "") then return nil, USAGE end
  local text = args[5]
  if text == "-" then
    if type(stdin) ~= "string" then return nil, "no text received on stdin" end
    text = stdin:gsub("\n+$", "")
  end
  return { name = args[3], spec = args[4], text = text, target = args[7] or "butler" }
end

-- build(env, request, list) -> entry | nil, reason: everything add checks before it asks.
local function build(env, request, list)
  local entry = { name = request.name, spec = request.spec, target = request.target, text = request.text,
    created_by = "operator", created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    last_fired = math.floor(os.time() / 60), enabled = true }
  local candidate = {}
  for i, existing in ipairs(list) do candidate[i] = existing end
  local ok, err = schedule.add(candidate, entry)
  if not ok then return nil, err end
  local resolved, alias = pcall(env.resolve, request.target)
  if not resolved or alias ~= request.target then
    return nil, "no live session named " .. request.target .. "; the target must be a session alias"
  end
  return entry
end

-- confirm(label, run): the terminal prompt of typed-lines on; `run` returns
-- ok, message once the owner types yes.
local function confirm(label, run)
  local matrix = remuda.butler.matrix
  if type(remuda.pending) ~= "function" or not (matrix and type(matrix.prompt_preface_supported) == "function"
      and matrix.prompt_preface_supported()) then
    return fail("Adding a schedule needs a Remuda core with terminal prompts. Nothing was changed.")
  end
  local pending_ok, reply = pcall(remuda.pending, { timeout = 90 })
  if not pending_ok or type(reply) ~= "table" or type(reply.prompt_line) ~= "function" then
    return fail("Adding a schedule needs a terminal prompt. Nothing was changed.")
  end
  local completed = false
  local function resolve(code, stdout, stderr)
    if completed then return end
    completed = true
    if type(reply.resolve) == "function" then reply:resolve(code, stdout or "", stderr or "") end
  end
  local prompted, prompt_error = pcall(reply.prompt_line, reply, {
    label = label,
    preface = WARNING,
    callback = function(answer, failure)
      if completed then return end
      if failure then return resolve(1, "", "The schedule prompt failed. Nothing was changed.\n") end
      if answer ~= "yes" then return resolve(1, "", "Not added. Nothing was changed.\n") end
      local ok, message = run()
      if ok then resolve(0, message .. "\n", "") else resolve(1, "", message .. "\n") end
    end,
  })
  if not prompted then
    resolve(1, "", "The schedule prompt failed: " .. tostring(prompt_error) .. ". Nothing was changed.\n")
    return nil
  end
  return reply
end

local function add(args, env, stdin)
  local request, parse_error = parse_add(args, stdin)
  if not request then return fail(parse_error) end
  local list, list_error = load_list(env)
  if not list then return fail(list_error) end
  local entry, build_error = build(env, request, list)
  if not entry then return fail(build_error) end
  return confirm("Type yes to add schedule " .. entry.name .. ".", function()
    local latest, latest_error = load_list(env)
    if not latest then return nil, latest_error end
    local fresh, fresh_error = build(env, request, latest)
    if not fresh then return nil, fresh_error end
    schedule.add(latest, fresh)
    local saved, save_error = schedule.save(env.path, latest)
    if not saved then return nil, "could not save the schedule: " .. tostring(save_error) end
    env.trace("schedule_added", fresh.name .. " " .. fresh.spec .. " -> " .. fresh.target)
    return true, "added schedule " .. fresh.name
  end)
end

local function remove(args, env)
  if #args ~= 3 then return fail(USAGE) end
  local list, list_error = load_list(env)
  if not list then return fail(list_error) end
  if not schedule.remove(list, args[3]) then return fail("no schedule named " .. terminal_safe(args[3])) end
  local saved, save_error = schedule.save(env.path, list)
  if not saved then return fail("could not save the schedules: " .. tostring(save_error)) end
  env.trace("schedule_removed", args[3])
  return "removed schedule " .. args[3]
end

local function show(args, env)
  if #args ~= 2 then return fail(USAGE) end
  local entries, list_error = load_list(env)
  if not entries then return fail(list_error) end
  if #entries == 0 then return "no schedules" end
  local lines = {}
  for i, entry in ipairs(entries) do lines[i] = M.describe(entry) end
  return table.concat(lines, "\n")
end

-- cli(args, agent, stdin): args[1] is "schedule". `agent` is the caller's
-- Butler identity, nil for a person at the terminal.
function M.cli(args, agent, stdin)
  local env = remuda._butler_schedule_env
  if type(args) ~= "table" or type(env) ~= "table" or not env.path then return fail(USAGE) end
  local verb = args[2]
  if verb == "list" then return show(args, env) end
  if verb ~= "add" and verb ~= "rm" then return fail(USAGE) end
  if type(agent) == "string" and agent ~= "" then
    return fail("schedule " .. verb .. " is operator-only. Run it from the owner's terminal; ask the owner to run it.")
  end
  if verb == "add" then return add(args, env, stdin) end
  return remove(args, env)
end

remuda.butler.schedule_cli = M
return M
