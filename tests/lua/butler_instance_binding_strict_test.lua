-- Strict instance binding by environment: REMUDA_BUTLER_STRICT_INSTANCE_BINDING=1 in the daemon's environment
-- refuses every protected route for an unbound member. The Lua override is covered in butler_instance_binding_test.lua.
T.child_env = { REMUDA_BUTLER_STRICT_INSTANCE_BINDING = "1" }
local function ev(code) return (T.eval(code):gsub("%s+$", "")) end

-- Setup runs inside a test: a T.eval before the child starts would launch the daemon without T.child_env.
local ready
local function setup()
  if ready then return end
  ready = true
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 5, "Butler root start")
  T.eval(string.format([[
    remuda.butler.project_home(%q)
    remuda._butler_agent_builders.codex = function() return { "sleep", "60" } end
  ]], os.getenv("XDG_DATA_HOME") .. "/projects"))
end

T.test("the_environment_reaches_the_daemon", function() -- guard for the harness seam
  setup()
  T.eq(ev("return os.getenv('REMUDA_BUTLER_STRICT_INSTANCE_BINDING')"), "1")
end)

T.test("strict_env_refuses_an_unbound_member_on_every_protected_route", function()
  setup()
  T.eval("return remuda._butler_launch('codex', 'unbound')")
  -- a member from before the upgrade: no bound id on the row or the capability
  T.eval("local a = remuda._butler_bus.agents.unbound; a.instance_id, remuda._butler_bus.tokens[a.token].instance_id = nil, nil")
  local function snapshot()
    return ev([[local bus, n = remuda._butler_bus, 0
      for _ in pairs(bus.messages) do n = n + 1 end
      for _, rows in pairs(bus.inboxes) do n = n + #rows end
      return n .. ':' .. bus.next]])
  end
  local before = snapshot()
  local caller = "{ kind = 'session', session = 'unbound', instance_id = 'WHATEVER' }"
  for _, route in ipairs({ { "butler_send", "{ to = 'butler', text = 'x' }" }, { "butler_inbox", "{}" } }) do
    local name, args = route[1], route[2]
    local result = ev([[
      local tool; for k, v in pairs(remuda.tools) do if k == ']] .. name .. [[' or (type(v) == 'table' and v.name == ']] .. name .. [[') then tool = v end end
      local ok, err = pcall(tool.run, ]] .. args .. ", " .. caller .. [[)
      return ok and 'ok' or 'err' ]])
    T.eq(result, "err", name .. ": strict mode must refuse an unbound member")
  end
  T.eq(snapshot(), before, "strict refusals have zero effects")
  T.eval("return remuda.close('unbound')")
end)
