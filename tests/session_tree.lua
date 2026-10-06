local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. "\nexpected: " .. tostring(expected) .. "\nactual: " .. tostring(actual))
end
local function assert_no_blank_rows(output, context)
  assert(not output:find("\n\n", 1, true), context .. " contains a blank spacer row")
  assert(output:sub(-1) ~= "\n", context .. " has a trailing blank row")
end
local function fixture(rows)
  local agents = {}
  for _, row in ipairs(rows) do
    agents[row[1]] = { kind = row[2], parent = row[3] }
  end
  remuda._butler_bus.agents = agents
  local output = remuda._butler_sessions()
  assert_no_blank_rows(output, "fixture roster")
  return output
end
local function displayed_rows(output)
  local rows = {}
  for line in output:gmatch("[^\n]+") do rows[#rows + 1] = line end
  return rows
end

local rows = displayed_rows(fixture({
  {"root", "claude"},
  {"zeta", "claude", "root"},
  {"alpha", "codex", "root"},
  {"worker", "codex", "alpha"},
}))
assert_equal(rows[1], "SESSION\tAGENT\tLEADER", "roster header")
assert_equal(rows[2], "root\tclaude\t-", "root row")
-- View policy: a root (butler) and its direct children sit at the margin;
-- indentation starts at grandchildren (indent = max(0, depth - 1)).
assert_equal(rows[3], "alpha\tcodex\troot", "direct child stays at the margin")
assert_equal(rows[4], "  worker\tcodex\talpha", "grandchild is the first indented row")
assert_equal(rows[5], "zeta\tclaude\troot", "sorted second child")

-- The client's session pane asks the same tree for its order (core's
-- remuda.session_order hook): same walk, depth per row, names as sessions.
fixture({
  {"root", "claude"},
  {"zeta", "claude", "root"},
  {"alpha", "codex", "root"},
  {"worker", "codex", "alpha"},
  {"lost", "codex", "MISSING_PARENT"},
})
assert(type(remuda.session_order) == "function", "butler provides the session_order hook")
local order = remuda.session_order(remuda.ls())
local seen = {}
for index, item in ipairs(order) do seen[index] = item.name .. "@" .. item.depth end
assert_equal(table.concat(seen, " "), "root@0 alpha@0 worker@1 zeta@0 lost@0",
  "pane order and indent match the roster, orphans last at the margin")
rows = displayed_rows(fixture({
  {"root-b", "codex"},
  {"root-a", "claude"},
  {"orphan", "codex", "MISSING_PARENT"},
  {"cycle-a", "claude", "cycle-b"},
  {"cycle-b", "codex", "cycle-a"},
}))
assert_equal(rows[2], "root-a\tclaude\t-", "roots are sorted")
assert_equal(rows[3], "root-b\tcodex\t-", "all roots are rendered")
local found_orphan, found_cycle_a, found_cycle_b = false, false, false
local seen = {}
for _, line in ipairs(rows) do
  assert(line ~= "", "roster contains a blank row")
  if line == "[orphan] orphan\tcodex\tMISSING_PARENT" then found_orphan = true end
  if line:find("cycle-a", 1, true) then found_cycle_a = true end
  if line:find("cycle-b", 1, true) then found_cycle_b = true end
  local display = line:match("^[^\t]+")
  if display then
    display = display:gsub("^ *", ""):gsub("^%[orphan%] ", "")
    if display ~= "SESSION" then
      assert(not seen[display], "duplicate roster row: " .. display)
      seen[display] = true
    end
  end
end
assert(found_orphan, "orphan row is marked and retains its missing parent")
assert(found_cycle_a and found_cycle_b, "cycle members are visible")
assert_equal((function() local n=0 for _ in pairs(seen) do n=n+1 end return n end)(), 5, "every graph record appears once")

-- The pane's detail line: current context usage only, in K.
fixture({{"root", "claude"}})
local real_telemetry = remuda._butler_telemetry_for
local real_capture = remuda.capture
remuda.capture = function() error("no pane") end -- no screen: status is "other"
remuda._butler_telemetry_for = function()
  return { model = "opus", context_used = "123456", context_window = "1000000", context_percent = "12" }
end
assert_equal(remuda.session_detail({ name = "root" }), "other · claude · opus · 123K 12%", "detail shows usage in K and percent")
remuda._butler_telemetry_for = function()
  return { model = "opus", context_used = "?", context_window = "?", context_percent = "?" }
end
assert_equal(remuda.session_detail({ name = "root" }), "other · claude · opus", "unknown usage is left out")

-- Unread mail: the recipient's unread count, and nothing once it is read.
local root_id = "01TESTUNREADC0UNT000000000"
remuda._butler_bus.agents.root.id = root_id
local to_root = { host = "local", id = root_id, alias = "root", session = "root" }
assert_equal(remuda.session_detail({ name = "root" }), "other · claude · opus", "no mail, no count")
remuda._butler_mail.queue("operator", to_root, "one")
remuda._butler_mail.queue("operator", to_root, "two")
assert_equal(remuda.session_detail({ name = "root" }), "other · claude · opus · ✉2", "unread count")
remuda._butler_mail.inbox(root_id)
assert_equal(remuda.session_detail({ name = "root" }), "other · claude · opus", "read mail is not counted")
remuda._butler_telemetry_for = real_telemetry
remuda.capture = real_capture

local deep = {{"depth-0", "claude"}}
for depth = 1, 26 do deep[#deep + 1] = {"depth-" .. depth, "codex", "depth-" .. (depth - 1)} end
rows = displayed_rows(fixture(deep))
assert_equal(#rows, 28, "header plus all 27 agents")
for index = 2, #rows do
  local alias, kind, leader = rows[index]:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
  assert(alias and kind and leader, "compact three-column row: " .. rows[index])
  local indent = #(alias:match("^ *"))
  assert(indent <= 40 and indent % 2 == 0, "bounded two-space indentation")
  assert(not kind:match("^ ") and not leader:match("^ "), "only session display column is indented")
  local depth = tonumber(alias:match("depth%-(%d+)$"))
  assert(depth and indent == math.min(math.max(0, depth - 1), 20) * 2,
    "indent starts at grandchildren and caps at 40 spaces")
end
return "sessions tree acceptance passed: parent-first, stable siblings, roots/orphans/cycles, 40-space cap, compact columns"
