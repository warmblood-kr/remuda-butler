T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')

T.test("topic_names_cannot_escape_the_project_home", function()
  T.eq(T.eval([=[
    local data = os.getenv("XDG_DATA_HOME")
    remuda.butler.project_home(data .. "/projects")
    remuda._butler_agent_builders.fake = function() return { "sleep", "20" } end
    local rejected = {}
    for _, name in ipairs({ "../escape", "back\\slash", ".hidden", "line\nbreak" }) do
      local ok = pcall(remuda._butler_topic_new, name, nil, "fake")
      rejected[#rejected + 1] = tostring(not ok)
    end
    return table.concat(rejected, ",")
  ]=]), "true,true,true,true", "unsafe topic name was accepted")
  -- "../escape" would land beside project_home, in the data home.
  local entries = "," .. T.eval([=[return table.concat(remuda.list_dir(os.getenv("XDG_DATA_HOME")), ",")]=]) .. ","
  T.ok(entries:find(",remuda,", 1, true), "data home listing is empty or unreadable: " .. entries)
  T.ok(not entries:find(",escape,", 1, true), "traversal topic created a directory outside project_home")
end)

T.test("launch_cwd_rejects_control_characters", function()
  T.eq(T.eval([=[
    local cwd = os.getenv("XDG_DATA_HOME") .. "/cwd\nnotice-injection"
    remuda.mkdir(cwd)
    local made = false
    for _, entry in ipairs(remuda.list_dir(os.getenv("XDG_DATA_HOME"))) do
      if entry == "cwd\nnotice-injection" then made = true end
    end
    remuda._butler_agent_builders.claude = function() return { "sleep", "20" } end
    local token = remuda._butler_bus.agents.butler.token
    pcall(remuda._call, "butler_launch",
      { kind = "claude", name = "badcwd", cwd = cwd }, { capability = token })
    return tostring(made) .. "," .. tostring(remuda._butler_bus.agents.badcwd ~= nil)
  ]=]), "true,false", "cwd was not created, or launch accepted a control character in it")
end)
