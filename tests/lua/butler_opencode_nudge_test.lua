-- The OpenCode completion nudge: the plugin file Butler writes, the config
-- fragment that opts a member's private server into it, and JSON validity.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))

T.test("opencode_nudge_writes_the_plugin_under_the_member_data_home", function()
  T.eq(T.eval([=[
    remuda.exec('butler/opencode_nudge')
    local nudge = remuda.butler.opencode_nudge
    local home = remuda.butler_paths and remuda.butler_paths.data_home or os.getenv('XDG_DATA_HOME')
    local dir, err = nudge.ensure(home)
    assert(dir, err)
    local f = assert(io.open(dir .. '/index.js', 'rb'))
    local body = f:read('*a')
    f:close()
    local again = nudge.ensure(home)
    return table.concat({ tostring(dir:match('/remuda/butler/opencode/completion%-nudge$') ~= nil),
      tostring(body:find('remuda.completion-nudge', 1, true) ~= nil),
      tostring(body:find('REMUDA_BUTLER_AGENT_KIND', 1, true) ~= nil),
      tostring(again == dir) }, '|')
  ]=]), "true|true|true|true")
end)

T.test("opencode_nudge_plugins_field_quotes_paths_for_json", function()
  T.eq(T.eval([=[
    remuda.exec('butler/opencode_nudge')
    local nudge = remuda.butler.opencode_nudge
    local dir = '/tmp/a "quote" and \\ backslash/nudge'
    local encoded = '{"model":"m"' .. nudge.plugins_field(dir) .. '}'
    local decoded, err = remuda.json.decode(encoded)
    assert(decoded, err)
    return table.concat({ tostring(decoded.plugins[1] == dir), tostring(#decoded.plugins == 1),
      tostring(nudge.plugins_field('') == '') }, '|')
  ]=]), "true|true|true")
end)

T.test("opencode_config_content_opts_the_member_server_into_the_nudge", function()
  T.eq(T.eval([=[
    -- Launches no agent: the stubs stop before any spawn boundary.
    remuda._butler_argv = { 'sh', '-c', 'sleep 60' }
    remuda._butler_skip_relay = true
    remuda.new = function() error('fixture stops before starting an agent', 0) end
    remuda.exec('butler')
    local support = assert(remuda._butler_agent_support)
    local dir = '/tmp/butler completion/nudge'
    local chunk = support.opencode_config_content('token', 'opencode-go/model', { dir })
    local decoded, err = remuda.json.decode(chunk)
    assert(decoded, err)
    local plain = support.opencode_config_content('token', 'opencode-go/model', nil)
    local decoded_plain = assert(remuda.json.decode(plain))
    return table.concat({ tostring(decoded.plugins[1] == dir), tostring(#decoded.plugins == 1),
      tostring(decoded.mcp.remuda.type == 'local'),
      tostring(decoded_plain.plugins == nil),
      tostring(decoded.model == 'opencode-go/model') }, '|')
  ]=]), "true|true|true|true|true")
end)
