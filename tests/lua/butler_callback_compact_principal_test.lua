T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_launch("codex", "alice")
  remuda._butler_launch("codex", "bob")
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

local function eval(code) return T.eval(code) end

T.test("compact_callback_refuses_unidentified_before_mutating_the_member", function()
  local result = eval([[
    local saved = remuda.butler.compact
    local calls = 0
    remuda.butler.compact = function() calls = calls + 1; return "compacted" end
    local refused = 0
    for _, c in ipairs({{kind = "unknown"}, {}, {kind = "session", session = "unregistered"}}) do
      local ok, out = pcall(remuda._extension_commands.butler, {"compact", "alice", "--force"}, c)
      if not ok and tostring(out):find("Next:", 1, true) then refused = refused + 1 end
    end
    remuda.butler.compact = saved
    return refused .. "|" .. calls
  ]])
  T.eq(result, "3|0")
end)
