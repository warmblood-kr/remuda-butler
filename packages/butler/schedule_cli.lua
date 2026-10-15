-- `remuda butler schedule list|add|rm`. A session may add for itself and
-- remove its own schedules. An outside operator retains management of all.
local schedule = assert(remuda.butler and remuda.butler.schedule,
  "load butler/schedule before butler/schedule_cli")
local parse_cli = assert(remuda.cli and remuda.cli.parse, "Butler CLI requires remuda.cli.parse; upgrade Remuda")
local M = {}

local USAGE = "Usage: remuda butler schedule list\n"
  .. '       remuda butler schedule add NAME "M H * * *" TEXT [--to SESSION]\n'
  .. "       remuda butler schedule rm NAME\n"
  .. "TEXT may be - to read it from stdin. Members can target only themselves and remove only schedules they created; the operator can manage any target. A schedule is minute N or */N (N one of 5, 6, 10, 12, 15, 20, 30) at hour N or *."
local WARNING = "From now on this text arrives as mail from the reserved sender `schedule` at every due time, until the schedule is removed, also after restarts. The receiving agent reads it like any mail and may act on it."
local LIST_TEXT_BYTES = 80

local SCHEDULE_CLI_SPEC = {
  name = "remuda butler schedule",
  verbs = {
    list = { about = "List scheduled Butler messages. Example: remuda butler schedule list",
      next = "remuda butler schedule add --help" },
    add = { about = "Add a recurring Butler message. Example: remuda butler schedule add morning '0 9 * * *' 'Check the queue'",
      options = { { long = "to", value = "SESSION", help = "Target session (default: your own session for members, butler for the operator)" } },
      args = { { name = "NAME", help = "Unique schedule name" },
        { name = "CRON", help = "Supported minute/hour schedule, e.g. 0 9 * * *" },
        { name = "TEXT", help = "Message text, or - to read from stdin" } },
      next = "remuda butler schedule list" },
    rm = { about = "Remove a scheduled message. Example: remuda butler schedule rm morning",
      args = { { name = "NAME", help = "Schedule name" } }, next = "remuda butler schedule list" },
  },
}

local function fail(message)
  if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
  return nil, message
end

local terminal_safe, shortened = schedule.safe, schedule.shortened

-- describe(entry) -> one list line.
function M.describe(entry)
  local fired = "never"
  if entry.last_fired > 0 then
    local formatted, text = pcall(os.date, "%Y-%m-%d %H:%M", entry.last_fired * 60)
    fired = formatted and type(text) == "string" and text or "?"
  end
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
local function parse_add(values, stdin)
  local text = values.TEXT
  if text == "-" then
    if type(stdin) ~= "string" then return nil, "no text received on stdin" end
    text = stdin:gsub("\n+$", "")
  end
  return { name = values.NAME, spec = values.CRON, text = text, target = values.to or "butler", explicit_target = values.to ~= nil }
end

-- build(env, request, list) -> entry | nil, reason: everything add checks before it asks.
local function build(env, request, list, creator, recipient_id)
  local entry = { name = request.name, spec = request.spec, target = request.target, text = request.text,
    created_by = creator or "operator", created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    last_fired = math.floor(os.time() / 60), enabled = true }
  if recipient_id then entry.recipient_id = recipient_id end
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
    preface = matrix.wrap_prompt_preface(WARNING),
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

local function persist_add(env, request, creator, recipient_id)
  local latest, latest_error = load_list(env)
  if not latest then return nil, latest_error end
  local fresh, fresh_error = build(env, request, latest, creator, recipient_id)
  if not fresh then return nil, fresh_error end
  schedule.add(latest, fresh)
  local saved, save_error = schedule.save(env.path, latest)
  if not saved then return nil, "could not save the schedule: " .. tostring(save_error) end
  env.trace("schedule_added", fresh.name .. " " .. fresh.spec .. " -> " .. fresh.target)
  return true, "added schedule " .. fresh.name
end

local function add(request, env, principal)
  local creator
  if principal then
    creator = principal.id
    if type(creator) ~= "string" or creator == "" or type(principal.alias) ~= "string" then
      return fail("schedule add needs an authenticated Butler session")
    end
    if request.explicit_target and request.target ~= principal.alias then
      return fail("a Butler session can create schedules only for itself")
    end
    request.target = principal.alias
  end
  local list, list_error = load_list(env)
  if not list then return fail(list_error) end
  local entry, build_error = build(env, request, list, creator, creator)
  if not entry then return fail(build_error) end
  -- Running this command in an authenticated session is its confirmation.
  -- Keep the standing-delivery warning in the response for that self-service path.
  if principal then
    local ok, message = persist_add(env, request, creator, creator)
    if not ok then return fail(message) end
    return message .. ". " .. WARNING
  end
  return confirm("Type yes to add schedule " .. entry.name .. ".", function()
    return persist_add(env, request, "operator")
  end)
end

local function remove(name, env, principal)
  local list, list_error = load_list(env)
  if not list then return fail(list_error) end
  local index, entry = schedule.find(list, name)
  if not entry or (principal and entry.created_by ~= principal.id) then
    return fail("no schedule named " .. terminal_safe(name))
  end
  table.remove(list, index)
  local saved, save_error = schedule.save(env.path, list)
  if not saved then return fail("could not save the schedules: " .. tostring(save_error)) end
  env.trace("schedule_removed", terminal_safe(name))
  return "removed schedule " .. name
end

local function show(env)
  local entries, list_error = load_list(env)
  if not entries then return fail(list_error) end
  if #entries == 0 then return "no schedules" end
  local lines = {}
  for i, entry in ipairs(entries) do lines[i] = M.describe(entry) end
  return table.concat(lines, "\n")
end

-- cli(args, principal, stdin): args[1] is "schedule". `principal` is the
-- authenticated caller, nil for the outside operator.
function M.cli(args, principal, stdin)
  local argv = {}
  for i = 2, #(args or {}) do argv[#argv + 1] = args[i] end
  local report = parse_cli(SCHEDULE_CLI_SPEC, argv)
  if report.kind == "help" then return report.text end
  if not report.ok then return fail(report.text) end
  local env = remuda._butler_schedule_env
  if type(args) ~= "table" or type(env) ~= "table" or not env.path then return fail(USAGE) end
  local verb = report.verb
  if verb == "list" then return show(env) end
  if verb ~= "add" and verb ~= "rm" then return fail(USAGE) end
  if principal ~= nil and (type(principal) ~= "table" or principal.tag ~= "member") then
    return fail("schedule " .. verb .. " needs an authenticated Butler session or the operator")
  end
  if verb == "add" then
    local request, problem = parse_add(report.values, stdin)
    if not request then return fail(problem) end
    return add(request, env, principal)
  end
  return remove(report.values.NAME, env, principal)
end

remuda.butler.schedule_cli = M
return M
