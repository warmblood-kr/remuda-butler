-- Focused roster test for the local OSC task column and activity labels.
-- Run from the repo root: luajit tests/butler_sessions_task.lua

local bus = { agents = {} }
local rows = {}
local remuda = {
  _butler_sessions_config = {
    bus = bus,
    mail = { unread = function() return 0 end },
    json_field = function() return nil end,
    identity_path = nil,
  },
  _butler_sandbox = {
    summary = function() return nil end,
    of = function() return nil end,
  },
  _butler_telemetry_for = function() return { model = "test-model" } end,
  session = {
    list = function() return rows end,
  },
  session_detail = function() return "working · opencode · test-model" end,
}
_G.remuda = remuda
-- Advance the roster clock faster than its 2 s status cache so each case is
-- observed, not answered from the previous state.
local now = 1000
remuda._butler_status_now = function()
  now = now + 10
  return now
end
dofile("packages/butler/sessions.lua")

local function set_agent(instance)
  bus.agents = {
    work = {
      kind = "opencode",
      alias = "work",
      instance_binding = 1,
      instance_id = instance,
    },
  }
end

local function set_row(instance, state, age, title)
  rows = { {
    name = "work",
    instance_id = instance,
    program_status = { state = state, app = "opencode", title = title },
    program_status_age = age,
  } }
end

local function task_for(output, name)
  for line in output:gmatch("[^\n]+") do
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    if fields[1] == name then return fields[5] end
  end
  return nil
end

local function activity_for(output, name)
  for line in output:gmatch("[^\n]+") do
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    if fields[1] == name then return (fields[4]:gsub("%s+$", "")) end
  end
  return nil
end

local function activity_pad_for(output, name)
  for line in output:gmatch("[^\n]+") do
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = field end
    if fields[1] == name then
      local cell = fields[4]
      return #cell - #(cell:gsub("%s+$", ""))
    end
  end
  return nil
end

local function expect(label, actual, wanted)
  assert(actual == wanted, label .. ": got " .. tostring(actual) .. ", wanted " .. tostring(wanted))
end

set_agent("inst-1")
set_row("inst-1", "working", 10, "Review OSC status end-to-end")
local out = remuda._butler_sessions()
expect("header", out:match("^([^\n]+)"), "SESSION\tAGENT\tLEADER\tACTIVITY\tTASK")
expect("fresh working title", task_for(out, "work"), "Review OSC status end-to-end")
expect("working label", activity_for(out, "work"), "🏃 working")
expect("working pad", activity_pad_for(out, "work"), 4)

set_row("inst-1", "working", 601, "Review OSC status end-to-end")
expect("stale working title", task_for(remuda._butler_sessions(), "work"), "-")

set_row("inst-1", "blocked", 3599, "Answer the permission prompt")
expect("fresh blocked title", task_for(remuda._butler_sessions(), "work"), "Answer the permission prompt")
expect("blocked label", activity_for(remuda._butler_sessions(), "work"), "🙋 needs you")
expect("blocked pad", activity_pad_for(remuda._butler_sessions(), "work"), 2)

set_row("inst-1", "blocked", 3601, "Answer the permission prompt")
expect("stale blocked title", task_for(remuda._butler_sessions(), "work"), "-")

set_row("inst-2", "working", 10, "A different process")
expect("instance mismatch", task_for(remuda._butler_sessions(), "work"), "-")

set_agent("inst-1")
for _, age in ipairs({ 0 / 0, math.huge, -1, "10" }) do
  set_row("inst-1", "working", age, "Malformed age")
  expect("malformed age " .. tostring(age), task_for(remuda._butler_sessions(), "work"), "-")
end

set_agent(nil)
set_row("inst-1", "working", 10, "Unbound agent")
expect("unbound agent", task_for(remuda._butler_sessions(), "work"), "-")

set_agent("inst-1")
set_row("inst-1", "idle", 10, "Not current work")
expect("idle title hidden", task_for(remuda._butler_sessions(), "work"), "-")
expect("idle label", activity_for(remuda._butler_sessions(), "work"), "😴 idle")
expect("idle pad", activity_pad_for(remuda._butler_sessions(), "work"), 7)

set_row("inst-1", "done", 10, "Finished work")
local done = remuda._butler_sessions()
expect("done reads idle", activity_for(done, "work"), "😴 idle")
expect("done title hidden", task_for(done, "work"), "-")

set_row("inst-1", "error", 10, "Failed work")
local failed = remuda._butler_sessions()
expect("error stays other", activity_for(failed, "work"), "other")
expect("other pad", activity_pad_for(failed, "work"), 9)
expect("error title hidden", task_for(failed, "work"), "-")

