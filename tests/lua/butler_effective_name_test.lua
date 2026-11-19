-- The effective physical session name in a real child daemon: default,
-- opt-in override, invalid refusal, a fresh-daemon restart, and the durable
-- record. Run through tests/lua_tests.sh.
local repo = assert(os.getenv("REMUDA_LUA_REPO"))
local exe = assert(os.getenv("REMUDA_BIN"))
local child_server = assert(os.getenv("REMUDA_LUA_CHILD_SERVER"))
local config_home = assert(os.getenv("XDG_CONFIG_HOME"))
local data_home = assert(os.getenv("XDG_DATA_HOME"))
local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end
-- A fresh image per test: the module caches its loaded state.
local function restart_child()
  -- --yes/--i-am-inside: an intentional stop; a bare -f is refused while
  -- sessions are live and would keep the old image.
  remuda.process.run {
    argv = { exe, "-s", child_server, "stop", "-f", "--yes", "--i-am-inside" },
    timeout = 30,
  }
end
local function fields(text)
  local out = {}
  for field in (text .. "|"):gmatch("(.-)|") do out[#out + 1] = field end
  return out
end

T.test("the default effective name stays butler", function()
  T.install_mod("butler", repo)
  restart_child()
  T.eval("remuda._butler_test_mode = true")
  T.eval('return remuda.exec("butler")')
  T.eq(T.eval("return remuda._butler_initial_name"), "butler",
    "default effective name")
  T.eq(T.eval("return remuda._butler_initial_name_source"), "default",
    "default source")
end)

T.test("an override selects only the physical name", function()
  restart_child()
  T.eval("remuda._butler_test_mode = true")
  T.eval('remuda._butler_initial_name_override = "butler-alt"')
  T.eval('return remuda.exec("butler")')
  T.eq(T.eval("return remuda._butler_initial_name"), "butler-alt",
    "override became the session name")
  T.eq(T.eval("return remuda._butler_initial_name_source"), "override",
    "override source")
  T.eq(T.eval("return remuda._butler_effective_name.default_name()"), "butler",
    "the logical default is unchanged")
  T.eq(T.eval("return (remuda._butler_effective_name.resolve(nil, nil, nil))"), "butler",
    "resolution without input still yields butler")
end)

T.test("an invalid override refuses instead of silently using butler", function()
  restart_child()
  local result = T.eval([[
    remuda._butler_test_mode = true
    remuda._butler_initial_name_override = "bad name"
    local ok, value = pcall(remuda.exec, "butler")
    return table.concat({
      tostring(ok),
      tostring(remuda._butler_initial_name ~= nil),
      tostring(tostring(value):find("invalid", 1, true) ~= nil),
    }, ",")
  ]])
  T.eq(result, "false,false,true",
    "an invalid override refuses, picks no name, and says why")
end)

T.test("a fresh daemon re-applies the installer override across a restart", function()
  restart_child()
  -- Exactly the line install-butler.sh writes; no exec here, so the child
  -- boot itself must have evaluated this file.
  remuda.mkdir(config_home .. "/remuda")
  write_file(config_home .. "/remuda/init.lua",
    'remuda._butler_initial_name_override = "butler-alt"\n')
  T.eq(T.eval("return remuda._butler_initial_name_override"), "butler-alt",
    "the fresh daemon evaluated the persisted override")
  T.eval("remuda._butler_test_mode = true")
  T.eval('return remuda.exec("butler")')
  T.eq(T.eval("return remuda._butler_initial_name"), "butler-alt",
    "the restarted daemon kept the physical name")
  T.eq(T.eval("return remuda._butler_initial_name_source"), "override",
    "restart source")
end)

T.test("the durable record names the physical session after a restart", function()
  restart_child()
  os.remove(config_home .. "/remuda/init.lua")
  remuda.mkdir(data_home .. "/remuda/butler")
  write_file(data_home .. "/remuda/butler/effective-name",
    "version=1\nlogical=butler\nname=butler-alt\ninstance=\n")
  -- "lifecycle" loads the whole module without bootstrapping a launch.
  local result = T.eval([[
    remuda._butler_test_mode = "lifecycle"
    remuda.exec("butler")
    local bus = remuda._butler_bus
    local root = bus and bus.agents and bus.agents.butler
    return tostring(remuda._butler_initial_name) .. "|"
      .. tostring(remuda._butler_initial_name_source) .. "|"
      .. tostring(remuda._butler_memory_dir("butler")) .. "|"
      .. tostring(root and root.alias) .. "|"
      .. tostring(root and root.session_name)
  ]])
  local name, source, memory, alias, session_name = table.unpack(fields(result))
  T.eq(name, "butler-alt", "the record supplied the physical name")
  T.eq(source, "recorded", "record source")
  T.eq(alias, "butler", "the logical identity alias is still butler")
  T.eq(session_name, "butler-alt", "the root agent points at the physical session")
  T.ok(tostring(memory):match("/remuda/butler/memory/butler$") ~= nil,
    "memory stays keyed to the logical name: " .. tostring(memory))
  T.eq(T.eval("return remuda._butler_effective_name.logical_for("
    .. "{{alias='butler', session_name='butler-alt'}}, 'butler-alt')"), "butler",
    "routing resolves the physical session back to the logical alias")
end)

T.test("a real launch uses the physical name and keeps the logical identity", function()
  restart_child()
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
  T.eval('remuda._butler_initial_name_override = "butler-alt"')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval([[
      local b = remuda._butler_bus
      if not (b and b.agents.butler and b.agents.butler.session_name == "butler-alt") then return false end
      for _, row in ipairs(remuda.ls()) do
        if row.name == "butler-alt" and row.alive then return true end
      end
      return false
    ]]):match("^%s*true%s*$") ~= nil
  end, 10, "root under butler-alt")
  local result = T.eval([[
    local b = remuda._butler_bus
    local root = b.agents.butler
    local rec = io.open(assert(os.getenv("XDG_DATA_HOME")) .. "/remuda/butler/effective-name", "r")
    local text = rec and rec:read("a") or ""
    if rec then rec:close() end
    return table.concat({ root.alias, root.session_name,
      tostring(text:find("name=butler-alt", 1, true) ~= nil),
      tostring(text:find("instance=", 1, true) ~= nil),
      tostring(remuda._butler_memory_dir("butler")) }, "|")
  ]])
  local alias, session, named, instance, memory = table.unpack(fields(result))
  T.eq(alias, "butler", "the logical alias is still butler")
  T.eq(session, "butler-alt", "the root runs under the physical name")
  T.eq(named, "true", "the durable record names the physical session")
  T.eq(instance, "true", "the durable record carries an instance field")
  T.ok(tostring(memory):match("/remuda/butler/memory/butler$") ~= nil,
    "memory stays keyed to the logical name: " .. tostring(memory))
end)
