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


-- Persistence. remuda.json is a stand-in that round-trips Lua literals; the
-- daemon is the only place the real one runs.
local writes = {}
remuda = {
  json = {
    encode = function(value)
      local function lit(v)
        if type(v) == "string" then return ("%q"):format(v) end
        if type(v) ~= "table" then return tostring(v) end
        local out = {}
        for k, item in pairs(v) do out[#out + 1] = "[" .. lit(k) .. "]=" .. lit(item) end
        return "{" .. table.concat(out, ",") .. "}"
      end
      return lit(value)
    end,
    decode = function(text)
      local chunk = assert(loadstring(text and "return " .. text or "return nil"))
      setfenv(chunk, {})
      return chunk()
    end,
  },
  fs = {
    write_atomic = function(path, contents, options)
      writes[#writes + 1] = options
      local file = assert(io.open(path, "wb"))
      file:write(contents)
      file:close()
      return true
    end,
  },
}
local path = os.tmpname()
local traces = {}
local function trace(event, detail) traces[#traces + 1] = event .. " " .. tostring(detail) end
local function entry(name)
  return { name = name or "north-star", spec = "7 * * * *", target = "butler", text = "North Star check",
    created_by = "operator", created_at = "2026-10-02T00:00:00Z", last_fired = 0, last_message = "m1", enabled = true }
end
local function put(contents) local f = assert(io.open(path, "wb")); f:write(contents); f:close() end

eq("an absent file is an empty list", #schedule.load(os.tmpname() .. ".none", trace), 0)
eq("an absent file is no problem", select(2, schedule.load(os.tmpname() .. ".none", trace)), nil)
eq("a missing mail root is an empty list", #schedule.load(nil, trace), 0)

local list = {}
ok("add stores a checked entry", schedule.add(list, entry()))
ok("save writes", schedule.save(path, list))
ok("the file is written private", writes[1].private == true)
local loaded, problem = schedule.load(path, trace)
eq("round trip keeps the entry", #loaded, 1)
eq("round trip name", loaded[1].name, "north-star")
eq("round trip text", loaded[1].text, "North Star check")
eq("round trip last_message", loaded[1].last_message, "m1")
eq("round trip is not a problem", problem, nil)
eq("a good file leaves no trace", #traces, 0)

local multi = entry("multi")
multi.text = 'line one\nline "two"'
list = {}
schedule.add(list, multi)
schedule.save(path, list)
eq("newlines and quotes survive", schedule.load(path, trace)[1].text, multi.text)

-- A corrupt, oversized or foreign-version file loads as an empty list and says why.
for label, contents in pairs({
  corrupt = "{{{ not a record", empty = "", wrong_shape = "{[\"version\"]=1}",
  newer = "{[\"version\"]=2,[\"schedules\"]={}}",
  oversized = "{[\"version\"]=1,[\"schedules\"]={},[\"pad\"]=\"" .. ("x"):rep(300 * 1024) .. "\"}",
}) do
  put(contents)
  traces = {}
  local got, why = schedule.load(path, trace)
  ok(label .. " loads as an empty list, not a crash", type(got) == "table" and #got == 0)
  ok(label .. " reports a problem", type(why) == "string")
  ok(label .. " is traced", #traces == 1 and traces[1]:find("^schedule_file_unusable"))
end

-- A bad record inside a good file is dropped; the rest stay.
local bad_text = entry("bad-text")
bad_text.text = "tab\there"
local bad_spec = entry("bad-spec")
bad_spec.spec = "*/4 * * * *"
put(remuda.json.encode({ version = 1, schedules = { entry("keep"), bad_text, bad_spec, entry("keep"), "junk" } }))
traces = {}
loaded = schedule.load(path, trace)
eq("only the good unique record loads", #loaded, 1)
eq("it is the first of the duplicates", loaded[1].name, "keep")
eq("each dropped record is traced", #traces, 4)
os.remove(path)

-- Limits.
for _, name in ipairs({ "North", "a_b", "", ("a"):rep(33), "a b", 7 }) do
  ok("name rejected: " .. tostring(name), not schedule.valid_name(name))
end
ok("32 characters is a valid name", schedule.valid_name(("a"):rep(32)))
ok("digits and dashes are valid", schedule.valid_name("0-a-9"))
ok("text of 2048 bytes is valid", schedule.valid_text(("x"):rep(2048)))
ok("text of 2049 bytes is rejected", not schedule.valid_text(("x"):rep(2049)))
ok("newlines are allowed in text", schedule.valid_text("a\nb"))
for _, text in ipairs({ "", "a\tb", "a\27[2Jb", "a\0b", "a\r\nb", "a\127b", "a\194\133b", 7 }) do
  ok("text rejected: " .. tostring(text):gsub("%c", "?"), not schedule.valid_text(text))
end
ok("a session alias is a valid target", schedule.valid_target("butler") and schedule.valid_target("dev-1.a"))
for _, target in ipairs({ "", "a b", "a;b", "a\nb", ("a"):rep(65), 7 }) do
  ok("target rejected: " .. tostring(target):gsub("%c", "?"), not schedule.valid_target(target))
end
list = {}
ok("first add", schedule.add(list, entry("a")))
ok("a duplicate name is refused", not schedule.add(list, entry("a")))
local with_tab = entry("tabbed")
with_tab.spec = "7\t*\t*\t*\t*"
ok("an invalid spec is refused", not schedule.add(list, with_tab))
for i = 2, 16 do ok("add " .. i, schedule.add(list, entry("s" .. i))) end
local over, why = schedule.add(list, entry("seventeen"))
ok("the 17th schedule is refused", not over and why:find("16"))
ok("remove returns true", schedule.remove(list, "a") and #list == 15)
ok("remove of an absent name is nil", not schedule.remove(list, "a"))

print(("butler_schedule: %d cases passed"):format(count))
