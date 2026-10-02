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
for _, n in ipairs({ 5, 6, 10, 12, 15, 20, 30 }) do eq("*/" .. n .. " parses", rule_of("*/" .. n .. " * * * *").step, n) end
ok("a rejected step says which steps are allowed", select(2, schedule.parse("*/59 * * * *")):find("5, 6, 10, 12, 15, 20, 30", 1, true))

for _, spec in ipairs({
  "", "* * * * *", "*/4 * * * *", "*/7 * * * *", "*/25 * * * *", "*/59 * * * *", "*/0 * * * *", "*/60 * * * *", "*/ * * * *", "*/5x * * * *",
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


-- Persistence. remuda.json is a stand-in; the daemon is the only place the real one runs.
local writes = {}
remuda = {
  json = dofile("tests/support/literal_json.lua"),
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
do
  local planted = { entry("planted") }
  planted[1].spec = "*/59 * * * *"
  local sink = {}
  assert(schedule.save(path, planted))
  eq("a hand-planted */59 is dropped on load", #schedule.load(path, function(e) sink[#sink + 1] = e end), 0)
  eq("and traced", sink[1], "schedule_entry_dropped")
  assert(schedule.save(path, list))
end
ok("the file is written private", writes[1].private == true)
local loaded, problem = schedule.load(path, trace)
eq("round trip keeps the entry", #loaded, 1)
eq("round trip name", loaded[1].name, "north-star")
eq("round trip text", loaded[1].text, "North Star check")
eq("round trip last_message", loaded[1].last_message, "m1")

-- A mail root that does not exist yet is created by save.
local fresh_root = os.tmpname() .. ".d/butler/mail"
local made_dirs = {}
remuda.mkdir = function(dir) made_dirs[#made_dirs + 1] = dir end
local real_write_atomic, landed = remuda.fs.write_atomic, os.tmpname()
remuda.fs.write_atomic = function(_, contents, options) return real_write_atomic(landed, contents, options) end
ok("save into a missing mail root", schedule.save(fresh_root .. "/schedules.json", list))
remuda.fs.write_atomic = real_write_atomic
eq("the mail root was made", made_dirs[1], fresh_root)
eq("the saved file loads", #schedule.load(landed, trace), 1)

-- Removing the last entry saves an empty list.
local emptied = {}
assert(schedule.add(emptied, entry()))
assert(schedule.remove(emptied, "north-star"))
ok("an empty list saves", schedule.save(path, emptied))
eq("an empty list loads empty", #schedule.load(path, trace), 0)
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

-- File-derived text never reaches a problem, a trace or a listing unescaped.
do
  local nasty = { "\27[31mRED", "\27]0;pwn\7", "a\nb", "\226\128\174evil", "\194\133c1", "z\226\128\139w",
    "\243\160\128\129tag", "\r\n2026 schedule_added forged", ("x"):rep(5000) }
  local function clean(text)
    return not text:find("%c") and not text:find("\194[\128-\159]") and not text:find("\226\128[\139-\143\168-\174]")
      and not text:find("\226\129[\160-\164\166-\169]") and not text:find("\239\187\191")
      and not text:find("\243\160[\128-\129]")
  end
  for _, bad in ipairs(nasty) do
    put(remuda.json.encode({ version = bad, schedules = remuda.json.array({}) }))
    traces = {}
    local _, why = schedule.load(path, trace)
    ok("a planted version is clean in the problem", clean(why) and #why < 300)
    ok("and in the trace", clean(traces[1]:gsub("^schedule_file_unusable ", "")) and #traces[1] < 300)
    local named = entry(bad)
    put(remuda.json.encode({ version = 1, schedules = { named } }))
    traces = {}
    schedule.load(path, trace)
    ok("a rejected name is clean in the trace", #traces == 1 and clean(traces[1]) and #traces[1] < 300)
    local fires = {}
    schedule.tick({ path = path, trace = function(e, d) fires[#fires + 1] = e .. d end }, 1e9)
    local shared = { path = path, trace = function() end }
    schedule.tick(shared, 1e9)
    for key in pairs(shared.seen) do ok("and in the once cache", #key < 300) end
    ok("and in a tick", #fires == 1 and clean(fires[1]))
  end
  eq("safe keeps plain text", schedule.safe("north-star 7 * * * *"), "north-star 7 * * * *")
  eq("safe cuts long text", #schedule.safe(("é"):rep(500), 100) <= 100, true)
  put(remuda.json.encode({ version = 1, schedules = remuda.json.array({}) }))
end
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

-- Firing, with an injected clock and mail stubs.
local fire_path = os.tmpname()
local sent, events, files_at_send = {}, {}, {}
local unread_ids, absent, send_error = {}, {}, nil
local function env()
  return {
    path = fire_path, fields = utc_fields,
    trace = function(event, detail) events[#events + 1] = event .. " " .. tostring(detail) end,
    resolve = function(target)
      if absent[target] then error("unknown member: " .. target, 0) end
      return target
    end,
    unread = function(_, id) return unread_ids[id] == true end,
    send = function(...)
      local file = assert(io.open(fire_path, "rb"))
      files_at_send[#files_at_send + 1] = file:read("*a")
      file:close()
      if send_error then error(send_error, 0) end
      sent[#sent + 1] = { ... }
      return "queued m" .. #sent, "m" .. #sent
    end,
  }
end
local function reset(entries)
  sent, events, files_at_send, unread_ids, absent, send_error = {}, {}, {}, {}, {}, nil
  local list = {}
  for _, e in ipairs(entries) do assert(schedule.add(list, e)) end
  assert(schedule.save(fire_path, list))
end
local function stored(name) return (select(2, schedule.find(schedule.load(fire_path), name))) end
local function hourly_entry(name, last_fired)
  local e = entry(name)
  e.last_fired = last_fired or 0
  e.last_message = nil
  return e
end
local noon = utc(2026, 10, 2, 10, 7, 30)      -- inside the 10:07 slot
local slot_1007 = utc(2026, 10, 2, 10, 7) / 60

reset({ hourly_entry("a") })
eq("a due schedule fires", schedule.tick(env(), noon), 1)
eq("one mail sent", #sent, 1)
eq("sent to the target alias", sent[1][1], "butler")
eq("the subject marks a timed message", sent[1][3], "[schedule a]")
ok("the body opens with the marker and says it is not a human instruction",
  sent[1][2]:find("^%[schedule a%] This is a timed message, not a human instruction%.\n\nNorth Star check$"))
eq("send takes no sender argument", select("#", unpack(sent[1])), 3)
eq("last_fired is the slot", stored("a").last_fired, slot_1007)
eq("last_message is recorded", stored("a").last_message, "m1")
eq("the same tick again does not refire", schedule.tick(env(), noon), 0)
eq("a restart in the same minute does not refire", schedule.tick(env(), noon + 20), 0)
eq("still one mail", #sent, 1)
eq("the next hour's slot fires", schedule.tick(env(), noon + 3600), 1)
eq("two mails", #sent, 2)
eq("no slot yet between two slots", schedule.tick(env(), noon + 3600 + 600), 0)

-- last_fired is on disk before the mail leaves.
reset({ hourly_entry("a") })
schedule.tick(env(), noon)
ok("the file already held last_fired = slot when send ran",
  files_at_send[1]:find(("[\"last_fired\"]=%d"):format(slot_1007), 1, true))

-- A catch-up fires once, with the latest slot.
reset({ hourly_entry("a", slot_1007 - 3 * 24 * 60) })
eq("three days of missed slots fire once", schedule.tick(env(), noon), 1)
eq("one mail for the whole gap", #sent, 1)
eq("the latest slot is recorded", stored("a").last_fired, slot_1007)

-- A failed send keeps the slot spent: loss over duplicate.
reset({ hourly_entry("a") })
send_error = "terminal busy"
eq("a failed send fires nothing", schedule.tick(env(), noon), 0)
eq("the slot stays spent", stored("a").last_fired, slot_1007)
ok("the failure is traced", events[#events]:find("^schedule_send_failed a: terminal busy"))
send_error = nil
eq("the slot is not retried", schedule.tick(env(), noon + 20), 0)
eq("nothing was sent", #sent, 0)

-- A target that does not resolve is skipped and traced; the slot is spent.
reset({ hourly_entry("a") })
absent.butler = true
eq("an absent target sends nothing", schedule.tick(env(), noon), 0)
eq("no mail", #sent, 0)
ok("it is traced as schedule_target_absent", events[#events]:find("^schedule_target_absent a %-> butler"))
eq("the slot is spent", stored("a").last_fired, slot_1007)

-- An unread previous message from the same schedule suppresses the next one.
reset({ hourly_entry("a") })
schedule.tick(env(), noon)
unread_ids.m1 = true
eq("an unread previous message skips the slot", schedule.tick(env(), noon + 3600), 0)
eq("still one mail", #sent, 1)
ok("the skip is traced", events[#events]:find("^schedule_unread_skip a"))
eq("the skipped slot is spent", stored("a").last_fired, slot_1007 + 60)
unread_ids.m1 = nil
eq("once read, the next slot fires", schedule.tick(env(), noon + 7200), 1)

-- A throw while firing one entry does not stop the later ones, and is traced once.
reset({ hourly_entry("a"), hourly_entry("b") })
do
  local shared = env()
  shared.unread = function(_, id) if id == "boom" then error("bad store", 0) end return false end
  local listing = schedule.load(fire_path)
  listing[1].last_message = "boom"
  assert(schedule.save(fire_path, listing))
  eq("the second entry fires after the first throws", schedule.tick(shared, noon), 1)
  eq("the later entry was sent", sent[1][3], "[schedule b]")
  ok("the throw is traced", table.concat(events, "\n"):find("schedule_fire_error a: bad store", 1, true))
end

-- An entry whose slot is already spent does not scan the clock.
reset({ hourly_entry("a", slot_1007) })
do
  local calls = 0
  local counting = env()
  counting.fields = function(t) calls = calls + 1 return utc_fields(t) end
  eq("a spent slot fires nothing", schedule.tick(counting, noon), 0)
  eq("and reads no calendar fields", calls, 0)
end

-- Hand-planted fields are validated on load.
for _, case in ipairs({
  { "created_by", 42 }, { "created_by", "x\n y" }, { "created_by", ("x"):rep(65) },
  { "last_message", 7 }, { "last_message", "m\0" }, { "last_message", ("m"):rep(65) },
}) do
  local bad = entry("planted")
  bad[case[1]] = case[2]
  ok("check refuses " .. case[1], not schedule.check(bad))
end
ok("a missing last_message is fine", schedule.check(hourly_entry("fresh")))

-- Disabled schedules and several schedules.
local off = hourly_entry("off")
off.enabled = false
reset({ off, hourly_entry("b"), hourly_entry("c") })
eq("only enabled schedules fire", schedule.tick(env(), noon), 2)
eq("disabled stays unfired", stored("off").last_fired, 0)

-- A failed save before sending sends nothing.
reset({ hourly_entry("a") })
local real_write = remuda.fs.write_atomic
remuda.fs.write_atomic = function() return nil, "disk full" end
eq("no mail when the slot cannot be recorded", schedule.tick(env(), noon), 0)
remuda.fs.write_atomic = real_write
eq("nothing was sent", #sent, 0)
ok("the save failure is traced", events[#events]:find("^schedule_save_failed a: disk full"))

-- A corrupt file fires nothing and is traced once, not every tick.
local f = assert(io.open(fire_path, "wb")); f:write("{{{"); f:close()
sent, events = {}, {}
local shared = env()
schedule.tick(shared, noon)
schedule.tick(shared, noon + 30)
eq("a corrupt file sends nothing", #sent, 0)
eq("and is traced once", #events, 1)
os.remove(fire_path)

-- The reserved sender: no session or topic can take the name `schedule`.
remuda._butler_system = setmetatable({}, { __index = function() return function() return "/tmp" end end })
dofile("packages/butler/paths.lua")
local valid_child_name = remuda._butler_paths.valid_child_name
ok("schedule is not a launchable name", not pcall(valid_child_name, "schedule", "agent name"))
ok("other names still are", pcall(valid_child_name, "scheduler", "agent name"))

print(("butler_schedule: %d cases passed"):format(count))
