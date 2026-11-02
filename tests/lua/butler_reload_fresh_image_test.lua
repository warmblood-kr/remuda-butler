-- `remuda reload` (remuda#713, docs/reload.md): the old daemon runs the module
-- stop hooks and exits; the new daemon runs init.lua in a fresh Lua image while
-- host-backed sessions keep their names, processes and instance ids. This test
-- plays that in one daemon: stop the module, drop every Butler global, start
-- Butler again. The sessions never stop, exactly as across a reload.
local repo = assert(os.getenv("REMUDA_LUA_REPO"))
T.install_mod("butler", repo)
-- The core words Butler wraps, as a fresh image has them.
T.eval('remuda._reload_test_core = { key = remuda.key, type_text = remuda.type_text, send = remuda.send, close = remuda.close }')
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 100"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
T.eval('return remuda.exec("butler")')
local function truthy(code) return T.eval(code):match("^%s*true%s*$") ~= nil end
T.wait_until(function()
  return truthy('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil'
    .. ' and remuda._butler_bus.agents.butler.instance_id ~= nil')
end, 10, "Butler root start")

local SETUP = string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_launch("codex", "alice")
  remuda._butler_launch("codex", "bob", nil, "alice")
  remuda._butler_send("butler", "alice", "queued before the reload")
]], os.getenv("XDG_DATA_HOME") .. "/projects")
T.eval(SETUP)

local SNAPSHOT = [[
  local bus = remuda._butler_bus
  local inst = {}
  for _, row in ipairs(remuda.ls()) do if row.alive then inst[row.name] = row.instance_id end end
  local a, b = bus.agents.alice or {}, bus.agents.bob or {}
  return table.concat({ tostring(inst.butler), tostring(inst.alice), tostring(inst.bob),
    tostring(bus.agents.butler.id), tostring(a.id), tostring(b.id), tostring(b.parent),
    tostring(a.id and remuda._butler_mail.unread(a.id)) }, "|")
]]