set_row("inst-1", "working", 10, "spoof\226\128\174 reversed \226\128\139 zero")
local cleaned = task_for(remuda._butler_sessions(), "work")
assert(not cleaned:find("\226\128\142", 1, true), "bidi control must be removed")
assert(not cleaned:find("\226\128\139", 1, true), "zero-width space must be removed")
expect("cleaned title", cleaned, "spoof reversed zero")

local long = string.rep("가", 40) -- 120 UTF-8 bytes
set_row("inst-1", "working", 10, long)
local bounded = task_for(remuda._butler_sessions(), "work")
assert(#bounded <= 67, "bounded title must stay short: " .. #bounded)
assert(bounded:sub(-3) == "…", "a truncated title must carry the marker")
assert(not bounded:find("\239\191\189", 1, true), "truncation must not split UTF-8")

-- The age comes from the report time on every render, with the daemon's
-- monotonic age as a floor. The test clock advances by 3 s per render to pass
-- the 2 s status cache.
local clock = 2000
remuda._butler_status_now = function() return clock end
local function render()
  clock = clock + 3
  return remuda._butler_sessions()
end
local function set_row_at(state, age, at, title)
  rows = { {
    name = "work",
    instance_id = "inst-1",
    program_status = { state = state, app = "opencode", title = title, last_updated_at = at },
    program_status_age = age,
  } }
end

set_agent("inst-1")

-- Canonical case: the age is derived from the report time, so it grows between
-- renders even when the snapshot age does not change (a cached row ages out).
local frozen = clock
set_row_at("working", 5, frozen - 596, "Cached row ages")
expect("cached row fresh within the limit", task_for(render(), "work"), "Cached row ages")
expect("cached row ages out from the timestamp", task_for(render(), "work"), "-")

-- Acceptance: only time passes between renders. The row and its snapshot age
-- stay unchanged, and the age derived from the absolute report time must grow
-- until the task disappears.
local base = clock
set_row_at("working", 0, base - 100, "Absolute age grows")
expect("100 s report is fresh", task_for(render(), "work"), "Absolute age grows")
clock = clock + 450
expect("same row stays fresh just under the limit", task_for(render(), "work"), "Absolute age grows")
clock = clock + 60
expect("same row is stale past the limit", task_for(render(), "work"), "-")

-- A timestamp older than the limit wins over a fresh snapshot age.
set_row_at("working", 5, clock - 700, "Old report time")
expect("old timestamp is not fresh", task_for(render(), "work"), "-")

-- A fresh wall clock cannot resurrect a stale monotonic age (clock rollback).
set_row_at("working", 700, clock, "Wall clock says fresh")
expect("stale monotonic age is not fresh", task_for(render(), "work"), "-")

-- A report in the current second is not from the future.
set_row_at("working", 5, clock + 0.6, "Same second")
expect("sub-second timestamp stays fresh", task_for(render(), "work"), "Same second")

-- A timestamp ahead of the clock is not evidence, even with a fresh age.
set_row_at("working", 5, clock + 120, "Future timestamp")
expect("future timestamp is not fresh", task_for(render(), "work"), "-")

-- A non-positive timestamp is not usable.
set_row_at("working", 5, -1, "Negative timestamp")
expect("negative timestamp is not fresh", task_for(render(), "work"), "-")

-- A future timestamp as the only evidence is unknown.
rows = { {
  name = "work",
  instance_id = "inst-1",
  program_status = { state = "working", app = "opencode", title = "Future only", last_updated_at = clock + 60 },
} }
expect("future timestamp only is not fresh", task_for(render(), "work"), "-")

-- The roster relists on every render: a grown snapshot age hides the task even
-- with an unchanged report time.
set_row_at("working", 5, clock, "Relist re-reads the age")
expect("fresh age shows the task", task_for(render(), "work"), "Relist re-reads the age")
rows[1].program_status_age = 601
expect("relist sees the grown age", task_for(render(), "work"), "-")

-- A malformed timestamp fails closed even with a fresh age.
set_row_at("working", 5, "not-a-time", "Malformed timestamp")
expect("malformed timestamp is not fresh", task_for(render(), "work"), "-")

-- An old core with no timestamp still uses the monotonic age.
rows = { {
  name = "work",
  instance_id = "inst-1",
  program_status = { state = "working", app = "opencode", title = "Old core row" },
  program_status_age = 10,
} }
expect("missing timestamp falls back to age", task_for(render(), "work"), "Old core row")

rows = { {
  name = "work",
  instance_id = "inst-1",
  program_status = { state = "working", app = "opencode", title = "No evidence" },
} }
expect("missing age is not fresh", task_for(render(), "work"), "-")

set_row_at("blocked", 5, clock, "Permission by age")
expect("blocked fresh by age", task_for(render(), "work"), "Permission by age")
set_row_at("blocked", 3601, clock, "Stale blocked")
expect("blocked age limit", task_for(render(), "work"), "-")

print("butler sessions task: ok")
