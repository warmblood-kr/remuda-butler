-- Persistent schedules: fixed texts that arrive as ordinary mail at wall-clock
-- times. This file holds the pure rule grammar (parse, last_due); it does no
-- I/O and reads the clock only through the `fields` function it is given.
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

if remuda and remuda.butler then remuda.butler.schedule = M end
return M
