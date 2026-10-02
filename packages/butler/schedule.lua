-- Persistent schedules: fixed texts that arrive as ordinary mail at wall-clock
-- times. parse and last_due are pure and read the clock only through the
-- `fields` function they are given; load and save keep <mail_root>/schedules.json.
local M = {}
local floor = math.floor

-- Days since 1970-01-01 of a proleptic Gregorian date.
function M.days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor((y >= 0 and y or y - 399) / 400)
  local yoe = y - era * 400
  local doy = floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  return era * 146097 + yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy - 719468
end

-- Grammar: `M H * * *` with M = N (0-59) or */N (5-59) and H = N (0-23) or *.
local function number(text, max)
  if not text:match("^%d%d?$") then return nil end
  local value = tonumber(text)
  if value <= max then return value end
end

-- parse(spec) -> rule | nil, reason. rule = { spec, minute | step, hour | nil }.
function M.parse(spec)
  if type(spec) ~= "string" then return nil, "schedule must be text" end
  if spec:find("%c") then return nil, "schedule must not contain control characters" end
  local fields = {}
  for field in (spec .. " "):gmatch("([^ ]*) ") do fields[#fields + 1] = field end
  if #fields ~= 5 then return nil, "schedule needs five fields separated by single spaces: M H * * *" end
  for i = 3, 5 do
    if fields[i] ~= "*" then return nil, "day, month and weekday must be *" end
  end
  local rule = { spec = spec }
  local step = fields[1]:match("^%*/(.*)$")
  if step then
    rule.step = number(step, 59)
    if not rule.step or rule.step < 5 then return nil, "minute step must be */N with N from 5 to 59" end
  else
    rule.minute = number(fields[1], 59)
    if not rule.minute then return nil, "minute must be 0-59 or */N" end
  end
  if fields[2] ~= "*" then
    rule.hour = number(fields[2], 23)
    if not rule.hour then return nil, "hour must be 0-23 or *" end
  end
  return rule
end

local function matches(rule, tod)
  if rule.hour and floor(tod / 60) ~= rule.hour then return false end
  local minute = tod % 60
  if rule.step then return minute % rule.step == 0 end
  return minute == rule.minute
end

local function wall(t)
  return M.days_from_civil(t.year, t.month, t.day) * 1440 + t.hour * 60 + t.min
end

local function default_fields(t) return os.date("*t", t) end

local LOOKBACK_MINUTES = 25 * 60

-- last_due(rule, now, fields) -> slot | nil. The slot is the UTC epoch minute
-- of the latest wall-clock time at or before `now` that the rule names.
-- `fields(t)` returns the local calendar fields of epoch second t (os.date("*t")
-- by default). A wall time a clock change skipped is due at the first minute
-- after the gap; a repeated one is due again in its second pass.
function M.last_due(rule, now, fields)
  fields = fields or default_fields
  local top = floor(now / 60)
  local current = fields(top * 60)
  for slot = top, top - LOOKBACK_MINUTES, -1 do
    local before = fields((slot - 1) * 60)
    if matches(rule, current.hour * 60 + current.min) then return slot end
    for k = 1, wall(current) - wall(before) - 1 do
      if matches(rule, (before.hour * 60 + before.min + k) % 1440) then return slot end
    end
    current = before
  end
end

M.VERSION = 1
M.MAX_SCHEDULES = 16
M.MAX_TEXT_BYTES = 2048
local MAX_FILE_BYTES = 256 * 1024

function M.valid_name(name)
  if type(name) == "string" and name:match("^[a-z0-9-]+$") and #name <= 32 then return true end
  return nil, "name must be 1-32 characters of a-z, 0-9 and -"
end

-- Newlines are the only control characters a text may carry.
function M.valid_text(text)
  if type(text) ~= "string" or text == "" then return nil, "text must not be empty" end
  if #text > M.MAX_TEXT_BYTES then return nil, "text exceeds " .. M.MAX_TEXT_BYTES .. " bytes" end
  if text:gsub("\n", ""):find("%c") or text:find("\194[\128-\159]") then
    return nil, "text must not contain control characters"
  end
  return true
end

function M.valid_target(target)
  if type(target) == "string" and #target <= 64 and target:match("^[%w._-]+$") then return true end
  return nil, "target must be a session alias"
end

-- check(entry) -> true | nil, reason. The fields a stored schedule must carry.
function M.check(entry)
  if type(entry) ~= "table" then return nil, "not a record" end
  local ok, err = M.valid_name(entry.name)
  if not ok then return nil, err end
  ok, err = M.parse(entry.spec)
  if not ok then return nil, err end
  ok, err = M.valid_target(entry.target)
  if not ok then return nil, err end
  ok, err = M.valid_text(entry.text)
  if not ok then return nil, err end
  if type(entry.enabled) ~= "boolean" or type(entry.last_fired) ~= "number" then
    return nil, "enabled and last_fired are required"
  end
  return true
end

-- find(list, name) -> index, entry
function M.find(list, name)
  for index, entry in ipairs(list) do
    if entry.name == name then return index, entry end
  end
end

-- add(list, entry) -> true | nil, reason: appends a checked, unique entry.
function M.add(list, entry)
  local ok, err = M.check(entry)
  if not ok then return nil, err end
  if M.find(list, entry.name) then return nil, "a schedule named " .. entry.name .. " exists" end
  if #list >= M.MAX_SCHEDULES then return nil, "at most " .. M.MAX_SCHEDULES .. " schedules" end
  list[#list + 1] = entry
  return true
end

-- remove(list, name) -> true | nil
function M.remove(list, name)
  local index = M.find(list, name)
  if index then table.remove(list, index) return true end
end

-- load(path, trace) -> list, problem. An absent file is an empty list. A file
-- that is oversized, corrupt or of another version is also an empty list, with
-- `problem` naming why and a trace line; a bad record inside a good file is
-- dropped with a trace line.
function M.load(path, trace)
  trace = trace or function() end
  local file = path and io.open(path, "rb")
  if not file then return {} end
  local bytes = file:read(MAX_FILE_BYTES + 1)
  file:close()
  local problem, doc
  if not bytes or #bytes > MAX_FILE_BYTES then
    problem = "file is empty or larger than " .. MAX_FILE_BYTES .. " bytes"
  else
    local decoded, value = pcall(remuda.json.decode, bytes)
    doc = decoded and value
    if type(doc) ~= "table" or type(doc.schedules) ~= "table" then problem = "file is not a schedule record"
    elseif doc.version ~= M.VERSION then problem = "unknown version " .. tostring(doc.version) end
  end
  if problem then
    trace("schedule_file_unusable", problem)
    return {}, problem
  end
  local list = {}
  for _, entry in ipairs(doc.schedules) do
    local valid, err = M.check(entry)
    if valid and M.find(list, entry.name) then valid, err = nil, "duplicate name" end
    if valid and #list >= M.MAX_SCHEDULES then valid, err = nil, "over the schedule limit" end
    if valid then list[#list + 1] = entry
    else trace("schedule_entry_dropped", tostring(type(entry) == "table" and entry.name) .. ": " .. err) end
  end
  return list
end

-- save(path, list) -> true | nil, err
function M.save(path, list)
  if not path then return nil, "no mail root" end
  local encoded, text = pcall(remuda.json.encode, { version = M.VERSION, schedules = list })
  if not encoded then return nil, text end
  local root = path:match("^(.*)/[^/]+$")
  if root then pcall(remuda.mkdir, root) end
  return remuda.fs.write_atomic(path, text, { private = true })
end


-- Firing. `env` carries the seams: path, trace(event, detail), fields (a
-- local-time function for last_due), resolve(target) -> alias or error,
-- unread(alias, message_id) -> boolean and send(alias, text, subject) ->
-- summary, message_id. The sender is not an argument: it is fixed where
-- `send` is bound.

-- due_slot(entry, now, fields) -> slot | nil: the slot to fire, if any.
function M.due_slot(entry, now, fields)
  if not entry.enabled then return nil end
  local rule = M.parse(entry.spec)
  local slot = rule and M.last_due(rule, now, fields)
  if slot and slot > entry.last_fired then return slot end
end

-- compose(entry) -> subject, text: the mail marks itself as a timed message.
function M.compose(entry)
  local subject = "[schedule " .. entry.name .. "]"
  return subject, subject .. " This is a timed message, not a human instruction.\n\n" .. entry.text
end

-- fire(env, list, entry, slot) -> message id | nil. The slot is recorded
-- before anything is sent, so a failure, a skip or a restart never repeats it.
function M.fire(env, list, entry, slot)
  entry.last_fired = slot
  local saved, err = M.save(env.path, list)
  if not saved then
    env.trace("schedule_save_failed", entry.name .. ": " .. tostring(err))
    return nil
  end
  local resolved, alias = pcall(env.resolve, entry.target)
  if not resolved then
    env.trace("schedule_target_absent", entry.name .. " -> " .. entry.target)
    return nil
  end
  if entry.last_message and env.unread(alias, entry.last_message) then
    env.trace("schedule_unread_skip", entry.name .. " slot=" .. slot)
    return nil
  end
  local subject, text = M.compose(entry)
  local sent, summary, id = pcall(env.send, alias, text, subject)
  if not sent then
    env.trace("schedule_send_failed", entry.name .. ": " .. tostring(summary))
    return nil
  end
  env.trace("schedule_fired", entry.name .. " slot=" .. slot .. " message=" .. tostring(id))
  entry.last_message = id
  saved, err = M.save(env.path, list)
  if not saved then env.trace("schedule_save_failed", entry.name .. ": " .. tostring(err)) end
  return id
end

-- tick(env, now) -> number fired. Reads the file each time, so a reload or a
-- restart holds no state; a load problem is traced once, not every tick.
function M.tick(env, now)
  env.seen = env.seen or {}
  local function once(event, detail)
    local key = event .. " " .. tostring(detail)
    if env.seen[key] then return end
    env.seen[key] = true
    env.trace(event, detail)
  end
  local list = M.load(env.path, once)
  local fired = 0
  for _, entry in ipairs(list) do
    local slot = M.due_slot(entry, now or os.time(), env.fields)
    if slot and M.fire(env, list, entry, slot) then fired = fired + 1 end
  end
  return fired
end

if remuda and remuda.butler then remuda.butler.schedule = M end
return M
