return function(matrix)
  assert(type(matrix.setup_prepare) == "function", "Matrix setup validator is unavailable")
  assert(type(matrix.setup_network) == "function", "Matrix setup network stage is unavailable")
  assert(type(matrix.setup_write) == "function", "Matrix setup file writer is unavailable")
  assert(type(matrix.cli) == "function", "Matrix CLI router is unavailable")
  assert(matrix.cli({ "matrix", "setup" }) == matrix.setup_usage())
  assert(matrix.cli({ "matrix", "setup", "--help" }) == matrix.setup_usage())
  assert(matrix.cli_usage():find("Example:", 1, true)
    and matrix.cli_usage():find("https://<homeserver>", 1, true)
    and matrix.cli_usage():find("--password-file <path>", 1, true),
    "Matrix usage should include one complete placeholder setup example")

  assert(remuda.fs and remuda.fs.mkdir_new and remuda.fs.write_atomic,
    "run setup tests with the Remuda filesystem helpers")
  local root = os.tmpname()
  os.remove(root)
  assert(remuda.fs.mkdir_new(root))
  local saved_paths = remuda._butler_matrix_config
  remuda._butler_matrix_config = { token_path = root .. "/missing-token", config_path = root .. "/missing-config" }
  local default_guidance = matrix.configuration_guidance()
  assert(default_guidance and default_guidance:find("Next: remuda butler matrix setup", 1, true),
    "unconfigured guidance should point to setup")
  remuda._butler_matrix_config = saved_paths
  local password, token = root .. "/password", root .. "/token"
  local output = root .. "/output"
  assert(remuda.fs.mkdir_new(output))
  local real_mkdir_new = remuda.fs.mkdir_new
  local mkdir_calls = 0
  remuda.fs.mkdir_new = function(path)
    mkdir_calls = mkdir_calls + 1
    return real_mkdir_new(path)
  end
  local function write(path, content)
    local ok, err = remuda.fs.write_atomic(path, content or "secret", { private = true })
    assert(ok, err)
  end
  local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
  end
  local function args(secret_flag, secret_path, extra)
    local values = {
      "--homeserver", "http://matrix.invalid", "--owner", "@alice:example.org",
      secret_flag, secret_path, "--dir", output,
    }
    for _, value in ipairs(extra or {}) do values[#values + 1] = value end
    return values
  end
  local function rejected(values, fragment)
    local plan, err = matrix.setup_prepare(values)
    assert(not plan and tostring(err):find(fragment, 1, true),
      "expected setup rejection containing " .. fragment .. ", got " .. tostring(err))
  end

  write(password, "  password-secret  \nignored")
  local fake_http = remuda.http
  local fake_pending = remuda.pending
  local calls = 0
  remuda.http = { request = function() calls = calls + 1 end }
  local plan, err = matrix.setup_prepare(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--all" }))
  assert(plan, err)
  assert(plan.homeserver == "http://matrix.invalid")
  assert(plan.bot_mxid == "@butler-demo:example.org")
  assert(plan.owner_mxid == "@alice:example.org" and plan.create_all == true)
  assert(plan.token_path == output .. "/token" and plan.config_path == output .. "/config")
  assert(plan.secret_kind == "password" and plan.secret_path == password)
  assert(plan.secret == "password-secret", "only the trimmed first line should be used")
  assert(mkdir_calls == 0, "validation must not create output directories")
  assert(calls == 0, "setup validation must not make network requests")
  assert(io.open(plan.token_path, "rb") == nil and io.open(plan.config_path, "rb") == nil,
    "setup validation must not create the output files")
  remuda.http = fake_http

  -- An HTTP error may expose only its safe Matrix errcode and a matching Next
  -- hint, never any text from the server response body.
  write(token, "access-token")
  local error_config = root .. "/request-config"
  write(error_config, "http://matrix.invalid\n!room:example.org\n@alice:example.org\n")
  remuda._butler_matrix_config = { token_path = token, config_path = error_config }
  local request_http = remuda.http
  local delivered
  remuda.http = { request = function(spec)
    spec.callback({ status = 403, headers = {}, body = '{"errcode":"M_FORBIDDEN","error":"body-secret"}' })
    return { cancel = function() end }
  end }
  matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" }, function(result)
    delivered = result
  end)
  assert(delivered and delivered.error and delivered.error:find("M_FORBIDDEN", 1, true)
    and delivered.error:find("Next: check --password-file", 1, true)
    and not delivered.error:find("body-secret", 1, true) and delivered.body == nil,
    "HTTP errors should show safe errcode guidance without response body text")
  -- Reload to reset the client's rate-limit bucket between independent cases.
  dofile("packages/butler/matrix_request.lua")
  remuda.http = { request = function(spec)
    spec.callback({ status = 429, headers = {}, body = '{"errcode":"M_LIMIT_EXCEEDED","error":"private detail"}' })
    return { cancel = function() end }
  end }
  delivered = nil
  matrix.request({ method = "GET", path = "/_matrix/client/v3/account/whoami" }, function(result)
    delivered = result
  end)
  assert(delivered and delivered.error:find("M_LIMIT_EXCEEDED", 1, true)
    and delivered.error:find("Next: wait before retrying", 1, true)
    and not delivered.error:find("private detail", 1, true),
    "rate limits should include the wait hint without response body text")
  remuda.http = request_http
  remuda._butler_matrix_config = nil

  local empty = root .. "/empty"
  write(empty, "  \nignored")
  rejected(args("--password-file", empty, { "--bot", "@butler-demo:example.org" }), "empty")
  local oversized = root .. "/oversized"
  write(oversized, string.rep("x", 4097))
  rejected(args("--password-file", oversized, { "--bot", "@butler-demo:example.org" }), "4 KiB")
  rejected({ "--homeserver", "http://matrix.invalid", "--owner", "@alice:example.org",
    "--password-file", password }, "bot MXID")
  rejected(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--token-file", token }), "choose one")
  rejected(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--mystery" }), "unknown option")
  rejected(args("--password-file", password,
    { "--bot", "not-an-mxid" }), "bot must be")
  rejected({ "--homeserver", "https://matrix.invalid", "--owner", "@alice:example.org",
    "--bot", "@butler-demo:example.org", "--password-file", password, "--dir", output }, "--pin")
  rejected({ "--homeserver", "https://matrix.invalid", "--owner", "@alice:example.org",
    "--bot", "@butler-demo:example.org", "--password-file", password, "--dir", output,
    "--pin", "abcd" }, "64 hexadecimal")
  local pin = string.rep("A", 64)
  local pin_plan = matrix.setup_prepare({ "--homeserver", "https://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output, "--pin", pin })
  assert(pin_plan and pin_plan.pin == pin:lower(), "valid HTTPS pin must be normalized")
  local transport_spec
  remuda.http = { request = function(spec) transport_spec = spec; return {} end }
  matrix.setup_network(pin_plan, function() end)
  assert(transport_spec and transport_spec.pin and transport_spec.pin:match("^sha256/"),
    "HTTPS setup must pass the configured pin to the transport")
  local ca_file = root .. "/ca.pem"
  write(ca_file, "certificate")
  local ca_plan = matrix.setup_prepare({ "--homeserver", "https://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output, "--ca-file", ca_file })
  assert(ca_plan and ca_plan.ca_file == ca_file, "readable HTTPS CA file should validate")
  matrix.setup_network(ca_plan, function() end)
  assert(transport_spec and transport_spec.ca_file == ca_file,
    "HTTPS setup must pass the configured CA file to the transport")
  rejected({ "--homeserver", "https://matrix.invalid", "--owner", "@alice:example.org",
    "--bot", "@butler-demo:example.org", "--password-file", password, "--dir", output,
    "--pin", pin, "--ca-file", ca_file }, "choose one")

  local source = root .. "/existing-source"
  write(source, "keep")
  write(output .. "/token", "existing")
  rejected(args("--password-file", password, { "--bot", "@butler-demo:example.org" }), "--force")
  local forced = matrix.setup_prepare(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--force" }))
  assert(forced, "--force should authorize replacing existing output files")
  os.remove(output .. "/token")

  local default_dir = os.getenv("XDG_CONFIG_HOME")
  if not default_dir or default_dir == "" then default_dir = (os.getenv("HOME") or "") .. "/.config" end
  local default_paths = { token_path = default_dir .. "/remuda/butler/token",
    config_path = default_dir .. "/remuda/butler/config" }
  remuda._butler_matrix_paths = default_paths
  rejected({ "--homeserver", "http://matrix.invalid", "--owner", "@alice:example.org",
    "--bot", "@butler-demo:example.org", "--password-file", password }, "--default")
  local default_dir_path = default_paths.config_path:match("^(.*)/[^/]+$")
  remuda.mkdir(default_dir_path:match("^(.*)/[^/]+$"))
  local default_made, default_error = remuda.fs.mkdir_new(default_dir_path)
  assert(default_made or default_error == "exists", default_error)
  local after_default_fixture = mkdir_calls
  local default = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--default" })
  assert(default, "--default should accept an existing directory without --force")
  assert(mkdir_calls == after_default_fixture, "validation must not create default output directories")
  remuda._butler_matrix_paths = nil

  local requests = {}
  remuda.http = { request = function(spec)
    requests[#requests + 1] = spec
    return { cancel = function() end }
  end }
  local resolved
  remuda.pending = function()
    return { resolve = function(_, status, stdout, stderr)
      resolved = { status = status, stdout = stdout, stderr = stderr }
    end }
  end
  local real_write_atomic, atomic_writes = remuda.fs.write_atomic, {}
  remuda.fs.write_atomic = function(path, contents, opts)
    atomic_writes[#atomic_writes + 1] = { path = path, private = opts and opts.private }
    return real_write_atomic(path, contents, opts)
  end
  local real_status = matrix.status
  matrix.status = function(_, callback)
    assert(read(output .. "/token") == "temporary-access-token\n"
      and read(output .. "/config"), "setup must write credentials before checking status")
    callback({ status = 200, json = { user_id = "@butler-demo:example.org",
      joined_rooms = { "!home:example.org", "!all:example.org" } } })
    return { cancel = function() end }
  end
  local reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output, "--all" })
  assert(reply and not resolved, "setup CLI should complete asynchronously")
  assert(#requests == 1, "password setup should begin with /login")
  local login = requests[1]
  assert(login.method == "POST" and login.url == "http://matrix.invalid/_matrix/client/v3/login")
  assert(login.body:find("password-secret", 1, true), "login request must carry password in its body")
  assert(not login.body:find("Authorization", 1, true), "login must not put credentials in headers")
  login.callback({ status = 200, body = '{"access_token":"temporary-access-token"}' })
  assert(#requests == 2 and requests[2].method == "GET"
    and requests[2].url == "http://matrix.invalid/_matrix/client/v3/account/whoami")
  assert(requests[2].headers.Authorization == "Bearer temporary-access-token")
  requests[2].callback({ status = 200, body = '{"user_id":"@butler-demo:example.org"}' })
  assert(#requests == 3 and requests[3].method == "POST"
    and requests[3].url == "http://matrix.invalid/_matrix/client/v3/createRoom")
  assert(requests[3].body:find('"preset":"private_chat"', 1, true)
    and requests[3].body:find("@alice:example.org", 1, true)
    and not requests[3].body:find("m.room.encryption", 1, true),
    "createRoom must invite owner without enabling encryption")
  requests[3].callback({ status = 200, body = '{"room_id":"!home:example.org"}' })
  assert(#requests == 4 and requests[4].method == "POST"
    and requests[4].url == "http://matrix.invalid/_matrix/client/v3/createRoom")
  assert(requests[4].body:find("@alice:example.org", 1, true)
    and not requests[4].body:find("m.room.encryption", 1, true),
    "ALL-BUTLERS createRoom must invite owner without enabling encryption")
  requests[4].callback({ status = 200, body = '{"room_id":"!all:example.org"}' })
  matrix.status = real_status
  assert(resolved and resolved.status == 0 and resolved.stdout:find("!home:example.org", 1, true)
    and resolved.stdout:find("!all:example.org", 1, true)
    and resolved.stdout:find("Status: User: @butler-demo:example.org; Joined rooms: 2", 1, true)
    and resolved.stdout:find("Next: accept the invite on your phone and say hi", 1, true)
    and resolved.stdout:find("Next: delete the password file", 1, true)
    and not resolved.stdout:find("password-secret", 1, true)
    and not resolved.stdout:find("temporary-access-token", 1, true),
    "setup CLI output must report saved rooms without secrets")
  assert(read(output .. "/token") == "temporary-access-token\n")
  assert(read(output .. "/config") == table.concat({ "http://matrix.invalid",
    "!home:example.org", "@butler-demo:example.org", "@alice:example.org", "", "30000",
    "all_room=!all:example.org", "" }, "\n"))
  assert(#atomic_writes == 2 and atomic_writes[1].private and atomic_writes[2].private,
    "token and config must both use private atomic writes")
  remuda.fs.write_atomic = real_write_atomic
  remuda.http = fake_http

  write(output .. "/token", "previous-token\n")
  write(output .. "/config", "previous-config\n")
  local forced_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output, "--force" })
  assert(forced_plan, "--force should permit replacing existing files in an existing directory")
  remuda.fs.write_atomic = function(path, contents, opts)
    if path == output .. "/config" then return nil, "simulated disk failure" end
    return real_write_atomic(path, contents, opts)
  end
  local forced_written, forced_error = matrix.setup_write(forced_plan, {
    token = "replacement-token", user_id = "@butler-demo:example.org",
    home_room = "!orphan-home:example.org", all_room = "!orphan-all:example.org",
  })
  assert(not forced_written and forced_error:find("!orphan-home:example.org", 1, true)
    and forced_error:find("!orphan-all:example.org", 1, true))
  assert(read(output .. "/token") == "previous-token\n"
    and read(output .. "/config") == "previous-config\n",
    "failed forced write must restore pre-existing output files")
  remuda.fs.write_atomic = real_write_atomic

  local rollback_dir = root .. "/rollback/child"
  local rollback_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", rollback_dir })
  assert(rollback_plan, "validation must accept a not-yet-created output directory")
  remuda.fs.write_atomic = function(path, contents, opts)
    if path == rollback_dir .. "/config" then return nil, "simulated disk failure" end
    return real_write_atomic(path, contents, opts)
  end
  local rollback_written, rollback_error = matrix.setup_write(rollback_plan, {
    token = "temporary-access-token", user_id = "@butler-demo:example.org",
    home_room = "!orphan-room:example.org",
  })
  assert(not rollback_written and rollback_error:find("!orphan-room:example.org", 1, true))
  assert(read(rollback_dir .. "/token") == nil, "failed write must remove files created by this run")
  local made_parent = remuda.fs.mkdir_new(root .. "/rollback")
  local made_child = remuda.fs.mkdir_new(rollback_dir)
  assert(made_parent and made_child, "failed write must remove directories created by this run")
  os.remove(rollback_dir)
  os.remove(root .. "/rollback")
  remuda.fs.write_atomic = real_write_atomic

  local fresh_dir = root .. "/fresh-parent/child"
  local before_fresh_validation = mkdir_calls
  local fresh_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", fresh_dir })
  assert(fresh_plan, "setup validation must accept a new output directory without creating it")
  assert(mkdir_calls == before_fresh_validation, "validation must leave new output directories untouched")
  local fresh_result, fresh_error = matrix.setup_write(fresh_plan, {
    token = "fresh-token", user_id = "@butler-demo:example.org", home_room = "!fresh:example.org",
  })
  assert(fresh_result, fresh_error)
  assert(read(fresh_dir .. "/token") == "fresh-token\n" and read(fresh_dir .. "/config"))
  local existing_dir, existing_dir_error = remuda.fs.mkdir_new(fresh_dir)
  assert(not existing_dir and existing_dir_error == "exists",
    "successful setup must keep its newly created output directory")
  os.remove(fresh_dir .. "/token")
  os.remove(fresh_dir .. "/config")
  os.remove(fresh_dir)
  os.remove(root .. "/fresh-parent")

  requests = {}
  remuda.http = { request = function(spec) requests[#requests + 1] = spec; return {} end }
  resolved = nil
  matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output, "--force" })
  requests[1].callback({ status = 403, body = 'rejected password-secret' })
  assert(resolved and resolved.status == 1 and not resolved.stderr:find("password-secret", 1, true),
    "login errors must not expose secrets or response bodies")
  remuda.http = fake_http

  write(token, "  access-token  \nignored")
  local token_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--token-file", token, "--dir", output, "--force" })
  assert(token_plan and token_plan.secret_kind == "token" and token_plan.bot_mxid == nil
    and token_plan.secret == "access-token",
    "token setup should use the first trimmed line and discover the bot with whoami later")
  requests = {}
  remuda.http = { request = function(spec) requests[#requests + 1] = spec; return {} end }
  local token_result
  matrix.setup_network(token_plan, function(result) token_result = result end)
  assert(#requests == 1 and requests[1].method == "GET"
    and requests[1].url == "http://matrix.invalid/_matrix/client/v3/account/whoami"
    and requests[1].headers.Authorization == "Bearer access-token",
    "token setup should use whoami without password login")
  requests[1].callback({ status = 200, body = '{"user_id":"@butler-demo:example.org"}' })
  assert(#requests == 2 and requests[2].url == "http://matrix.invalid/_matrix/client/v3/createRoom"
    and not requests[2].body:find("m.room.encryption", 1, true),
    "token setup should create one unencrypted HOME room")
  requests[2].callback({ status = 200, body = '{"room_id":"!token-home:example.org"}' })
  assert(token_result and token_result.home_room == "!token-home:example.org"
    and token_result.all_room == nil and token_result.token == "access-token")
  remuda.http = fake_http
  remuda.pending = fake_pending
  for _, path in ipairs({ password, token, empty, oversized, ca_file, source,
    output .. "/token", output .. "/config" }) do os.remove(path) end
  os.remove(output)
  os.remove(root)
end
