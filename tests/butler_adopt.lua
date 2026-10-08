-- Adoption on lead exit and the close authority rule. Run from the repository root:
--   luajit tests/butler_adopt.lua
local bus = { agents = {} }
local unread, idle, closed, exited, close_error = {}, {}, {}, {}, nil
local deeper, live_deeper = {}, {} -- deeper targets are closable by lineage only once exited
remuda = { extension_command = function() end, butler = { typed_lines_cli = {}, schedule_cli = {}, approve_text = { cli = function() end }, matrix = { cli_usage = function() return "" end },
    is_idle = function(name) if idle[name] == false then return false, "busy" end return true end },
  _butler_bus = bus,
  _butler_mail = nil,
  ls = function()
    local rows = {}
    for _, r in ipairs(exited) do rows[#rows + 1] = r end
    for n in pairs(deeper) do rows[#rows + 1] = { name = n, alive = false } end
    return rows
  end,
  close = function(name)
    if close_error then error(close_error, 0) end
    closed[#closed + 1] = name
  end,
  _butler_contribute = function() end }
local mail = { unread = function(id) return unread[id] or 0 end }
remuda._butler_sessions_config = { bus = bus, mail = mail, json_field = function() end }
remuda._butler_commands_config = { current_agent = function() end, OPERATOR = "operator",
  contributions = function() return {} end, registry_list = function() end,
  statusline = function() end, resolve = function(name)
    if not bus.agents[name] then error("unknown", 0) end
    return name
  end, mail = mail }
dofile("packages/butler/sessions.lua")
dofile("packages/butler/commands.lua")

local function tree(rows)
  bus.agents, closed = {}, {}
  for _, r in ipairs(rows) do
    bus.agents[r[1]] = { id = r[1] .. "-id", kind = "codex", parent = r[2], parent_id = r[2] and (r[2] .. "-id"), children = {} }
  end
  for name, agent in pairs(bus.agents) do
    if agent.parent and bus.agents[agent.parent] then
      table.insert(bus.agents[agent.parent].children, name)
    end
  end
end
-- what the exit path does: take the row out, then adopt its members
local function exit(name)
  local exited = bus.agents[name]
  bus.agents[name] = nil
  remuda._butler_adopt_members(name, exited)
end
local function can_close(leader, name, force, cli)
  closed, deeper = {}, {}
  local row = bus.agents[name]
  if row and row.parent ~= leader and not live_deeper[name] then deeper[name] = true end
  local ok = pcall(remuda._butler_close_member, name, leader, force, cli)
  return ok and closed[1] == name
end
local function has(list, x) for _, v in ipairs(list) do if v == x then return true end end end

-- adoption: two live members move to the lead's leader
tree({ {"butler"}, {"lead", "butler"}, {"m1", "lead"}, {"m2", "lead"}, {"other", "butler"} })
exit("lead")
assert(bus.agents.m1.parent == "butler" and bus.agents.m2.parent == "butler", "members re-parented to the lead's leader")
assert(has(bus.agents.butler.children, "m1") and has(bus.agents.butler.children, "m2"), "new parent lists them as children")
assert(can_close("butler", "m1") and can_close("butler", "m2"), "grandparent closes adopted members")

-- authority does not widen
tree({ {"butler"}, {"top", "butler"}, {"lead", "top"}, {"m1", "lead"}, {"sib", "top"}, {"other", "butler"}, {"om", "other"} })
exit("lead")
assert(bus.agents.m1.parent == "top")
assert(can_close("top", "m1"), "new parent closes")
for _, who in ipairs({ "sib", "other", "om", "m1" }) do
  assert(not can_close(who, "m1"), who .. " must not close adopted m1")
end
assert(can_close("butler", "m1"), "root closes a descendant below a live parent (remuda#606)")
assert(not can_close("top", "om"), "adoption does not widen to other leads' members")

-- chain: lead -> mid -> leaf; the lead exits, then mid exits
tree({ {"butler"}, {"top", "butler"}, {"lead", "top"}, {"mid", "lead"}, {"leaf", "mid"} })
exit("lead")
assert(bus.agents.mid.parent == "top" and bus.agents.leaf.parent == "mid", "only direct members move")
exit("mid")
assert(bus.agents.leaf.parent == "top", "grandchild chain re-parents step by step")

-- existing guards still apply to adopted rows
tree({ {"butler"}, {"lead", "butler"}, {"m1", "lead"} })
exit("lead")
unread["m1-id"] = 2
assert(not can_close("butler", "m1"), "unread mail still blocks")
assert(can_close("butler", "m1", true), "--force still overrides")
unread["m1-id"], idle.m1 = nil, false
assert(not can_close("butler", "m1"), "busy still blocks")
idle.m1 = nil

-- the lead had no live leader: members go to root
tree({ {"butler"}, {"lead", "GONE"}, {"m1", "lead"} })
exit("lead")
assert(bus.agents.m1.parent == "butler", "no live leader -> root")

-- root closes leader-less rows (old orphans, or no parent at all)
tree({ {"butler"}, {"orphan", "DEAD"}, {"free"}, {"lead", "butler"}, {"m", "lead"} })
assert(can_close("butler", "orphan", nil, true), "root closes an orphan")
assert(can_close("butler", "free", nil, true), "root closes a parentless row")
assert(not can_close("butler", "butler"), "root never closes itself")
assert(not can_close("lead", "orphan") and not can_close("m", "free"), "non-root cannot close leader-less rows")
assert(can_close("butler", "m"), "root closes a grandchild whose parent is alive (remuda#606)")
assert(not can_close("butler", "orphan") and not can_close("butler", "free"), "an MCP caller (no CLI flag) never closes leader-less rows")
remuda._butler_relaunching = { DEAD = os.time() }
assert(not can_close("butler", "orphan", nil, true), "a lead that is relaunching still has its members")
remuda._butler_relaunching = { DEAD = os.time() - 1000 }
assert(can_close("butler", "orphan", nil, true), "a stale relaunch marker expires")
remuda._butler_relaunching = nil

-- A finished pane can retain an arbitrary last screen. It is still closable
-- without force, and unread/busy/composer gates do not apply to an exited process.
-- Before this regression fix, the exact failure was: `finished is not idle: composer not empty`.
tree({ {"butler"}, {"finished", "butler"} })
exited = { { name = "finished", alive = false } }
remuda.butler.is_idle = function() return false, "composer not empty" end
unread["finished-id"] = 2
local close_ok, close_result = pcall(remuda._butler_close_member, "finished", "butler", false, true)
assert(close_ok and close_result == "Closed finished.\nNext: remuda butler sessions"
  and closed[1] == "finished", "finished member closes despite its stale composer screen")

-- A live row sharing the name with a stale exited row stays authoritative: the live-session gates still apply.
closed = {}
exited = { { name = "finished", alive = false }, { name = "finished", alive = true } }
local live_ok, live_err = pcall(remuda._butler_close_member, "finished", "butler", false, true)
assert(not live_ok and tostring(live_err):find("unread Butler mail", 1, true) and #closed == 0,
  "a live row for the same name keeps the close gates")

-- A failed forced close raises a readable message (the CLI turns it into exit 1 via cli_result), never a bare Lua error.
closed, close_error = {}, "session already gone"
local returned, failure = pcall(remuda._butler_close_member, "finished", "butler", true, true)
assert(not returned and failure:find("could not close finished: session already gone", 1, true)
  and failure:find("Next: retry remuda butler close finished", 1, true),
  "--force close failure raises a readable message, not a success string")
exited, close_error, remuda.butler.is_idle = {}, nil, function(name)
  if idle[name] == false then return false, "busy" end
  return true
end
-- stale generations (sec-463b): a recorded parent_id that no longer matches is never rebound or honored
tree({ {"butler"}, {"top", "butler"}, {"lead", "top"}, {"m1", "lead"}, {"m2", "lead"} })
assert(can_close("lead", "m1"), "healthy direct member closes")
bus.agents.m1.parent_id = "stale-id"
assert(not can_close("lead", "m1"), "direct edge with a mismatched parent_id refuses")
exit("lead")
assert(bus.agents.m1.parent == "lead" and bus.agents.m1.parent_id == "stale-id", "stale child is not adopted")
assert(not can_close("top", "m1") and not can_close("butler", "m1"), "stale child is not closable via the heir")
assert(bus.agents.m2.parent == "top" and bus.agents.m2.parent_id == "top-id" and can_close("top", "m2"), "healthy sibling still adopted")
tree({ {"butler"}, {"top", "butler"}, {"lead", "top"}, {"m1", "lead"} })
bus.agents.lead.parent_id = "stale-id" -- the exiting row itself belongs to a stale parent generation
exit("lead")
assert(bus.agents.m1.parent == "butler" and bus.agents.m1.parent_id == "butler-id", "stale exiting parent: members go to the root")
assert(not can_close("top", "m1"), "stale heir alias does not gain the members")

-- deeper descendants close by lineage only once exited; force does not widen that
tree({ {"butler"}, {"top", "butler"}, {"lead", "top"}, {"m1", "lead"} })
live_deeper.m1 = true
assert(not can_close("butler", "m1") and not can_close("butler", "m1", true), "live deeper descendant refused, even forced")
assert(#closed == 0 and bus.agents.m1.parent == "lead", "refusal has no effect")
live_deeper.m1 = nil
assert(can_close("butler", "m1"), "exited deeper descendant closes")
assert(can_close("top", "lead"), "idle live direct member still closes")
print("ok - adoption and close authority")
