-- Current-main local parity control. No daemon, no live state, no publisher stub.
local agents = {
  root = { id = "root", kind = "codex" },
  child = { id = "child", kind = "codex", parent = "root" },
  leaf = { id = "leaf", kind = "codex", parent = "child" },
}
remuda = { _butler_sessions_config = {
  bus = { agents = agents }, mail = { unread = function() return 0 end },
  json_field = function() return nil end,
} }
dofile("packages/butler/sessions.lua")
local order = remuda.session_order()
local expected = { {name="root",depth=0}, {name="child",depth=0}, {name="leaf",depth=1} }
assert(#order == #expected, "local roster target count changed")
for index, row in ipairs(expected) do
  assert(order[index].name == row.name and order[index].depth == row.depth,
    "local root/child/leaf order or existing margins changed")
end
print("PASS local root->child->leaf relations/order and existing margins 0/0/1")
-- Historical #559 publisher RED remains supporting evidence in the old-head
-- checkout. Main has no publisher; do not manufacture a behavioral failure.
local publisher = io.open("packages/butler/session_display.lua", "r")
if not publisher then
  io.stderr:write("BASELINE PREREQUISITE MISSING: main has no display publisher; "
    .. "automatic publication and durable-ID runtime examples are unsupported here, not RED.\n")
  os.exit(77)
end
publisher:close()
print("Publisher prerequisite now exists: run the owner-side runtime contract suite.")