-- What the old daemon does (stop hooks), then what the new one starts from
-- (a fresh image: no Butler globals at all), then init.lua again.
local RELOAD = [[
  -- The old activation's stop hook unwraps input; a fresh image has no
  -- Butler wrappers on any core word.
  for word, fn in pairs(remuda._reload_test_core) do remuda[word] = fn end
  local names = {}
  for key in pairs(remuda) do
    if type(key) == "string" and (key:match("^_butler") or key == "butler") then names[#names + 1] = key end
  end
  for _, key in ipairs(names) do remuda[key] = nil end
  remuda._butler_argv = {"sh", "-c", "sleep 100"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1
  remuda.reload("butler")
  return "reloaded"
]]

local before
T.test("setup_has_a_root_two_members_and_unread_mail", function()
  T.wait_until(function()
    return truthy('local a = remuda._butler_bus.agents return a.alice ~= nil and a.bob ~= nil')
  end, 10, "members registered")
  before = T.eval(SNAPSHOT)
  local f = {}
  for part in (before .. "|"):gmatch("(.-)|") do f[#f + 1] = part end
  T.ok(f[1] ~= "nil" and f[2] ~= "nil" and f[3] ~= "nil", "all three sessions live: " .. before)
  T.eq(f[7], "alice", "bob's leader")
  T.eq(f[8], "2", "alice has her welcome and the queued mail unread")
end)

T.test("a_fresh_image_keeps_live_members_root_and_queued_mail", function()
  T.eval(RELOAD)
  T.wait_until(function()
    return truthy('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil'
      .. ' and not remuda._butler_launching')
  end, 10, "Butler start after the fresh image")
  local after = T.eval(SNAPSHOT)
  T.eq(after, before, "same sessions (instances), identities, leaders and unread mail")
  -- Nothing was swept: no `ended` row for either member in agents.jsonl.
  local ended = T.eval([[
    local f = assert(io.open(remuda._butler_identity.identity_path))
    local text = f:read("a"); f:close()
    local n = 0
    for line in text:gmatch("[^\n]+") do
      if line:find('"state":"ended"', 1, true) then n = n + 1 end
    end
    return n
  ]])
  T.eq(ended, "0", "no identity was marked ended")
end)

T.test("members_still_act_after_the_fresh_image", function()
  -- Caller attribution: the member's own session (with its instance) reads its inbox.
  local inbox = T.eval([[
    local inst
    for _, row in ipairs(remuda.ls()) do if row.name == "alice" then inst = row.instance_id end end
    local ok, out = pcall(remuda._butler_command_run, "inbox", { "inbox" },
      { kind = "session", session = "alice", instance_id = inst })
    return tostring(ok) .. "|" .. tostring(out)
  ]])
  T.ok(inbox:find("^true|") and inbox:find("queued before the reload", 1, true), "alice reads her mail: " .. inbox)
  -- New mail reaches a member, and a member can report to its leader.
  local sent = T.eval([[
    local ok, err = pcall(remuda._butler_send, "butler", "bob", "after the reload")
    local reported, why = pcall(remuda._butler_report, "bob", "bob reports")
    return tostring(ok) .. "|" .. tostring(reported) .. "|" .. tostring(ok and "" or err) .. tostring(reported and "" or why)
  ]])
  T.eq(sent, "true|true|", "mail flows to and from members")
end)

T.test("a_member_closed_after_the_fresh_image_is_recorded_ended", function()
  T.eval('remuda.close("bob")')
  T.wait_until(function()
    return truthy([[
      local rec = remuda._butler_bus.identities.bob
      return rec ~= nil and rec.state == "ended" and remuda._butler_bus.agents.bob == nil
    ]])
  end, 10, "bob's exit recorded")
end)

T.test("the_roster_file_is_private_and_holds_no_capability_or_mail", function()
  local out = T.eval([[
    local path = remuda._butler_roster.path
    local f = assert(io.open(path, "rb")); local text = f:read("a"); f:close()
    local leaked = {}
    for token in pairs(remuda._butler_bus.tokens) do
      if text:find(token, 1, true) then leaked[#leaked + 1] = "token" end
    end
    for _, needle in ipairs({ "queued before the reload", "after the reload", "Welcome to Butler" }) do
      if text:find(needle, 1, true) then leaked[#leaked + 1] = needle end
    end
    local mode = remuda.process.run({ argv = { "ls", "-l", path }, timeout = 5 }).stdout:sub(1, 10)
    return mode .. "|" .. table.concat(leaked, ",")
  ]])
  T.eq(out, "-rw-------|", "0600 and no tokens or message text")
end)

T.test("only_the_same_live_instance_with_a_running_identity_is_adopted", function()
  local out = T.eval([[
    local bus, roster = remuda._butler_bus, remuda._butler_roster
    local saved_agents, saved_tokens = bus.agents, bus.tokens
    local rows = roster.load()
    local function adopt(ls)
      bus.agents, bus.tokens = {}, setmetatable({}, { __index = saved_tokens })
      local ok, got = pcall(roster.adopt, ls)
      bus.agents, bus.tokens = saved_agents, saved_tokens
      return ok and table.concat(got, ",") or ("error " .. tostring(got))
    end
    local same, reused, dead = {}, {}, {}
    for _, row in ipairs(rows) do
      same[#same + 1] = { name = row.session_name, alive = true, instance_id = row.instance_id }
      reused[#reused + 1] = { name = row.session_name, alive = true, instance_id = row.instance_id .. "-new" }
      dead[#dead + 1] = { name = row.session_name, alive = false, instance_id = row.instance_id }
    end
    local in_image = (pcall(roster.adopt, same)) and #roster.adopt(same) or -1
    return adopt(same) .. "|" .. adopt(reused) .. "|" .. adopt(dead) .. "|" .. in_image
  ]])
  -- bob was closed: only the root and alice are still in the roster.
  T.eq(out, "alice,butler|||0", "same instance only, and never in a populated image")
end)
