-- Unit tests for packages/butler/schedule_cli.lua. Run from the repository root:
--   luajit tests/butler_schedule_cli.lua
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

local path = os.tmpname()
os.remove(path)
local traces, prompts, writes = {}, {}, 0
local live = { butler = true, ["dev-1"] = true }
local matrix = { prompt_preface_supported = function() return true end }
remuda = {
  json = dofile("tests/support/literal_json.lua"),
  butler = { matrix = matrix },
  fs = {
    write_atomic = function(target, contents, options)
      assert(options.private == true, "schedules are written private")
      writes = writes + 1
      local file = assert(io.open(target, "wb"))
      file:write(contents)
      file:close()
      return true
    end,
  },
  fail = function(message, code) return { error = message, code = code } end,
  pending = function()
    return {
      prompt_line = function(_, spec) prompts[#prompts + 1] = spec end,
      resolve = function(self, code, stdout, stderr)
        self.result = { code = code, stdout = stdout, stderr = stderr }
      end,
    }
  end,
  _butler_schedule_env = {
    path = path,
    trace = function(event, detail) traces[#traces + 1] = event .. " " .. tostring(detail) end,
    resolve = function(target)
      if not live[target] then error("unknown member: " .. target, 0) end
      return target
    end,
  },
}
dofile("packages/butler/schedule.lua")
local cli = dofile("packages/butler/schedule_cli.lua")
local schedule = remuda.butler.schedule

local function file_text()
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end
local function stored() return schedule.load(path) end
-- Runs `add` and, when it reached the prompt, answers it.
local function add(args, answer, stdin, agent)
  prompts = {}
  local reply = cli.cli(args, agent, stdin)
  if #prompts == 0 then return reply end
  prompts[1].callback(answer)
  return reply.result, prompts[1]
end
local function words(...) return { "schedule", ... } end

eq("an empty store lists nothing", cli.cli(words("list")), "no schedules")

-- add is operator-only.
local refused = cli.cli(words("add", "north-star", "7 * * * *", "hello"), "01HABC")
ok("an agent identity is refused for add", type(refused) == "table" and refused.error:find("operator%-only"))
eq("a refused add asks nothing", #prompts, 0)
eq("a refused add writes nothing", file_text(), nil)
ok("a session name counts as an agent identity too",
  type(cli.cli(words("add", "x", "7 * * * *", "t"), "dev-1")) == "table")

-- add: validated first, then confirmed, then written.
local result, prompt = add(words("add", "north-star", "7 * * * *", "North Star check"), "yes")
eq("yes completes the add", result.code, 0)
ok("it reports the name", result.stdout:find("added schedule north%-star"))
ok("the prompt names the schedule", prompt.label:find("north%-star"))
ok("the prompt warns about standing delivery", prompt.preface:find("reserved sender `schedule`", 1, true))
local entry = stored()[1]
eq("stored name", entry.name, "north-star")
eq("stored spec", entry.spec, "7 * * * *")
eq("target defaults to butler", entry.target, "butler")
eq("stored text", entry.text, "North Star check")
eq("created by the operator", entry.created_by, "operator")
eq("enabled", entry.enabled, true)
ok("created_at is set", entry.created_at:find("^%d%d%d%d%-%d%d%-%d%dT"))
ok("a new schedule starts at the current minute, not at an old slot",
  math.abs(entry.last_fired - os.time() / 60) <= 1)
ok("the add is traced", traces[#traces]:find("^schedule_added north%-star 7 %* %* %* %* %-> butler"))

local before = file_text()
local nothing = add(words("add", "other", "7 * * * *", "text"), "no")
eq("anything but yes cancels", nothing.code, 1)
local typed = add(words("add", "other", "7 * * * *", "text"), "y")
eq("y is not yes", typed.code, 1)
eq("a cancelled add leaves the file alone", file_text(), before)

local with_target = add(words("add", "guard", "*/30 * * * *", "liveness", "--to", "dev-1"), "yes")
eq("--to sets the target", with_target.code, 0)
eq("target stored", select(2, schedule.find(stored(), "guard")).target, "dev-1")
local piped = add(words("add", "piped", "0 9 * * *", "-"), "yes", "line one\nline two\n\n")
eq("stdin text is accepted", piped.code, 0)
eq("trailing newlines of stdin are dropped", select(2, schedule.find(stored(), "piped")).text, "line one\nline two")

-- add: bad input never reaches the prompt and never writes.
local function rejected(label, args, stdin)
  prompts = {}
  local writes_before = writes
  local got = cli.cli(args, nil, stdin)
  ok(label .. " is rejected", type(got) == "table" and got.code == 1)
  eq(label .. " asks nothing", #prompts, 0)
  eq(label .. " writes nothing", writes, writes_before)
  return got.error
end
rejected("a step of 4", words("add", "n1", "*/4 * * * *", "t"))
rejected("a day field", words("add", "n1", "7 * 1 * *", "t"))
rejected("an upper-case name", words("add", "North", "7 * * * *", "t"))
rejected("a duplicate name", words("add", "north-star", "9 * * * *", "t"))
rejected("a text with a tab", words("add", "n1", "7 * * * *", "a\tb"))
rejected("a text with an escape", words("add", "n1", "7 * * * *", "a\27[2Jb"))
rejected("an empty text", words("add", "n1", "7 * * * *", ""))
rejected("a too long text", words("add", "n1", "7 * * * *", ("x"):rep(2049)))
rejected("a too long stdin text", words("add", "n1", "7 * * * *", "-"), ("x"):rep(2049))
rejected("a missing stdin", words("add", "n1", "7 * * * *", "-"))
rejected("a missing text", words("add", "n1", "7 * * * *"))
rejected("an extra argument", words("add", "n1", "7 * * * *", "t", "more"))
rejected("a dangling --to", words("add", "n1", "7 * * * *", "t", "--to"))
ok("an unknown target is named", rejected("an unknown target", words("add", "n1", "7 * * * *", "t", "--to", "ghost")):find("ghost"))
rejected("a target given as an id", words("add", "n1", "7 * * * *", "t", "--to", "01HABCDEFGHJKMNPQRSTVWXYZ0"))
local usage = rejected("a bare add", words("add"))
ok("usage is shown", usage:find("Usage: remuda butler schedule list", 1, true))
ok("a bare schedule shows usage", cli.cli(words()).error:find("Usage:", 1, true))
ok("an unknown verb shows usage", cli.cli(words("rename")).error:find("Usage:", 1, true))

-- The 16-schedule cap.
for i = 1, 16 - #stored() do
  eq("fill " .. i, add(words("add", "fill-" .. i, "7 * * * *", "t"), "yes").code, 0)
end
eq("the store holds 16", #stored(), 16)
ok("the 17th is refused", rejected("a 17th schedule", words("add", "one-more", "7 * * * *", "t")):find("16"))

-- list: open to everyone, one line per schedule, text cut at 80 bytes and made terminal safe.
local listing = cli.cli(words("list"), "01HABC")
ok("an agent may list", type(listing) == "string")
local first = listing:match("^[^\n]*")
ok("a line carries name, spec, target, state and last_fired",
  first:find("^north%-star  7 %* %* %* %*  %-> butler  on  last %d%d%d%d%-%d%d%-%d%d %d%d:%d%d  North Star check$"))
eq("one line per schedule", select(2, listing:gsub("\n", "\n")) + 1, 16)
local long = schedule.load(path)
long[1].text = ("a"):rep(200)
long[2].text = "x\nred"
long[3].text = ("é"):rep(60)
long[3].enabled = false
long[3].last_fired = 0
schedule.save(path, long)
local lines = {}
for line in cli.cli(words("list")):gmatch("[^\n]+") do lines[#lines + 1] = line end
eq("an 80-byte text ends with ...", lines[1]:match("a+%.%.%.$"), ("a"):rep(77) .. "...")
ok("a newline in the text becomes a space", lines[2]:find("x red$"))
local hostile = { name = "n\27[2J", spec = "7 * * * *", target = "b\r", enabled = true, last_fired = 0,
  text = "x\27[31m\nred\194\133" }
local described = cli.describe(hostile)
ok("control characters never reach the terminal", not described:find("%c") and not described:find("\194\133"))
eq("a multi-byte text is cut on a character boundary", lines[3]:match("last never  (.*)$"), ("é"):rep(38) .. "...")
ok("disabled reads as off", lines[3]:find("  off  ", 1, true))

-- rm: operator-only, no prompt.
local gone_before = #stored()
local rm_refused = cli.cli(words("rm", "north-star"), "01HABC")
ok("an agent identity is refused for rm", type(rm_refused) == "table" and rm_refused.error:find("operator%-only"))
eq("a refused rm removes nothing", #stored(), gone_before)
prompts = {}
eq("rm reports", cli.cli(words("rm", "north-star")), "removed schedule north-star")
eq("rm asks nothing", #prompts, 0)
eq("rm removes the schedule", select(1, schedule.find(stored(), "north-star")), nil)
ok("the rm is traced", traces[#traces] == "schedule_removed north-star")
ok("rm of an absent schedule fails", cli.cli(words("rm", "north-star")).error:find("no schedule named north%-star"))
ok("rm needs a name", cli.cli(words("rm")).error:find("Usage:", 1, true))

-- A file that cannot be read is never overwritten by add or rm.
local garbage = "{{{ corrupt"
local f = assert(io.open(path, "wb")); f:write(garbage); f:close()
local wrote = writes
ok("add refuses an unusable file", add(words("add", "n1", "7 * * * *", "t"), "yes").error:find("unusable"))
ok("the refusal names the file and how to recover",
  add(words("add", "n1", "7 * * * *", "t"), "yes").error:find(path .. " is unusable", 1, true)
  and add(words("add", "n1", "7 * * * *", "t"), "yes").error:find("Delete the file", 1, true))
ok("rm refuses an unusable file", cli.cli(words("rm", "n1")).error:find("unusable"))
ok("list says the file is unusable", cli.cli(words("list")).error:find("unusable"))
eq("the unusable file is untouched", file_text(), garbage)
eq("nothing was written", writes, wrote)

-- Without terminal prompts, add changes nothing.
os.remove(path)
local saved_pending = remuda.pending
remuda.pending = nil
ok("no prompt support, no add", cli.cli(words("add", "n1", "7 * * * *", "t")).error:find("terminal prompts"))
remuda.pending = saved_pending
matrix.prompt_preface_supported = function() return false end
ok("no preface support, no add", cli.cli(words("add", "n1", "7 * * * *", "t")).error:find("terminal prompts"))
eq("still nothing stored", file_text(), nil)

-- Planted file contents reach neither the terminal nor the trace unescaped.
do
  local function clean(text)
    return not text:find("%c") and not text:find("\194[\128-\159]") and not text:find("\226\128[\139-\143\168-\174]")
      and not text:find("\226\129[\160-\164\166-\169]") and not text:find("\243\160[\128-\129]")
  end
  local nasty = "\27[31mRED\27]0;pwn\7\n\226\128\174\194\133z\226\128\139\243\160\128\129"
  local function message(reply) return type(reply) == "table" and reply.error or reply end
  traces = {}
  local f = assert(io.open(path, "wb"))
  f:write(remuda.json.encode({ version = nasty, schedules = remuda.json.array({}) }))
  f:close()
  ok("list shows a planted version clean", clean(message(cli.cli(words("list")))))
  ok("add shows it clean", clean(message(add(words("add", "n1", "7 * * * *", "t"), "yes"))))
  ok("rm shows it clean", clean(message(cli.cli(words("rm", "n1")))))
  ok("the trace holds it clean", #traces == 3 and clean(table.concat(traces, "")))
  local hostile_entry = { name = "ok-name", spec = "7 * * * *", target = "butler", text = nasty, created_by = nasty,
    created_at = nasty, last_fired = 0, enabled = true }
  eq("describe shows every field clean", clean(cli.describe(hostile_entry)), true)
  os.remove(path)
end

-- One unprintable date never aborts the listing.
do
  local entries = { { name = "bad", spec = "7 * * * *", target = "butler", text = "t", created_by = "operator",
    last_fired = 1e300, enabled = true }, { name = "good", spec = "7 * * * *", target = "butler", text = "t",
    created_by = "operator", last_fired = 0, enabled = true } }
  ok("describe prints ? for a date os.date cannot format", cli.describe(entries[1]):find("last %?  t$"))
  local real_date = os.date
  os.date = function() error("number has no integer representation") end
  local line = cli.describe({ name = "x", spec = "7 * * * *", target = "b", text = "t", last_fired = 5, enabled = true })
  os.date = real_date
  ok("a throwing os.date prints ?", line:find("last %?  t$"))
  eq("a never-fired entry still says never", cli.describe(entries[2]):find("last never", 1, true) ~= nil, true)
end

print(("butler_schedule_cli: %d cases passed"):format(count))
