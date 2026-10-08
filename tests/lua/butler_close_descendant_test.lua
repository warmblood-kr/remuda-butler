-- remuda#606: an ancestor closes a finished descendant below its direct members
-- (leader-of-leader), with the normal close gates; siblings, the descendant
-- itself and other branches still cannot.
local repo = assert(os.getenv("REMUDA_LUA_REPO"))
local started

local function start_butler()
  if started then return end
  started = true
  T.install_mod("butler", repo)
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "Butler root start")
end

-- Runs every case in one daemon call against a stubbed roster, close and idle
-- check, then restores them, so the live roster never sees the fake rows.
local function outcomes()
  return T.eval([=[
    local bus = remuda._butler_bus
    local saved = { agents = bus.agents, close = remuda.close, ls = remuda.ls, idle = remuda.butler.is_idle }
    local closed, busy = {}, {}
    bus.agents = {}
    for _, row in ipairs({ { "butler" }, { "lead", "butler" }, { "leaf", "lead" }, { "deep", "leaf" },
        { "sib", "butler" }, { "sibleaf", "sib" }, { "loop1", "loop2" }, { "loop2", "loop1" } }) do
      bus.agents[row[1]] = { id = row[1] .. "-606-id", kind = "codex", parent = row[2], session_name = row[1] }
    end
    remuda.close = function(name) closed[#closed + 1] = name end
    remuda.ls = function() return {} end
    remuda.butler.is_idle = function(name) if busy[name] then return false, "busy" end return true end
    local out = {}
    local function try(label, leader, name, force, cli)
      closed = {}
      local ok = pcall(remuda._butler_close_member, name, leader, force, cli)
      out[#out + 1] = label .. "=" .. ((ok and closed[1] == name) and "closed" or "refused")
    end
    local ok, err = pcall(function()
      try("root-grandchild", "butler", "leaf", false, true)
      try("root-great-grandchild", "butler", "deep", false, true)
      try("lead-grandchild", "lead", "deep", false, true)
      try("mcp-lead-grandchild", "lead", "deep", false, nil)
      try("lead-direct", "lead", "leaf", false, true)
      try("sibling-branch", "sib", "deep", false, true)
      try("other-branch", "lead", "sibleaf", false, true)
      try("child-closes-ancestor", "leaf", "lead", false, true)
      try("self", "leaf", "leaf", false, true)
      try("root-row", "lead", "butler", true, true)
      try("parent-cycle", "butler", "loop1", false, nil)
      busy.deep = true
      try("busy-grandchild", "butler", "deep", false, true)
      try("busy-grandchild-force", "butler", "deep", true, true)
    end)
    bus.agents, remuda.close, remuda.ls, remuda.butler.is_idle = saved.agents, saved.close, saved.ls, saved.idle
    if not ok then error(err, 0) end
    return table.concat(out, " ")
  ]=])
end

T.test("ancestor closes finished descendants, others still refused", function()
  start_butler()
  T.eq(outcomes(), table.concat({
    "root-grandchild=closed", "root-great-grandchild=closed", "lead-grandchild=closed",
    "mcp-lead-grandchild=closed", "lead-direct=closed",
    "sibling-branch=refused", "other-branch=refused", "child-closes-ancestor=refused", "self=refused",
    "root-row=refused", "parent-cycle=refused",
    "busy-grandchild=refused", "busy-grandchild-force=closed",
  }, " "), "close authority over descendants")
end)
