-- B06 (Rust->Lua migration, #320): D047, split out of
-- butler_matrix_request_parity_test.lua. Rust ran it under
-- `_butler_test_mode = "lifecycle"` (real mail delivery needs main.lua's mail
-- bus), while the other B06 tests use `true`; the two modes cannot coexist in
-- one daemon, so this file owns its own. Name equals the Rust name in
-- tests/butler_daemon.rs; the assertions are unchanged.
-- Deviation: json.encode (remuda.json) builds the sync body instead of
-- serde_json; origin_server_ts = 0 is verified end-to-end (mutation red).
local REPO = assert(os.getenv("REMUDA_LUA_REPO"))
local SCRATCH = assert(os.getenv("REMUDA_LUA_SCRATCH"))
T.install_mod("butler", REPO)
T.eval("remuda._butler_test_mode = 'lifecycle'; remuda._butler_skip_relay = true")
T.eval('return remuda.exec("butler")')

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

-- Same files as the Rust butler_config helper.
local function config(tag, homeserver, room, self_mxid, allowed)
  local dir = SCRATCH .. "/b06-" .. tag
  remuda.mkdir(dir)
  local token_path, config_path = dir .. "/" .. tag .. ".token", dir .. "/" .. tag .. ".config"
  write_file(token_path, "test-token\n")
  write_file(config_path, homeserver .. "\n" .. room .. "\n" .. self_mxid .. "\n" .. allowed .. "\n\n100\n")
  return dir, token_path, config_path
end

local function boot(opts)
  T.eq(T.eval(string.format([[
    local REPO = %q
    dofile(REPO .. "/tests/support/fake_http.lua")
    remuda._butler_matrix_config = { token_path = %q, config_path = %q }
    remuda.exec("butler/matrix_request")
    remuda.exec("butler/matrix_relay")
    return 'booted'
  ]], REPO, opts.token_path, opts.config_path)), "booted", "boot failed")
end

local function vars(values)
  local lines = {}
  for name, value in pairs(values) do lines[#lines + 1] = string.format("local %s = %q", name, value) end
  return table.concat(lines, "\n") .. "\n"
end

T.test("butler_matrix_relay_persists_matrix_event_time_through_real_mail_delivery", function()
  local room = "!relay-time:example.org"
  local _, token_path, config_path = config("mail-time", "http://matrix.example.org", room, "@bot:example.org",
    "@alice:example.org")
  boot({ token_path = token_path, config_path = config_path })
  local event = { type = "m.room.message", event_id = "$mail-time", sender = "@alice:example.org",
    origin_server_ts = 0,
    content = { msgtype = "m.text", body = "dated \27[31mby Matrix" .. string.char(194, 155) .. "2J" } }
  local response = remuda.json.encode({ next_batch = "s1",
    rooms = { join = { [room] = { timeline = { events = { event } } } } } })
  local result = T.eval(vars({
    BASELINE = "http://matrix.example.org/_matrix/client/v3/sync?timeout=0",
    SYNC = "http://matrix.example.org/_matrix/client/v3/sync?since=s0&timeout=100",
    RESPONSE = response }) .. [==[
      local matrix = remuda.butler.matrix
      remuda.http.respond("GET", BASELINE, {status=200,headers={},body='{"next_batch":"s0"}'})
      remuda.http.respond("GET", SYNC, {status=200,headers={},body=RESPONSE})
      local original_delivery = remuda._butler_inbox_delivery
      remuda._butler_inbox_delivery = function(message)
        remuda.captured_delivery = message
        return original_delivery(message)
      end
      assert(matrix.relay.start(remuda._butler_matrix_config))
      for _=1,4 do remuda.http.tick() end
      remuda._butler_inbox_delivery = original_delivery
      local bus = remuda._butler_bus
      local root = assert(bus.agents.butler)
      for _, id in ipairs(remuda._butler_mail.mailbox(root.id)) do
        local message = bus.messages[id]
        if message and message.matrix and message.matrix.event_id == "$mail-time" then
          local body = bus.objects[message.body.object_id].content
          matrix.relay.stop()
          return message.created_at .. "|" .. tostring(message.matrix.room)
            .. "|" .. tostring(message.matrix.event_id) .. "|" .. body
        end
      end
      local state = matrix.relay.instance:state()
      local report = "mail-not-found|captured=" .. tostring(remuda.captured_delivery ~= nil)
        .. "|calls=" .. #remuda.http.calls .. "|pending=" .. tostring(state.pending["$mail-time"] ~= nil)
        .. "|inbox=" .. #remuda._butler_mail.mailbox(root.id)
      matrix.relay.stop()
      return report
  ]==])
  T.eq(result, "1970-01-01T00:00:00Z|home|$mail-time|dated [31mby Matrix2J",
    "relay-to-mail delivery must preserve metadata and strip control characters: " .. result)
end)
