-- Unit tests for packages/butler/schedule.lua. Run from the repository root:
--   luajit tests/butler_schedule.lua
local schedule = dofile("packages/butler/schedule.lua")
local count = 0

local function eq(name, got, want)
  count = count + 1
  if got ~= want then
    error(("case %d: %s\n want: %s\n  got: %s"):format(count, name, tostring(want), tostring(got)), 2)
  end
end

local function ok(name, value)
  count = count + 1
  if not value then error(("case %d: %s"):format(count, name), 2) end
end

-- UTC epoch seconds of a calendar time.
local function utc(y, mo, d, h, mi, s)
  return schedule.days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + (s or 0)
end
local function utc_fields(t) return os.date("!*t", t) end

-- parse: five fields, minute N or */N (N >= 5), hour N or *, the rest `*`.
local function rule_of(spec)
  local rule, err = schedule.parse(spec)
  ok("parses: " .. spec .. " (" .. tostring(err) .. ")", rule)
  return rule
end
local hourly = rule_of("7 * * * *")
eq("hourly minute", hourly.minute, 7)
eq("hourly hour is any", hourly.hour, nil)
eq("rule keeps its spec", hourly.spec, "7 * * * *")
local daily = rule_of("0 9 * * *")
eq("daily minute", daily.minute, 0)
eq("daily hour", daily.hour, 9)
local half = rule_of("*/30 * * * *")
eq("step", half.step, 30)
eq("step has no fixed minute", half.minute, nil)
eq("*/5 is the smallest step", rule_of("*/5 * * * *").step, 5)
rule_of("59 23 * * *")

for _, spec in ipairs({
  "", "* * * * *", "*/4 * * * *", "*/0 * * * *", "*/60 * * * *", "*/ * * * *", "*/5x * * * *",
  "60 * * * *", "7 24 * * *", "-1 * * * *", "a * * * *", "1-5 * * * *", "1,2 * * * *", "*/5,10 * * * *",
  "007 * * * *", "7 * 1 * *", "7 * * 1 *", "7 * * * 1", "7 * * *", "7 * * * * *",
  " 7 * * * *", "7 * * * * ", "7  * * * *", "7\t*\t*\t*\t*", "7 * * * *\n", "7 * * * *\0",
  "7 * * *\r*", "7 *\27[2J * * *",
}) do
  local rule, err = schedule.parse(spec)
  ok("rejected: " .. spec:gsub("%c", "?"), rule == nil and type(err) == "string" and err ~= "")
end
for _, value in ipairs({ 7, true, {} }) do
  local rule, err = schedule.parse(value)
  ok("non-string rejected: " .. type(value), rule == nil and type(err) == "string")
end
ok("a nil spec is rejected", schedule.parse(nil) == nil)

-- last_due: the latest slot at or before now, as a UTC epoch minute.
local function due(rule, t, fields)
  local slot = schedule.last_due(rule, t, fields or utc_fields)
  return slot and slot * 60
end
eq("hourly: on the minute", due(hourly, utc(2026, 10, 2, 10, 7, 0)), utc(2026, 10, 2, 10, 7))
eq("hourly: last second of the slot minute", due(hourly, utc(2026, 10, 2, 10, 7, 59)), utc(2026, 10, 2, 10, 7))
eq("hourly: one second early", due(hourly, utc(2026, 10, 2, 10, 6, 59)), utc(2026, 10, 2, 9, 7))
eq("daily: before the hour", due(daily, utc(2026, 10, 2, 8, 59, 59)), utc(2026, 10, 1, 9, 0))
eq("daily: on the hour", due(daily, utc(2026, 10, 2, 9, 0, 0)), utc(2026, 10, 2, 9, 0))
eq("daily: late in the day", due(daily, utc(2026, 10, 2, 23, 59, 59)), utc(2026, 10, 2, 9, 0))
eq("step 30: just before", due(half, utc(2026, 10, 2, 10, 29, 59)), utc(2026, 10, 2, 10, 0))
eq("step 30: on it", due(half, utc(2026, 10, 2, 10, 30, 0)), utc(2026, 10, 2, 10, 30))
local five = rule_of("*/5 * * * *")
eq("step 5: before", due(five, utc(2026, 10, 2, 10, 4, 59)), utc(2026, 10, 2, 10, 0))
eq("step 5: on it", due(five, utc(2026, 10, 2, 10, 5, 0)), utc(2026, 10, 2, 10, 5))
eq("step 5: 23:59 sees 23:55", due(five, utc(2026, 10, 2, 23, 59, 59)), utc(2026, 10, 2, 23, 55))
eq("step 5: 00:00 starts the next day", due(five, utc(2026, 10, 3, 0, 0, 0)), utc(2026, 10, 3, 0, 0))
local midnight = rule_of("0 0 * * *")
eq("midnight: 23:59 still belongs to today's slot", due(midnight, utc(2026, 10, 2, 23, 59, 59)), utc(2026, 10, 2, 0, 0))
eq("midnight: 00:00 is the next slot", due(midnight, utc(2026, 10, 3, 0, 0, 0)), utc(2026, 10, 3, 0, 0))
eq("month and year rollover", due(midnight, utc(2027, 1, 1, 0, 0, 30)), utc(2027, 1, 1, 0, 0))
eq("a fractional clock is floored", due(hourly, utc(2026, 10, 2, 10, 7, 0) + 0.9), utc(2026, 10, 2, 10, 7))

-- A zone that springs forward at 2026-03-08 07:00Z: local 02:00-02:59 never happens.
local jump = utc(2026, 3, 8, 7, 0)
local function new_york(t) return os.date("!*t", t + (t < jump and -18000 or -14400)) end
local at_230 = rule_of("30 2 * * *")
eq("skipped hour: still before the jump", due(at_230, jump - 60, new_york), utc(2026, 3, 7, 7, 30))
eq("skipped hour: catches up at the first minute after the gap", due(at_230, jump, new_york), jump)
eq("skipped hour: stays the same slot afterwards", due(at_230, jump + 3600, new_york), jump)
eq("skipped hour: the next day is its own slot", due(at_230, utc(2026, 3, 9, 6, 31), new_york), utc(2026, 3, 9, 6, 30))
eq("a rule outside the gap is unaffected", due(rule_of("0 9 * * *"), jump + 25200, new_york), utc(2026, 3, 8, 13, 0))
eq("an hourly rule fires at its real minute after the jump", due(hourly, jump + 600, new_york), jump + 420)

print(("butler_schedule: %d cases passed"):format(count))
