return function(matrix)
  assert(type(matrix.setup_prepare) == "function", "Matrix setup validator is unavailable")
  assert(type(matrix.setup_network) == "function", "Matrix setup network stage is unavailable")
  assert(type(matrix.cli) == "function", "Matrix CLI router is unavailable")
  assert(matrix.cli({ "matrix", "setup" }) == matrix.setup_usage())
  assert(matrix.cli({ "matrix", "setup", "--help" }) == matrix.setup_usage())

  assert(remuda.fs and remuda.fs.mkdir_new and remuda.fs.write_atomic,
    "run setup tests with the Remuda filesystem helpers")
  local root = os.tmpname()
  os.remove(root)
  assert(remuda.fs.mkdir_new(root))
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
  assert(resolved and resolved.status == 0 and resolved.stdout:find("!home:example.org", 1, true)
    and resolved.stdout:find("!all:example.org", 1, true)
    and not resolved.stdout:find("password-secret", 1, true)
    and not resolved.stdout:find("temporary-access-token", 1, true),
    "setup CLI output must report rooms without secrets")
  remuda.http = fake_http

  requests = {}
  remuda.http = { request = function(spec) requests[#requests + 1] = spec; return {} end }
  resolved = nil
  matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output })
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
end
