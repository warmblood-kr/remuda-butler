-- `inbox <arg>` takes an id from the caller: a path or a non-ULID never
-- reaches a message file open and is never cached.
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
  remuda._butler_launch("codex", "cx1")
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

T.test("inbox_with_a_non_ulid_opens_no_message_file", function()
  T.eq(T.eval([=[
    local opened = {}
    local real_open = io.open
    io.open = function(name, ...)
      if tostring(name):find('../../x', 1, true) or tostring(name):find('not-a-ulid', 1, true) then
        opened[#opened + 1] = name
      end
      return real_open(name, ...)
    end
    local agent = remuda._butler_bus.agents.cx1
    local rejected = {}
    for _, id in ipairs({ '../../x', 'not-a-ulid' }) do
      local ok, err = pcall(remuda._butler_command_run, 'inbox', { 'inbox', id },
        { kind = 'session', session = agent.session_name, instance_id = _inst(agent.session_name) })
      rejected[#rejected + 1] = tostring(not ok
        and tostring(err):find('agents may only read their own Butler inbox', 1, true) ~= nil)
    end
    io.open = real_open
    local bus = remuda._butler_bus
    return table.concat(rejected, ',') .. '|' .. tostring(#opened) .. '|' .. tostring(bus.messages['../../x'] == nil)
      .. '|' .. tostring(bus.messages['not-a-ulid'] == nil)
  ]=]), "true,true|0|true|true")
end)

-- Outside an agent session, `inbox <message-id>` says why and ends with a
-- Next: line.
T.test("operator_inbox_with_a_message_id_gets_a_next_line", function()
  T.eq(T.eval([=[
    local id = remuda._butler_send('butler', 'cx1', 'operator view'):match('^queued (%S+)')
    local ok, out = pcall(remuda._butler_command_run, 'inbox', { 'inbox', id }, { kind = 'outside' })
    out = tostring(out)
    return (out:find('shows a message only to the member it was delivered to', 1, true)
      and out:find(id, 1, true) and out:find('Next:', 1, true)) and 'next' or out
  ]=]), "next")
end)
