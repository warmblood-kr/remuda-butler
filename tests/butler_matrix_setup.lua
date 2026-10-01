return function(matrix)
  assert(type(matrix.setup_prepare) == "function", "Matrix setup validator is unavailable")
  assert(type(matrix.setup_network) == "function", "Matrix setup network stage is unavailable")
  assert(type(matrix.setup_write) == "function", "Matrix setup file writer is unavailable")
  assert(type(matrix.cli) == "function", "Matrix CLI router is unavailable")
  local no_flag_plan = matrix.setup_prepare({})
  assert(no_flag_plan and no_flag_plan.wizard == true,
    "no setup flags should select the interactive wizard")
  assert(matrix.cli({ "matrix", "setup", "--help" }) == matrix.setup_usage())
  local setup_help = matrix.setup_usage()
  assert(not setup_help:find("MXID", 1, true)
    and setup_help:find("Your Matrix server address", 1, true)
    and setup_help:find("in Element: click your avatar, top left", 1, true)
    and setup_help:find("the account setup logs in as", 1, true)
    and setup_help:find("--register", 1, true)
    and setup_help:find("prompt for its registration token if no file is given", 1, true)
    and setup_help:find("--registration-token-file PATH  Optional", 1, true)
    and setup_help:find("homeserver registration token", 1, true)
    and setup_help:find("generated and saved privately", 1, true)
    and setup_help:find("Example: remuda butler matrix setup", 1, true)
    and setup_help:find("--register --dir /path/to/private/butler", 1, true)
    and not setup_help:find("--register --registration-token-file", 1, true),
    "setup usage should explain each option in plain words and show a full example")
  assert(matrix.cli_usage():find("Example:", 1, true)
    and matrix.cli_usage():find("https://<homeserver>", 1, true)
    and matrix.cli_usage():find("--password-file <path>", 1, true),
    "Matrix usage should include one complete placeholder setup example")
  assert(not matrix.cli_usage():match("Example:[^\n]*"):find("--pin", 1, true),
    "the usage example should not require --pin")

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
  write(password, "  password-secret  \nignored")
  local function args(secret_flag, secret_path, extra)
    local values = {
      "--homeserver", "http://matrix.invalid", "--owner", "@alice:example.org",
      secret_flag, secret_path, "--dir", output,
    }
    for _, value in ipairs(extra or {}) do values[#values + 1] = value end
    return values
  end
  write(token, "access-token-secret")
  local function written_room_config(room_mode, destination)
    local values = { "--homeserver", "http://matrix.invalid", "--owner", "@alice:example.org",
      "--token-file", token, "--bot", "@butler-demo:example.org", "--dir", destination }
    if room_mode then
      values[#values + 1] = "--rooms"
      values[#values + 1] = room_mode
    end
    local plan, prepare_error = matrix.setup_prepare(values)
    assert(plan, "room policy setup should validate: " .. tostring(prepare_error))
    assert(plan.rooms_mode == (room_mode or "allowlist"), "room policy should default to allowlist")
    local files, write_error = matrix.setup_write(plan, {
      token = "created-access-token", user_id = "@butler-demo:example.org", home_room = "!home:example.org",
    })
    assert(files, "room policy setup should write its config: " .. tostring(write_error))
    return read(files.config_path)
  end
  local default_rooms_config = written_room_config(nil, root .. "/default-rooms")
  assert(not default_rooms_config:find("rooms=", 1, true),
    "default allowlist policy should preserve the legacy config without a rooms line")
  local open_rooms_config = written_room_config("open", root .. "/open-rooms")
  assert(open_rooms_config:find("\nrooms=open\n", 1, true),
    "open room policy should serialize as rooms=open")
  mkdir_calls = 0
  local function rejected(values, fragment)
    local plan, err = matrix.setup_prepare(values)
    assert(not plan and tostring(err):find(fragment, 1, true),
      "expected setup rejection containing " .. fragment .. ", got " .. tostring(err))
  end
  local function invalid_ids(owner_id, bot_id)
    return matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
      "--owner", owner_id, "--password-file", password, "--bot", bot_id, "--dir", output })
  end
  local _, missing_at = invalid_ids("alice", "@butler-demo:example.org")
  assert(missing_at and missing_at:find("--owner 'alice' is not a Matrix user ID. It looks like @alice:example.org: an @, your name, a colon, your server.", 1, true),
    "missing @ should show the corrected Matrix user ID shape")
  local _, missing_server = invalid_ids("@alice", "@butler-demo:example.org")
  assert(missing_server and missing_server:find("--owner '@alice' is missing :server", 1, true),
    "missing server should show a specific Matrix user ID hint")
  local _, spaces = invalid_ids("@alice smith:example.org", "@butler-demo:example.org")
  assert(spaces and spaces:find("--owner '@alice smith:example.org' contains spaces", 1, true),
    "spaces should show a specific Matrix user ID hint")
  local _, invalid_bot = invalid_ids("@alice:example.org", "butler-home:example.org")
  assert(invalid_bot and invalid_bot:find("--bot 'butler-home:example.org' is not a Matrix user ID. It looks like @butler-home:example.org", 1, true),
    "bot ID errors should name --bot and show the corrected shape")
  local _, long_id = invalid_ids(string.rep("a", 80), "@butler-demo:example.org")
  assert(long_id and not long_id:find(string.rep("a", 65), 1, true),
    "invalid public ID echoes must be capped at 64 characters")
  local valid_id_plan = invalid_ids("@alice:example.org", "@butler-demo:example.org")
  assert(valid_id_plan and valid_id_plan.owner_mxid == "@alice:example.org"
    and valid_id_plan.bot_mxid == "@butler-demo:example.org",
    "valid Matrix user IDs should still pass")

  local registration_token_file = root .. "/registration-token"
  write(registration_token_file, "  homeserver-registration-token  \nignored")
  local registration_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-demo:example.org", "--dir", output })
  assert(registration_plan and registration_plan.secret_kind == "registration"
    and registration_plan.secret == "homeserver-registration-token"
    and registration_plan.bot_mxid == "@butler-demo:example.org"
    and registration_plan.password_path == output .. "/password",
    "--register should validate the homeserver token and reserve a private password output path")
  local prompted_registration = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--bot", "@butler-demo:example.org",
    "--dir", output })
  assert(prompted_registration and prompted_registration.prompt_registration_token == true,
    "--register without a token file should ask the CLI to prompt for the registration token")
  local chosen_password_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--password-file", password, "--bot", "@butler-demo:example.org",
    "--dir", output })
  assert(chosen_password_plan and chosen_password_plan.secret_kind == "registration"
    and chosen_password_plan.secret == "homeserver-registration-token"
    and chosen_password_plan.password_secret == "password-secret"
    and chosen_password_plan.password_path == output .. "/password",
    "--register should accept a chosen password file while preserving the registration token separately")
  local default_registration = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--dir", output })
  assert(default_registration and default_registration.bot_mxid:match("^@butler%-%w[%w%-]*:example%.org$"),
    "registration should derive a slugged butler username from the hostname when --bot is omitted")
  local existing_password_dir = root .. "/existing-password"
  assert(real_mkdir_new(existing_password_dir))
  write(existing_password_dir .. "/password", "old-generated-password")
  local _, existing_password_error = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-demo:example.org", "--dir", existing_password_dir })
  assert(existing_password_error and existing_password_error:find("output file already exists", 1, true),
    "validation should refuse to register before overwriting an existing password file")
  local forced_registration = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-demo:example.org", "--dir", existing_password_dir,
    "--force" })
  assert(forced_registration, "--force should explicitly permit replacing an existing password file")
  os.remove(existing_password_dir .. "/password")
  os.remove(existing_password_dir)

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
    "--password-file", password }, "--bot is required")
  rejected(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--token-file", token }), "choose one")
  rejected(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--mystery" }), "unknown option")
  rejected(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--rooms", "anyone" }), "rooms must be open or allowlist")
  rejected(args("--password-file", password,
    { "--bot", "not-an-mxid" }), "--bot 'not-an-mxid' is not a Matrix user ID")
  do
  -- Owner decision A: an https homeserver whose certificate the system roots
  -- trust needs no --pin/--ca-file; an untrusted one is refused with a Next:.
  local saved_http = remuda.http
  local function system_trust_setup(trusted)
    local queue, specs, result = {}, {}, nil
    remuda.http = { request = function(spec)
      specs[#specs + 1] = spec
      queue[#queue + 1] = spec
      return { cancel = function() end }
    end }
    local plan, plan_error = matrix.setup_prepare({ "--homeserver", "https://matrix.invalid",
      "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
      "--password-file", password, "--dir", output })
    assert(plan and not plan.pin and not plan.ca_file,
      "https setup without --pin/--ca-file must use system trust roots: " .. tostring(plan_error))
    matrix.setup_network(plan, function(value) result = value end)
    while #queue > 0 do
      local spec = table.remove(queue, 1)
      if spec.pin ~= nil or spec.ca_file ~= nil or spec.pin_only == true then
        spec.callback({ error = "unexpected trust override" })
      elseif not trusted then
        spec.callback({ error = "TLS request failed: server certificate issuer not trusted" })
      elseif spec.url:find("/login", 1, true) then
        spec.callback({ status = 200, body = '{"access_token":"system-trust-token"}' })
      elseif spec.url:find("/whoami", 1, true) then
        spec.callback({ status = 200, body = '{"user_id":"@butler-demo:example.org"}' })
      elseif spec.url:find("/createRoom", 1, true) then
        spec.callback({ status = 200, body = '{"room_id":"!system-trust:example.org"}' })
      else
        spec.callback({ status = 404, body = '{"errcode":"M_UNRECOGNIZED"}' })
      end
    end
    remuda.http = saved_http
    return result, specs
  end
  local trusted, trusted_specs = system_trust_setup(true)
  assert(type(trusted) == "table" and not trusted.error and trusted.home_room == "!system-trust:example.org"
    and #trusted_specs > 0,
    "a system-trusted https homeserver must set up without --pin/--ca-file: "
      .. tostring(type(trusted) == "table" and trusted.error))
  local untrusted = system_trust_setup(false)
  assert(type(untrusted) == "table" and type(untrusted.error) == "string"
    and untrusted.error:find("Next: remuda butler matrix setup --ca-file PATH", 1, true)
    and not untrusted.error:find("system-trust-token", 1, true),
    "an untrusted https certificate must be refused with a --ca-file Next: line: "
      .. tostring(type(untrusted) == "table" and untrusted.error))
  end
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
  assert(transport_spec.pin_only ~= true and transport_spec.pin == nil,
    "--ca-file setup keeps chain validation: no pin_only")

  do
  -- A self-signed homeserver as core 0a5f090 sees it: a pin alone is additive
  -- (chain check fails), pin_only = true with the matching SPKI pin replaces it.
  local good_pin_hex, wrong_pin_hex = string.rep("0", 64), string.rep("1", 64)
  local good_transport_pin = "sha256/" .. string.rep("A", 43) .. "="
  local saved_http = remuda.http
  local function self_signed_setup(pin_hex, register)
    local queue, specs, result = {}, {}, nil
    remuda.http = { request = function(spec)
      specs[#specs + 1] = spec
      queue[#queue + 1] = spec
      return { cancel = function() end }
    end }
    local setup_args = { "--homeserver", "https://matrix.invalid",
      "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
      "--password-file", password, "--dir", output, "--pin", pin_hex }
    if register then
      setup_args[#setup_args + 1] = "--register"
      setup_args[#setup_args + 1] = "--registration-token-file"
      setup_args[#setup_args + 1] = registration_token_file
    end
    local plan = assert(matrix.setup_prepare(setup_args))
    matrix.setup_network(plan, function(value) result = value end)
    while #queue > 0 do
      local spec = table.remove(queue, 1)
      if spec.pin_only ~= true then
        spec.callback({ error = "TLS request failed: server certificate issuer not trusted" })
      elseif spec.pin ~= good_transport_pin then
        spec.callback({ error = "TLS request failed: SPKI pin mismatch" })
      elseif spec.url:find("/register", 1, true) and not spec.body:find('"auth"', 1, true) then
        spec.callback({ status = 401,
          body = '{"session":"self-signed-session","flows":[{"stages":["m.login.registration_token"]}]}' })
      elseif spec.url:find("/register", 1, true) then
        spec.callback({ status = 200,
          body = '{"access_token":"self-signed-token","user_id":"@butler-demo:example.org"}' })
      elseif spec.url:find("/login", 1, true) then
        spec.callback({ status = 200, body = '{"access_token":"self-signed-token"}' })
      elseif spec.url:find("/whoami", 1, true) then
        spec.callback({ status = 200, body = '{"user_id":"@butler-demo:example.org"}' })
      elseif spec.url:find("/createRoom", 1, true) then
        spec.callback({ status = 200, body = '{"room_id":"!self-signed:example.org"}' })
      else
        spec.callback({ status = 404, body = '{"errcode":"M_UNRECOGNIZED"}' })
      end
    end
    remuda.http = saved_http
    return result, specs
  end
  local signed, signed_specs = self_signed_setup(good_pin_hex)
  assert(type(signed) == "table" and not signed.error
    and signed.home_room == "!self-signed:example.org",
    "--pin alone must set up a self-signed HTTPS homeserver: "
      .. tostring(type(signed) == "table" and signed.error))
  for _, spec in ipairs(signed_specs) do
    assert(spec.pin_only == true and spec.pin == good_transport_pin and spec.ca_file == nil,
      "every setup request with --pin must use pin_only = true: " .. tostring(spec.url))
  end
  rejected({ "--homeserver", "http://matrix.invalid", "--owner", "@alice:example.org",
    "--bot", "@butler-demo:example.org", "--password-file", password, "--dir", output,
    "--pin", good_pin_hex }, "only valid with an https:// homeserver")
  local saved_setup_http = remuda.http
  local other_error
  remuda.http = { request = function(spec)
    spec.callback({ error = "TLS request failed: server hostname mismatch (pinned)" })
    return { cancel = function() end }
  end }
  matrix.setup_network(assert(matrix.setup_prepare({ "--homeserver", "https://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output, "--pin", good_pin_hex })),
    function(value) other_error = value end)
  remuda.http = saved_setup_http
  assert(other_error and other_error.error and not other_error.error:find("does not match --pin", 1, true),
    "only core's SPKI pin mismatch text gets the --pin Next: line: " .. tostring(other_error and other_error.error))
  local registered, registered_specs = self_signed_setup(good_pin_hex, true)
  assert(type(registered) == "table" and not registered.error
    and registered.home_room == "!self-signed:example.org"
    and registered_specs[1].url:find("/register", 1, true),
    "--register --pin must create the bot on a self-signed HTTPS homeserver: "
      .. tostring(type(registered) == "table" and registered.error))
  for _, spec in ipairs(registered_specs) do
    assert(spec.pin_only == true and spec.pin == good_transport_pin and spec.ca_file == nil,
      "every --register request with --pin must use pin_only = true: " .. tostring(spec.url))
  end
  local mismatched = self_signed_setup(wrong_pin_hex)
  assert(type(mismatched) == "table" and type(mismatched.error) == "string"
    and mismatched.error:find("pin", 1, true) and mismatched.error:find("Next:", 1, true)
    and not mismatched.error:find("self-signed-token", 1, true),
    "a wrong --pin must fail with a Next: line: "
      .. tostring(type(mismatched) == "table" and mismatched.error))
  end
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
  local _, default_refusal = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org", "--password-file", password })
  local setup_prefix = "remuda butler matrix setup --homeserver 'http://matrix.invalid'"
    .. " --owner '@alice:example.org' --password-file '" .. password
    .. "' --bot '@butler-demo:example.org'"
  assert(default_refusal and default_refusal:find("Nothing was written.", 1, true)
    and default_refusal:find(setup_prefix .. " --default", 1, true)
    and default_refusal:find(setup_prefix .. " --dir \"$HOME/.config/remuda/matrix-test\"", 1, true)
    and default_refusal:find("--dir \"$HOME/.config/remuda/matrix-test\"", 1, true)
    and default_refusal:find("REMUDA_BUTLER_TOKEN=", 1, true)
    and default_refusal:find("REMUDA_BUTLER_CONFIG=", 1, true)
    and default_refusal:find("remuda -s matrix-test daemon", 1, true)
    and not default_refusal:find("reload", 1, true)
    and not default_refusal:find("remuda stop", 1, true),
    "default refusal should explain both safe choices without restart hints")
  assert(not default_refusal:find("password-secret", 1, true),
    "default refusal must not reveal the secret contents")
  local _, registration_default_refusal = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-demo:example.org" })
  assert(registration_default_refusal and registration_default_refusal:find("Nothing was written.", 1, true)
    and registration_default_refusal:find("--registration-token-file", 1, true)
    and not registration_default_refusal:find("homeserver-registration-token", 1, true),
    "setup_command abort hints must never reveal the registration token contents")
  assert(io.open(default_paths.token_path, "rb") == nil
    and io.open(default_paths.config_path, "rb") == nil,
    "refused default setup must not write token or config files")
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
  local registration_result
  matrix.setup_register({ homeserver = "http://matrix.invalid", username = "butler-demo",
    password = "generated-password", registration_token = "server-registration-token" },
    function(result) registration_result = result end)
  assert(#requests == 1 and requests[1].method == "POST"
    and requests[1].url == "http://matrix.invalid/_matrix/client/v3/register",
    "registration should begin with the Matrix register endpoint")
  local function request_json(spec)
    return matrix.decode_json(spec.body)
  end
  local initial_register = request_json(requests[1])
  assert(initial_register.username == "butler-demo"
    and initial_register.password == "generated-password"
    and initial_register.inhibit_login == false and initial_register.auth == nil,
    "registration should submit account details without putting secrets in URL or headers")
  requests[1].callback({ status = 401, body = '{"session":"uia-session-1","flows":[{"stages":["m.login.dummy","m.login.registration_token"]}]}' })
  assert(#requests == 2, "registration should send the dummy UIA stage first")
  local dummy_register = request_json(requests[2])
  assert(dummy_register.auth and dummy_register.auth.type == "m.login.dummy"
    and dummy_register.auth.session == "uia-session-1"
    and dummy_register.auth.token == nil,
    "dummy UIA stage should use the challenge session and omit the registration token")
  requests[2].callback({ status = 401, body = '{"session":"uia-session-1","flows":[{"stages":["m.login.dummy","m.login.registration_token"]}]}' })
  assert(#requests == 3, "registration should submit the token stage after dummy")
  local token_register = request_json(requests[3])
  assert(token_register.auth and token_register.auth.type == "m.login.registration_token"
    and token_register.auth.token == "server-registration-token"
    and token_register.auth.session == "uia-session-1",
    "registration token stage should use the same UIA session")
  assert(not requests[3].url:find("server-registration-token", 1, true)
    and not requests[3].headers.Authorization,
    "registration token must never appear in URL or Authorization header")
  requests[3].callback({ status = 200,
    body = '{"access_token":"new-access-token","user_id":"@butler-demo:example.org"}' })
  assert(registration_result and registration_result.access_token == "new-access-token"
    and registration_result.user_id == "@butler-demo:example.org",
    "registration should return only the created account credentials")
  requests = {}
  local registration_error
  matrix.setup_register({ homeserver = "http://matrix.invalid", username = "butler-demo",
    password = "generated-password", registration_token = "server-registration-token" },
    function(result) registration_error = result end)
  requests[1].callback({ status = 401,
    body = '{"session":"uia-session-2","flows":[{"stages":["m.login.registration_token"]}]}' })
  requests[2].callback({ status = 403,
    body = '{"errcode":"M_FORBIDDEN","error":"server-registration-token rejected"}' })
  assert(registration_error and registration_error.error
    == "The server rejected that registration token. Nothing was created or written."
    and not registration_error.error:find("server-registration-token", 1, true),
    "registration token rejection should return fixed safe guidance")
  requests = {}
  local no_registration_flow
  matrix.setup_register({ homeserver = "http://matrix.invalid", username = "butler-demo",
    password = "generated-password", registration_token = "server-registration-token" },
    function(result) no_registration_flow = result end)
  requests[1].callback({ status = 401,
    body = '{"session":"uia-session-3","flows":[{"stages":["m.login.dummy"]}]}' })
  assert(no_registration_flow and no_registration_flow.error
    == "This server does not accept registration tokens. Next: this server needs an admin-created bot; run setup with --token-file PATH (the bot access token)."
    and #requests == 1,
    "registration without a token flow should stop with safe existing-bot guidance")
  requests = {}
  local unsupported_registration_flow
  matrix.setup_register({ homeserver = "http://matrix.invalid", username = "butler-demo",
    password = "generated-password", registration_token = "server-registration-token" },
    function(result) unsupported_registration_flow = result end)
  requests[1].callback({ status = 401,
    body = '{"session":"uia-session-4","flows":[{"stages":["m.login.dummy","m.login.terms","m.login.registration_token"]}]}' })
  assert(unsupported_registration_flow and unsupported_registration_flow.error
    and unsupported_registration_flow.error:find("m.login.terms", 1, true)
    and #requests == 1,
    "registration should name and stop on UIA stages it cannot complete")
  requests = {}
  local user_in_use
  matrix.setup_register({ homeserver = "http://matrix.invalid", username = "butler-demo",
    password = "generated-password", registration_token = "server-registration-token" },
    function(result) user_in_use = result end)
  requests[1].callback({ status = 400,
    body = '{"errcode":"M_USER_IN_USE","error":"private response text"}' })
  assert(user_in_use and user_in_use.errcode == "M_USER_IN_USE"
    and not tostring(user_in_use.error):find("private response text", 1, true),
    "registration should expose only the safe M_USER_IN_USE code for collision retry")
  requests = {}
  local resolved
  local prompt_specs = {}
  local line_specs = {}
  local pending_timeout
  remuda.pending = function(options)
    pending_timeout = options and options.timeout
    local reply = { resolve = function(_, status, stdout, stderr)
      resolved = { status = status, stdout = stdout, stderr = stderr }
    end }
    function reply:prompt_secret(spec)
      assert(not spec.label:find(":%s*$"), "a hidden prompt label must not end with its own colon: " .. spec.label)
      -- prompt_secret has no preface: its label has to fit core's one line.
      assert(#spec.label <= 256 and not spec.label:find("\n", 1, true),
        "a hidden prompt label is one line and at most 256 characters: " .. #spec.label)
      prompt_specs[#prompt_specs + 1] = spec
    end
    function reply:prompt_line(spec)
      -- Core's prompt_line shows a label on one line, cuts it at 256
      -- characters and adds ":" / "[default]:" itself. Longer text goes in
      -- `preface` (one string, at most 32 lines of at most 256 characters; more
      -- is an error from core, #186). Only a core without preface gets the old
      -- summary-in-the-label form.
      local legacy = not matrix.prompt_preface_supported() and spec.label:find("^Matrix setup will:")
      assert(not spec.label:find(":%s*$"), "a wizard prompt label must not end with its own colon: " .. spec.label)
      assert(legacy or (#spec.label <= 256 and not spec.label:find("\n", 1, true)),
        "every wizard prompt label is one line and at most 256 characters: " .. spec.label)
      assert(spec.preface == nil or matrix.prompt_preface_supported(), "a core without preface must not be sent one")
      if spec.preface ~= nil then
        assert(type(spec.preface) == "string" and spec.preface ~= "" and not spec.preface:find("[%z\1-\9\11-\31\127]")
          and not spec.preface:find("Continue?", 1, true),
          "a preface is plain text lines without control characters and without the question")
        local count = 0
        for line in (spec.preface .. "\n"):gmatch("([^\n]*)\n") do
          count = count + 1
          assert(#line <= 250, "a preface line must leave room under core's 256-character cap: " .. #line)
        end
        assert(count <= 32, "a preface must stay under core's 32-line cap: " .. count)
      end
      -- What the terminal shows for this prompt: the preface lines, then the
      -- question. The assertions below read it as `label`; `question` and
      -- `preface` are the two parts as sent to core.
      line_specs[#line_specs + 1] = { label = (spec.preface and (spec.preface .. "\n") or "") .. spec.label,
        question = spec.label, preface = spec.preface, default = spec.default, callback = spec.callback }
    end
    return reply
  end
  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  local wizard_reply = matrix.cli({ "matrix", "setup" })
  assert(wizard_reply and pending_timeout == 300 and #line_specs == 1 and not resolved
    and line_specs[1].label == "Matrix homeserver URL",
    "no-flag setup should begin an interactive wizard")
  line_specs[1].callback("http://matrix.invalid", nil)
  assert(#line_specs == 2
    and line_specs[2].label == "Your Matrix user ID (for example @alice:example.org)",
    "the wizard should ask for the owner after the homeserver")
  line_specs[2].callback("@alice:example.org", nil)
  assert(#line_specs == 3 and line_specs[3].label:find("Continue? Type Y", 1, true)
    and line_specs[3].label:find("Bot: @butler%-")
    and line_specs[3].label:find("\n  Rooms: open (anyone can invite this Butler). Restrict: set rooms=allowlist or add deny_room/deny_server in "
      .. default_paths.config_path .. ". The sender allowlist still decides whose messages are trusted.\n", 1, true)
    and not line_specs[3].label:find("quarantined", 1, true)
    and not line_specs[3].label:find("Room access", 1, true)
    and line_specs[3].label:find("replaces its current Matrix relay config", 1, true),
    "the wizard should set open rooms and summarize the real config path")
  assert(line_specs[3].label:match("\n([^\n]*)$") == "Continue? Type Y to continue, or N to cancel",
    "the summary label should end with the bare question: core adds the [N]: suffix")
  -- #186: the summary is the prompt's preface; the label is only the question.
  assert(line_specs[3].question == "Continue? Type Y to continue, or N to cancel"
    and type(line_specs[3].preface) == "string" and line_specs[3].preface:find("^Matrix setup will:\n  Homeserver: ")
    and line_specs[3].preface:find("\n  Bot: @butler%-"),
    "the wizard summary is a preface and the label is only the question: " .. tostring(line_specs[3].question))
  do
    -- A very long value must not hit core's 256-character line cap (an error
    -- there would end the wizard): the wizard cuts the line itself.
    local long_owner = "@" .. string.rep("a", 400) .. ":example.org"
    requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
    matrix.cli({ "matrix", "setup" })
    line_specs[1].callback("http://matrix.invalid", nil)
    line_specs[2].callback(long_owner, nil)
    assert(#line_specs == 3 and not resolved and line_specs[3].preface:find("\n  Owner: @aaaa", 1, true)
      and not line_specs[3].preface:find(long_owner, 1, true),
      "a very long value is cut to fit a preface line: " .. tostring(resolved and resolved.stderr))
    line_specs[3].callback("N", nil)
    -- A core without preface (older daemons ignore it silently) keeps the
    -- summary in the label, as before.
    local supported = matrix.prompt_preface_supported
    matrix.prompt_preface_supported = function() return false end
    requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
    local legacy_ok, legacy_error = pcall(function()
      matrix.cli({ "matrix", "setup" })
      line_specs[1].callback("http://matrix.invalid", nil)
      line_specs[2].callback("@alice:example.org", nil)
      assert(#line_specs == 3 and line_specs[3].preface == nil
        and line_specs[3].question:find("^Matrix setup will:\n  Homeserver: ")
        and line_specs[3].question:match("\n([^\n]*)$") == "Continue? Type Y to continue, or N to cancel",
        "a core without preface keeps the summary in the label")
      line_specs[3].callback("N", nil)
    end)
    matrix.prompt_preface_supported = supported
    assert(legacy_ok, legacy_error)
    requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
    matrix.cli({ "matrix", "setup" })
    line_specs[1].callback("http://matrix.invalid", nil)
    line_specs[2].callback("@alice:example.org", nil)
  end
  assert(not line_specs[3].label:find("HTTPS", 1, true),
    "an http wizard summary should show no HTTPS trust line")
  assert(line_specs[3].default == "N", "wizard confirmation should default to no")
  line_specs[3].callback("n", nil)
  assert(resolved and resolved.status == 1 and resolved.stderr:find("Nothing was written.", 1, true)
    and select(2, resolved.stderr:gsub("Next:", "")) == 1
    and #requests == 0 and #prompt_specs == 0,
    "declining the summary should stop before registration or network work")

  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("http://matrix.invalid", nil)
  line_specs[2].callback("@alice:example.org", nil)
  line_specs[3].callback("Y", nil)
  assert(#prompt_specs == 1 and prompt_specs[1].label
    == "Registration token for http://matrix.invalid, from its admin (hidden). This is not an access token"
    and #requests == 0 and not resolved,
    "confirming the summary should enter the existing hidden registration-token flow")
  local wizard_bot = assert(line_specs[3].label:match("Bot: (@%S+)"), "wizard summary should name the bot")
  local wizard_relay, wizard_config, wizard_status = matrix.relay, remuda._butler_matrix_config, matrix.status
  matrix.relay = { stop = function() end, start = function() return true end }
  matrix.status = function(_, callback) callback({}) end
  prompt_specs[1].callback("wizard-registration-token", nil)
  requests[1].callback({ status = 401,
    body = '{"session":"wizard-session","flows":[{"stages":["m.login.registration_token"]}]}' })
  requests[2].callback({ status = 200,
    body = '{"access_token":"wizard-access-token","user_id":"' .. wizard_bot .. '"}' })
  requests[3].callback({ status = 200, body = '{"user_id":"' .. wizard_bot .. '"}' })
  requests[4].callback({ status = 200, body = '{"room_id":"!wizard-home:example.org"}' })
  matrix.relay, matrix.status = wizard_relay, wizard_status
  assert(resolved and resolved.status == 0 and read(default_paths.config_path):find("\nrooms=open\n", 1, true),
    "the confirmed wizard should write rooms=open to the config")
  for _, path in ipairs({ default_paths.token_path, default_paths.config_path,
    default_paths.config_path:gsub("/config$", "/password") }) do os.remove(path) end
  remuda._butler_matrix_config = wizard_config

  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("https://matrix.invalid", nil)
  line_specs[2].callback("@alice:example.org", nil)
  assert(#line_specs == 3
    and line_specs[3].label == "HTTPS trust: press Enter to use this system's trusted certificates, "
      .. "or enter a 64-character SHA-256 certificate pin or an absolute CA file path",
    "HTTPS setup should offer system trust on Enter, or a certificate pin or CA file: "
      .. tostring(line_specs[3] and line_specs[3].label))
  line_specs[3].callback(string.rep("a", 64), nil)
  assert(#line_specs == 4 and line_specs[4].label:find("HTTPS certificate pin: " .. string.rep("a", 64), 1, true)
    and line_specs[4].label:find("Continue? Type Y", 1, true),
    "the HTTPS summary should show the validated trust pin before confirmation")
  line_specs[4].callback("N", nil)
  assert(resolved and resolved.status == 1 and #requests == 0 and #prompt_specs == 0,
    "declining an HTTPS wizard should not start registration")

  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("https://matrix.invalid", nil)
  line_specs[2].callback("@alice:example.org", nil)
  line_specs[3].callback("", nil)
  assert(#line_specs == 4 and not resolved
    and line_specs[4].label:find("\n  HTTPS trust: this system's trusted certificates\n", 1, true)
    and not line_specs[4].label:find("HTTPS certificate pin", 1, true)
    and not line_specs[4].label:find("HTTPS CA file", 1, true)
    and line_specs[4].label:find("Continue? Type Y", 1, true),
    "Enter at the HTTPS trust prompt should use system trust: no pin, no CA file: "
      .. tostring(resolved and resolved.stderr))
  line_specs[4].callback("Y", nil)
  prompt_specs[1].callback("wizard-registration-token", nil)
  assert(#requests == 1 and requests[1].pin == nil and requests[1].ca_file == nil
    and requests[1].pin_only ~= true,
    "a system-trust wizard should send its first request with no pin and no CA file")

  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("https://matrix.invalid", nil)
  line_specs[2].callback("@alice:example.org", nil)
  local bad_ca_path = root .. "/missing\nca.pem"
  line_specs[3].callback(bad_ca_path, nil)
  assert(resolved and not resolved.stderr:find(bad_ca_path, 1, true)
    and resolved.stderr:find(bad_ca_path:gsub("\n", " "), 1, true),
    "wizard validation errors should sanitize control characters from entered paths")

  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("https://matrix.invalid", nil)
  line_specs[2].callback("@alice:example.org", nil)
  line_specs[3].callback(nil, nil)
  assert(resolved and resolved.status == 1 and resolved.stderr:find("Nothing was written.", 1, true)
    and select(2, resolved.stderr:gsub("Next:", "")) == 1 and #requests == 0,
    "a non-string HTTPS trust answer should fail safely instead of throwing")
  assert(resolved.stderr:find("The HTTPS trust answer must be Enter (this system's trusted certificates), "
    .. "a certificate pin or a CA file path.", 1, true),
    "the refused HTTPS trust answer should name Enter as a choice: " .. resolved.stderr)

  write(default_paths.token_path, "existing default token")
  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("http://matrix.invalid", nil)
  line_specs[2].callback("@alice:example.org", nil)
  assert(resolved and resolved.stderr:find("output file already exists", 1, true)
    and resolved.stderr:match("([^\n]+)\n$") == "Next: back up or move the existing Matrix setup files, then rerun remuda butler matrix setup.",
    "an existing output refusal should end with an actionable wizard next step")
  os.remove(default_paths.token_path)

  local prompt_output = root .. "/prompted-registration"
  assert(real_mkdir_new(prompt_output))
  local prompt_token = "prompted-registration-token"

  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("ftp://matrix.invalid", nil)
  assert(resolved and resolved.status == 1
    and resolved.stderr:find("Matrix setup arguments", 1, true) == nil
    and resolved.stderr:find("must be an absolute http:// or https:// URL", 1, true)
    and #line_specs == 1 and #requests == 0,
    "the wizard should reject an invalid homeserver URL before asking for more values: "
      .. tostring(resolved and resolved.stderr) .. " line prompts=" .. tostring(#line_specs))

  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("http://matrix.invalid", nil)
  line_specs[2].callback("alice", nil)
  assert(resolved and resolved.status == 1
    and resolved.stderr:find("is not a Matrix user ID", 1, true)
    and #line_specs == 2 and #requests == 0,
    "the wizard should reject a malformed owner MXID before continuing")

  local old_pending = remuda.pending
  remuda.pending = function()
    return { resolve = function(_, status, stdout, stderr)
      resolved = { status = status, stdout = stdout, stderr = stderr }
    end }
  end
  resolved = nil
  matrix.cli({ "matrix", "setup" })
  remuda.pending = old_pending
  assert(resolved and resolved.status == 1
    and resolved.stderr:find("needs a Remuda core with prompt_line", 1, true)
    and select(2, resolved.stderr:gsub("Next:", "")) == 1,
    "an older core without prompt_line should refuse the wizard with an upgrade hint")

  for _, prompt_error in ipairs({ "not_a_terminal", "too_long", "cancelled" }) do
    requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
    wizard_reply = matrix.cli({ "matrix", "setup" })
    line_specs[1].callback(nil, prompt_error)
    assert(resolved and resolved.status == 1 and resolved.stderr:find("Nothing was written.", 1, true)
      and select(2, resolved.stderr:gsub("Next:", "")) == 1 and #requests == 0,
      "wizard prompt errors should refuse safely: " .. prompt_error)
  end

  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("https://matrix.invalid", nil)
  line_specs[2].callback("@alice:example.org", nil)
  line_specs[3].callback(ca_file, nil)
  assert(#line_specs == 4 and line_specs[4].label:find("HTTPS CA file: " .. ca_file, 1, true)
    and line_specs[4].label:find("Continue? Type Y", 1, true),
    "the wizard should validate and summarize an HTTPS CA file path")
  line_specs[4].callback("N", nil)
  assert(resolved and resolved.status == 1 and #requests == 0,
    "declining the CA-file wizard should not start registration")

  -- #182: a stock Mac has no HOSTNAME in the daemon and no hostname file.
  local nameless_getenv, nameless_io_open = os.getenv, io.open
  os.getenv = function(name)
    if name == "HOSTNAME" or name == "COMPUTERNAME" then return nil end
    return nameless_getenv(name)
  end
  io.open = function(path, mode)
    if path == "/etc/hostname" or path == "/var/run/hostname" then return nil, "no such file" end
    return nameless_io_open(path, mode)
  end
  local nameless_ok, nameless_error = pcall(function()
    assert(type(matrix.setup_default_bot) == "function"
      and matrix.setup_default_bot("@alice:example.org") == nil,
      "a machine with no name source has no default bot")
    local _, no_bot_error = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
      "--owner", "@alice:example.org", "--register", "--dir", output })
    assert(no_bot_error and no_bot_error:find("cannot derive a bot account name from this computer", 1, true)
      and no_bot_error:find("\nNext: add --bot @butler-NAME:example.org", 1, true),
      "the flag form names --bot as the next step when no bot name can be derived: " .. tostring(no_bot_error))
    for _, bot_answer in ipairs({ "butler-mac", "@butler-mac:example.org" }) do
      requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
      wizard_reply = matrix.cli({ "matrix", "setup" })
      line_specs[1].callback("http://matrix.invalid", nil)
      line_specs[2].callback("@alice:example.org", nil)
      assert(#line_specs == 3 and not resolved and line_specs[3].label
        == "Butler bot name (for example butler-mac; it becomes @butler-mac:example.org)"
        and line_specs[3].default == nil,
        "the wizard asks for a bot name when none can be derived: " .. tostring(resolved and resolved.stderr))
      line_specs[3].callback(bot_answer, nil)
      assert(#line_specs == 4 and line_specs[4].label:find("\n  Bot: @butler-mac:example.org\n", 1, true)
        and line_specs[4].label:find("Continue? Type Y", 1, true),
        "the wizard summary shows the entered bot name: " .. bot_answer)
      line_specs[4].callback("N", nil)
    end
    for _, bad_answer in ipairs({ "", "bad name" }) do
      requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
      wizard_reply = matrix.cli({ "matrix", "setup" })
      line_specs[1].callback("http://matrix.invalid", nil)
      line_specs[2].callback("@alice:example.org", nil)
      line_specs[3].callback(bad_answer, nil)
      assert(#line_specs == 3 and resolved and resolved.status == 1
        and resolved.stderr:find("Nothing was written.", 1, true)
        and select(2, resolved.stderr:gsub("Next:", "")) == 1 and #requests == 0,
        "the wizard refuses a malformed or empty bot name: '" .. bad_answer .. "'")
    end
    requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
    wizard_reply = matrix.cli({ "matrix", "setup" })
    line_specs[1].callback("https://matrix.invalid", nil)
    line_specs[2].callback("@alice:example.org", nil)
    assert(#line_specs == 3 and line_specs[3].label:find("Butler bot name", 1, true),
      "with no machine name an https wizard asks for the bot name first")
    line_specs[3].callback("butler-mac", nil)
    assert(#line_specs == 4 and line_specs[4].label:find("HTTPS trust: press Enter", 1, true),
      "the https wizard asks for trust after the bot name")
    line_specs[4].callback("", nil)
    assert(#line_specs == 5 and not resolved
      and line_specs[5].label:find("\n  Bot: @butler-mac:example.org\n", 1, true)
      and line_specs[5].label:find("\n  HTTPS trust: this system's trusted certificates\n", 1, true),
      "the summary shows the entered bot and system trust: " .. tostring(resolved and resolved.stderr))
    line_specs[5].callback("N", nil)
  end)
  os.getenv, io.open = nameless_getenv, nameless_io_open
  assert(nameless_ok, nameless_error)
  requests, resolved, prompt_specs, line_specs = {}, nil, {}, {}
  wizard_reply = matrix.cli({ "matrix", "setup" })
  line_specs[1].callback("http://matrix.invalid", nil)
  line_specs[2].callback("@alice:example.org", nil)
  assert(#line_specs == 3 and line_specs[3].label:find("Continue? Type Y", 1, true),
    "with a name source the wizard shows no bot prompt")
  line_specs[3].callback("N", nil)

  do
    -- A long homeserver must not push the hidden token prompt over core's
    -- 256-character line, with or without the "rejected" notice in front.
    local long_homeserver = "http://" .. string.rep("a", 60) .. "." .. string.rep("b", 60) .. "."
      .. string.rep("c", 60) .. ".invalid"
    requests, resolved, prompt_specs = {}, nil, {}
    matrix.cli({ "matrix", "setup", "--homeserver", long_homeserver, "--owner", "@alice:example.org",
      "--register", "--bot", "@butler-prompt:example.org", "--dir", prompt_output })
    assert(#prompt_specs == 1 and not resolved
      and prompt_specs[1].label:find("^Registration token for http://aaaa")
      and prompt_specs[1].label:find("from its admin (hidden). This is not an access token", 1, true)
      and #prompt_specs[1].label + #matrix.REJECTED_REGISTRATION_TOKEN + 1 <= 256,
      "a long homeserver is shortened in the hidden token prompt: " .. tostring(resolved and resolved.stderr))
  end

  requests, resolved, prompt_specs = {}, nil, {}
  local prompt_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--bot", "@butler-prompt:example.org",
    "--dir", prompt_output })
  assert(prompt_reply and pending_timeout == 300 and #prompt_specs == 1 and not resolved,
    "registration setup should request its token before starting network work")
  assert(prompt_specs[1].label == "Registration token for http://matrix.invalid, from its admin (hidden). This is not an access token",
    "registration prompt should explain which token is needed")
  for attempt = 1, 3 do
    local attempt_token = prompt_token .. tostring(attempt)
    prompt_specs[attempt].callback("  " .. attempt_token .. "  \nignored", nil)
    local initial_index = (attempt - 1) * 2 + 1
    assert(#requests == initial_index and requests[initial_index].url == "http://matrix.invalid/_matrix/client/v3/register",
      "a prompted token should start the existing registration flow")
    requests[initial_index].callback({ status = 401,
      body = '{"session":"prompt-session-' .. tostring(attempt)
        .. '","flows":[{"stages":["m.login.registration_token"]}]}' })
    local token_index = initial_index + 1
    local token_request = request_json(requests[token_index])
    assert(token_request.auth and token_request.auth.type == "m.login.registration_token"
      and token_request.auth.token == attempt_token
      and token_request.auth.session == "prompt-session-" .. tostring(attempt)
      and not requests[token_index].url:find(attempt_token, 1, true)
      and not requests[token_index].headers.Authorization,
      "the trimmed prompted token should reach only the registration auth request")
    requests[token_index].callback({ status = 403,
      body = '{"errcode":"M_FORBIDDEN","error":"' .. attempt_token .. ' rejected"}' })
    if attempt < 3 then
      assert(not resolved and #prompt_specs == attempt + 1,
        "a rejected registration token should prompt again up to three total attempts")
      assert(prompt_specs[attempt + 1].label
        == "The server rejected that registration token. Nothing was created or written. "
          .. "Registration token for http://matrix.invalid, from its admin (hidden). This is not an access token",
        "the retry notice should be separated from the prompt label with a space")
    end
  end
  assert(resolved and resolved.status == 1
    and resolved.stderr:find("The server rejected that registration token. Nothing was created or written.", 1, true)
    and resolved.stderr:find("Next: rerun with --registration-token-file PATH", 1, true)
    and not resolved.stderr:find(prompt_token, 1, true)
    and #requests == 6 and #prompt_specs == 3,
    "three token rejections should stop safely without exposing a token")

  prompt_specs, requests, resolved = {}, {}, nil
  local disabled_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--bot", "@butler-disabled:example.org",
    "--dir", prompt_output })
  assert(disabled_reply and #prompt_specs == 1)
  local disabled_token = "never-sent-registration-token"
  prompt_specs[1].callback(disabled_token, nil)
  assert(#requests == 1 and not request_json(requests[1]).auth,
    "the first register request must not send the registration token")
  requests[1].callback({ status = 403, body = '{"errcode":"M_FORBIDDEN","error":"Registration has been disabled"}' })
  assert(resolved and resolved.status == 1 and #prompt_specs == 1
    and resolved.stderr:find("Account registration is disabled on this server. Nothing was created or written. Next: ask the server admin for a bot account, then rerun with --token-file PATH (the bot access token).", 1, true)
    and not resolved.stderr:find(disabled_token, 1, true),
    "a 403 before token submission should report disabled registration without prompting again")

  prompt_specs, requests, resolved = {}, {}, nil
  local drift_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--bot", "@butler-drift:example.org",
    "--dir", prompt_output })
  assert(drift_reply and #prompt_specs == 1)
  prompt_specs[1].callback("first-prompt-token", nil)
  requests[1].callback({ status = 400, body = '{"errcode":"M_USER_IN_USE"}' })
  assert(request_json(requests[2]).username == "butler-drift-2")
  requests[2].callback({ status = 401,
    body = '{"session":"drift-session","flows":[{"stages":["m.login.registration_token"]}]}' })
  requests[3].callback({ status = 403, body = '{"errcode":"M_FORBIDDEN"}' })
  assert(#prompt_specs == 2 and not resolved)
  prompt_specs[2].callback("second-prompt-token", nil)
  assert(request_json(requests[4]).username == "butler-drift",
    "a new token attempt should restart account-name selection from the original bot ID")

  prompt_specs, requests, resolved = {}, {}, nil
  local prompt_pending = remuda.pending
  remuda.pending = function(options)
    pending_timeout = options and options.timeout
    return { resolve = function(_, status, stdout, stderr)
      resolved = { status = status, stdout = stdout, stderr = stderr }
    end }
  end
  local old_core_ok, old_core_reply = pcall(matrix.cli, { "matrix", "setup",
    "--homeserver", "http://matrix.invalid", "--owner", "@alice:example.org",
    "--register", "--bot", "@butler-old-core:example.org", "--dir", prompt_output })
  remuda.pending = prompt_pending
  assert(old_core_ok and old_core_reply and resolved and resolved.status == 1
    and resolved.stderr:find("Nothing was written.", 1, true)
    and resolved.stderr:find("Next: rerun with --registration-token-file PATH (this remuda core has no hidden prompt; upgrade with remuda upgrade)", 1, true),
    "an older core without prompt_secret should fail with a clear upgrade hint")

  for _, prompt_error in ipairs({ "not_a_terminal", "refused", "too_long", "cancelled" }) do
    prompt_specs, requests, resolved = {}, {}, nil
    local error_output = root .. "/prompt-error-" .. prompt_error
    local error_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
      "--owner", "@alice:example.org", "--register", "--bot", "@butler-error:example.org",
      "--dir", error_output })
    assert(error_reply and #prompt_specs == 1 and not resolved,
      "registration setup should be pending while the hidden prompt is active")
    local leaked = "secret-from-" .. prompt_error
    prompt_specs[1].callback(leaked, prompt_error)
    assert(resolved and resolved.status == 1
      and resolved.stderr:find("Nothing was written.", 1, true)
      and resolved.stderr:find("Next: rerun with --registration-token-file PATH", 1, true)
      and not resolved.stderr:find(leaked, 1, true)
      and #requests == 0,
      "prompt errors should abort without writing or exposing the attempted token")
    if prompt_error == "not_a_terminal" then
      assert(resolved.stderr:find("needs a terminal", 1, true),
        "a non-terminal prompt failure should explain that a terminal is required")
    end
    assert(read(error_output .. "/token") == nil and read(error_output .. "/config") == nil,
      "prompt errors must leave setup files unwritten")
  end
  prompt_specs, requests, resolved = {}, {}, nil
  local empty_output = root .. "/prompt-empty"
  local empty_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--bot", "@butler-empty:example.org",
    "--dir", empty_output })
  assert(empty_reply and #prompt_specs == 1 and not resolved,
    "registration setup should start with a hidden prompt")
  for attempt = 1, 3 do
    prompt_specs[attempt].callback(" \t\r\n ", nil)
    if attempt < 3 then
      assert(not resolved and #prompt_specs == attempt + 1,
        "an empty token answer should ask again and consume one of the three tries")
      assert(prompt_specs[attempt + 1].label:find("The registration token was empty.", 1, true),
        "the retry prompt should explain that the registration token is empty")
    end
  end
  assert(resolved and resolved.status == 1
    and resolved.stderr:find("The registration token was empty.", 1, true)
    and resolved.stderr:find("Nothing was written.", 1, true)
    and resolved.stderr:find("Next: rerun with --registration-token-file PATH", 1, true)
    and #prompt_specs == 3 and #requests == 0,
    "three empty answers should stop without network work and show safe guidance")
  assert(read(empty_output .. "/token") == nil and read(empty_output .. "/config") == nil,
    "empty prompted answers must leave setup files unwritten")

  local real_write_atomic, atomic_writes = remuda.fs.write_atomic, {}
  local setup_http = remuda.http
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
  local registration_output = root .. "/registered-output"
  assert(remuda.fs.mkdir_new(registration_output))
  local requested_random_length
  local password_status = matrix.status
  matrix.status = function(_, callback)
    local generated_password = read(registration_output .. "/password")
    assert(generated_password and #generated_password == 44
      and generated_password:sub(-1) == "\n"
      and read(registration_output .. "/token") == "registered-access-token\n",
      "registration must persist its generated password and access token before status")
    callback({ status = 200, json = { user_id = "@butler-demo-2:example.org",
      joined_rooms = { "!registered-home:example.org" } } })
    return { cancel = function() end }
  end
  local no_rng_output = root .. "/no-secure-random"
  local real_io_open = io.open
  io.open = function(path, mode)
    if path == "/dev/urandom" then return nil, "simulated unavailable random source" end
    return real_io_open(path, mode)
  end
  requests, resolved = {}, nil
  local no_rng_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-no-rng:example.org", "--dir", no_rng_output })
  io.open = real_io_open
  assert(no_rng_reply and resolved and resolved.status == 1
    and pending_timeout == 90
    and resolved.stderr:find("This system has no secure random source for a bot password. Next: rerun with --password-file PATH (a password you choose)", 1, true)
    and #requests == 0
    and read(no_rng_output .. "/token") == nil
    and read(no_rng_output .. "/password") == nil
    and read(no_rng_output .. "/config") == nil,
    "registration must fail closed without secure randomness before network or file writes")
  local no_rng_dir_created = remuda.fs.mkdir_new(no_rng_output)
  assert(no_rng_dir_created, "secure-random failure must not create the output directory")
  os.remove(no_rng_output)

  local short_rng_output = root .. "/short-secure-random"
  io.open = function(path, mode)
    if path == "/dev/urandom" then
      return { read = function() return string.rep("x", 31) end, close = function() end }
    end
    return real_io_open(path, mode)
  end
  requests, resolved = {}, nil
  matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-short-rng:example.org", "--dir", short_rng_output })
  io.open = real_io_open
  assert(resolved and resolved.status == 1
    and resolved.stderr:find("This system has no secure random source for a bot password", 1, true)
    and #requests == 0 and read(short_rng_output .. "/password") == nil,
    "a short secure-random read must also fail closed before network or file writes")
  local short_rng_dir_created = remuda.fs.mkdir_new(short_rng_output)
  assert(short_rng_dir_created, "short secure-random read must not create the output directory")
  os.remove(short_rng_output)

  io.open = function(path, mode)
    if path == "/dev/urandom" then
      return {
        read = function(_, count)
          requested_random_length = count
          return string.rep(string.char(251), count)
        end,
        close = function() end,
      }
    end
    return real_io_open(path, mode)
  end
  requests, resolved = {}, nil
  local registration_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-demo:example.org", "--dir", registration_output })
  assert(registration_reply and #requests == 1)
  local first_registration = request_json(requests[1])
  assert(first_registration.username == "butler-demo"
    and first_registration.inhibit_login == false
    and #first_registration.password == 43
    and first_registration.password:match("^[%w_-]+$")
    and requested_random_length == 32,
    "registration should make a base64url password from 32 random bytes")
  local generated_password = first_registration.password
  requests[1].callback({ status = 400,
    body = '{"errcode":"M_USER_IN_USE","error":"private collision detail"}' })
  assert(#requests == 2, "an occupied bot name should retry registration")
  local retry_registration = request_json(requests[2])
  assert(retry_registration.username == "butler-demo-2"
    and retry_registration.password == generated_password,
    "registration collision retries should append -2 and reuse the generated password")
  requests[2].callback({ status = 401,
    body = '{"session":"retry-session","flows":[{"stages":["m.login.registration_token"]}]}' })
  assert(#requests == 3)
  local token_auth = request_json(requests[3])
  assert(token_auth.username == "butler-demo-2"
    and token_auth.auth.type == "m.login.registration_token"
    and token_auth.auth.session == "retry-session"
    and token_auth.auth.token == "homeserver-registration-token")
  requests[3].callback({ status = 200,
    body = '{"access_token":"registered-access-token","user_id":"@butler-demo-2:example.org"}' })
  assert(#requests == 4 and requests[4].url:match("/account/whoami$"),
    "registration must continue through the normal whoami verification")
  assert(requests[4].headers.Authorization == "Bearer registered-access-token")
  requests[4].callback({ status = 200, body = '{"user_id":"@butler-demo-2:example.org"}' })
  assert(#requests == 5 and requests[5].url:match("/createRoom$"),
    "registration must continue to create the HOME room and invite the owner")
  assert(requests[5].body:find("@alice:example.org", 1, true)
    and not requests[5].body:find("m.room.encryption", 1, true))
  requests[5].callback({ status = 200, body = '{"room_id":"!registered-home:example.org"}' })
  assert(resolved and resolved.status == 0
    and not resolved.stdout:find("homeserver-registration-token", 1, true)
    and not resolved.stdout:find(generated_password, 1, true)
    and not resolved.stdout:find("registered-access-token", 1, true)
    and resolved.stdout:find(registration_output .. "/password", 1, true),
    "registration success should report the private password file path without any secret")
  assert(read(registration_output .. "/password") == generated_password .. "\n"
    and read(registration_output .. "/token") == "registered-access-token\n"
    and read(registration_output .. "/config"):find("@butler-demo-2:example.org", 1, true),
    "registration setup should persist generated credentials and the selected bot ID")
  assert(#atomic_writes == 3 and atomic_writes[1].private
    and atomic_writes[2].private and atomic_writes[3].private,
    "registration token, generated password, and config must use private atomic writes")
  matrix.status = password_status
  io.open = real_io_open
  requests, resolved, atomic_writes = {}, nil, {}
  os.remove(registration_output .. "/token")
  os.remove(registration_output .. "/password")
  os.remove(registration_output .. "/config")
  os.remove(registration_output)

  local chosen_output = root .. "/chosen-password-output"
  assert(remuda.fs.mkdir_new(chosen_output))
  local chosen_status = matrix.status
  matrix.status = function(_, callback)
    assert(read(chosen_output .. "/password") == "password-secret\n"
      and read(chosen_output .. "/token") == "chosen-access-token\n",
      "chosen password and access token should be saved before status")
    callback({ status = 200, json = { user_id = "@butler-chosen:example.org",
      joined_rooms = { "!chosen-home:example.org" } } })
    return { cancel = function() end }
  end
  local secure_random_attempts = 0
  io.open = function(path, mode)
    if path == "/dev/urandom" then
      secure_random_attempts = secure_random_attempts + 1
      return nil, "chosen password should not need generated randomness"
    end
    return real_io_open(path, mode)
  end
  requests, resolved = {}, nil
  local chosen_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--password-file", password, "--bot", "@butler-chosen:example.org",
    "--dir", chosen_output })
  assert(chosen_reply and #requests == 1 and requests[1].url:match("/register$"))
  local chosen_initial = request_json(requests[1])
  assert(chosen_initial.password == "password-secret" and chosen_initial.username == "butler-chosen",
    "--register --password-file should submit the caller's chosen password")
  requests[1].callback({ status = 401,
    body = '{"session":"chosen-session","flows":[{"stages":["m.login.registration_token"]}]}' })
  local chosen_auth = request_json(requests[2])
  assert(chosen_auth.password == "password-secret"
    and chosen_auth.auth.token == "homeserver-registration-token"
    and chosen_auth.auth.session == "chosen-session")
  requests[2].callback({ status = 200,
    body = '{"access_token":"chosen-access-token","user_id":"@butler-chosen:example.org"}' })
  requests[3].callback({ status = 200, body = '{"user_id":"@butler-chosen:example.org"}' })
  requests[4].callback({ status = 200, body = '{"room_id":"!chosen-home:example.org"}' })
  local chosen_start_line = "Next: REMUDA_BUTLER_TOKEN='" .. chosen_output .. "/token'"
    .. " REMUDA_BUTLER_CONFIG='" .. chosen_output .. "/config' remuda -s matrix-test daemon"
  assert(resolved and resolved.status == 0
    and resolved.stdout:find("Accept the invite in Element before starting this separate Butler.", 1, true)
    and resolved.stdout:match("([^\n]+)\n$") == chosen_start_line
    and not resolved.stdout:find("password-secret", 1, true)
    and not resolved.stdout:find("homeserver-registration-token", 1, true)
    and not resolved.stdout:find("chosen-access-token", 1, true)
    and read(chosen_output .. "/password") == "password-secret\n"
    and secure_random_attempts == 0,
    "chosen-password registration should save privately, avoid secrets in output, and print a real next step")
  assert(#atomic_writes == 3 and atomic_writes[1].private
    and atomic_writes[2].private and atomic_writes[3].private,
    "chosen password, token, and config must all use private atomic writes")
  io.open = real_io_open
  matrix.status = chosen_status
  requests, resolved, atomic_writes = {}, nil, {}
  os.remove(chosen_output .. "/token")
  os.remove(chosen_output .. "/password")
  os.remove(chosen_output .. "/config")
  os.remove(chosen_output)

  local collision_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-busy:example.org", "--dir", root .. "/collision-output" })
  assert(collision_plan)
  requests, resolved = {}, nil
  remuda.http = { request = function(spec)
    requests[#requests + 1] = spec
    return { cancel = function() end }
  end }
  matrix.setup_network(collision_plan, function(result) resolved = result end)
  local expected_usernames = { "butler-busy", "butler-busy-2", "butler-busy-3",
    "butler-busy-4", "butler-busy-5" }
  for index, username in ipairs(expected_usernames) do
    assert(#requests == index and request_json(requests[index]).username == username,
      "registration should try bot usernames in order through -5")
    requests[index].callback({ status = 400,
      body = '{"errcode":"M_USER_IN_USE","error":"private collision detail"}' })
  end
  assert(resolved and resolved.error
    == "Bot account names ending in -2 through -5 are also in use. Pass --bot with another name. Nothing was created or written."
    and #requests == 5,
    "registration should stop after five taken names with clear guidance")
  remuda.http = setup_http
  requests, resolved = {}, nil

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
  local separate_output_start = "Next: REMUDA_BUTLER_TOKEN='" .. output .. "/token'"
    .. " REMUDA_BUTLER_CONFIG='" .. output .. "/config' remuda -s matrix-test daemon"
  assert(resolved and resolved.status == 0 and resolved.stdout:find("!home:example.org", 1, true)
    and resolved.stdout:find("!all:example.org", 1, true)
    and resolved.stdout:find("Status: User: @butler-demo:example.org; Joined rooms: 2", 1, true)
    and resolved.stdout:find("Accept the invite in Element before starting this separate Butler.", 1, true)
    and resolved.stdout:match("([^\n]+)\n$") == separate_output_start
    and not resolved.stdout:find("Next: delete", 1, true)
    and not resolved.stdout:find("password-secret", 1, true)
    and not resolved.stdout:find("temporary-access-token", 1, true),
    "setup CLI output must report saved rooms without secrets")
  assert(read(output .. "/token") == "temporary-access-token\n")
  assert(read(output .. "/config") == table.concat({ "http://matrix.invalid",
    "!home:example.org", "@butler-demo:example.org", "@alice:example.org", "", "30000",
    "all_room=!all:example.org", "" }, "\n"))
  assert(#atomic_writes == 2 and atomic_writes[1].private and atomic_writes[2].private,
    "token and config must both use private atomic writes")

  -- A successful default setup must update the in-memory config resolved at
  -- boot and replace only the relay, without printing the old reload hint.
  local saved_setup_network, saved_setup_status = matrix.setup_network, matrix.status
  local saved_relay_start, saved_relay_stop = matrix.relay.start, matrix.relay.stop
  local saved_matrix_config = remuda._butler_matrix_config
  local relay_events, started_config = {}, nil
  local relay_running = true
  matrix.setup_network = function(_, callback)
    callback({ token = "default-access-token", user_id = "@butler-demo:example.org",
      home_room = "!default-home:example.org" })
    return { cancel = function() end }
  end
  matrix.status = function(_, callback)
    callback({ status = 200, json = { user_id = "@butler-demo:example.org", joined_rooms = {} } })
    return { cancel = function() end }
  end
  matrix.relay.stop = function()
    relay_events[#relay_events + 1] = "stop"
    relay_running = false
    return true
  end
  matrix.relay.start = function(config)
    assert(not relay_running, "setup must stop the existing relay before starting its replacement")
    relay_events[#relay_events + 1] = "start"
    started_config = config
    relay_running = true
    return true
  end
  remuda._butler_matrix_paths = default_paths
  remuda._butler_matrix_config = { token_path = default_paths.token_path,
    config_path = default_paths.config_path }
  requests, resolved = {}, nil
  local default_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--default" })
  local invite_line = "Next: Accept the invite in Element, then write in the room."
  local expected_last_line = "Next: accept the invite in Element; the relay is running, so write to the Butler there."
  local output_last_line = resolved and resolved.stdout:match("([^\n]+)\n$")
  assert(default_reply and resolved and resolved.status == 0
    and table.concat(relay_events, ",") == "stop,start"
    and started_config and started_config.token_path == default_paths.token_path
    and started_config.config_path == default_paths.config_path
    and remuda._butler_matrix_config == started_config
    and resolved.stdout:match("([^\n]+)\n$") == expected_last_line
    and not resolved.stdout:find("reload", 1, true)
    and not resolved.stdout:find("remuda stop", 1, true)
    and not default_refusal:find("reload", 1, true)
    and not default_refusal:find("remuda stop", 1, true),
    "default setup must replace the relay from boot-resolved paths, end with the running message, and contain no reload or stop hints; events="
      .. table.concat(relay_events, ",") .. "; last=" .. tostring(output_last_line)
      .. "; refusal_reload=" .. tostring(default_refusal and default_refusal:find("reload", 1, true) ~= nil))

  relay_events, started_config, relay_running = {}, nil, true
  matrix.relay.start = function(config)
    assert(not relay_running, "failed-start case must still stop the running relay first")
    relay_events[#relay_events + 1] = "start"
    started_config = config
    return false
  end
  requests, resolved = {}, nil
  local failed_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--default", "--force" })
  local failed_invite_at = resolved and resolved.stdout:find(invite_line, 1, true)
  local relay_failed_at = resolved and resolved.stdout:find("Relay failed to start: relay.start returned false", 1, true)
  local status_next_at = resolved and resolved.stdout:find(
    "Next: fix the config, then rerun remuda butler matrix setup ... --default --force", 1, true)
  assert(failed_reply and resolved and resolved.status == 0
    and table.concat(relay_events, ",") == "stop,start"
    and failed_invite_at and relay_failed_at and status_next_at
    and failed_invite_at < relay_failed_at and relay_failed_at < status_next_at
    and resolved.stdout:match("([^\n]+)\n$")
      == "Next: fix the config, then rerun remuda butler matrix setup ... --default --force",
    "a false relay start must preserve invite guidance, report the reason, and end with a recovery Next step")

  matrix.relay.start = function()
    error("bad\nconfig")
  end
  requests, resolved = {}, nil
  local throwing_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--default", "--force" })
  local throwing_error_line = resolved and resolved.stdout:match("([^\n]*Relay failed to start:[^\n]*)")
  assert(throwing_reply and resolved and resolved.status == 0
    and resolved.stdout:find(invite_line, 1, true)
    and throwing_error_line and throwing_error_line:find("bad config", 1, true)
    and resolved.stdout:match("([^\n]+)\n$")
      == "Next: fix the config, then rerun remuda butler matrix setup ... --default --force",
    "a throwing relay start must print its terminal-safe reason and an actionable setup recovery")

  local live_config = remuda._butler_matrix_config
  relay_events, started_config = {}, nil
  matrix.relay.stop = function()
    error("--dir setup must not stop the live relay")
  end
  matrix.relay.start = function()
    error("--dir setup must not start the live relay")
  end
  local separate_dir = root .. "/separate-butler"
  requests, resolved = {}, nil
  local separate_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", separate_dir })
  local separate_start_line = "Next: REMUDA_BUTLER_TOKEN='" .. separate_dir .. "/token'"
    .. " REMUDA_BUTLER_CONFIG='" .. separate_dir .. "/config' remuda -s matrix-test daemon"
  assert(separate_reply and resolved and resolved.status == 0
    and #relay_events == 0 and remuda._butler_matrix_config == live_config
    and resolved.stdout:find("Accept the invite in Element before starting this separate Butler.", 1, true)
    and resolved.stdout:match("([^\n]+)\n$") == separate_start_line
    and not resolved.stdout:find("reload", 1, true)
    and not resolved.stdout:find("remuda stop", 1, true),
    "--dir setup must leave the live relay config untouched and print no restart hints")
  os.remove(separate_dir .. "/token")
  os.remove(separate_dir .. "/config")
  os.remove(separate_dir)

  -- Exercise the real module start path and deliver one scripted sync event
  -- after setup, with no daemon or module restart between setup and delivery.
  matrix.relay.start, matrix.relay.stop = saved_relay_start, saved_relay_stop
  dofile("packages/butler/matrix_request.lua")
  local saved_emit = remuda.emit_until_success
  local saved_http = remuda.http
  local saved_config = remuda._butler_matrix_config
  local scripted_requests, delivered_mail = {}, {}
  remuda.http = { request = function(spec)
    scripted_requests[#scripted_requests + 1] = spec
    return { cancel = function() end }
  end }
  remuda.emit_until_success = function(hook, message)
    assert(hook == "butler/deliver")
    delivered_mail[#delivered_mail + 1] = message
    return true
  end
  requests, resolved = {}, nil
  local delivered_reply = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--default", "--force" })
  assert(delivered_reply and resolved and resolved.status == 0
    and resolved.stdout:match("([^\n]+)\n$") == expected_last_line
    and matrix.relay.instance and #scripted_requests == 1,
    "setup must start the real relay against its newly written default config")
  scripted_requests[1].callback({ status = 200, headers = {}, body = '{"next_batch":"setup-s0"}' })
  local rate_timer
  for _, timer in ipairs(remuda._relay_timers) do
    if not timer.cancelled and timer.spec.every == 0.25 then rate_timer = timer; break end
  end
  assert(rate_timer, "scripted relay sync should have a rate-limit timer")
  rate_timer.spec.run()
  assert(#scripted_requests == 2, "relay should continue syncing after the initial baseline")
  scripted_requests[2].callback({ status = 200, headers = {}, body =
    '{"next_batch":"setup-s1","rooms":{"join":{"!default-home:example.org":{"timeline":{"events":[{"type":"m.room.message","event_id":"$after-setup","sender":"@alice:example.org","content":{"msgtype":"m.text","body":"hello after setup"}}]}}}}}' })
  assert(#delivered_mail == 1 and delivered_mail[1].text == "hello after setup"
    and delivered_mail[1].matrix.event_id == "$after-setup",
    "the newly started relay must deliver mail immediately after setup without a restart")
  matrix.relay.stop()
  remuda.http, remuda.emit_until_success = saved_http, saved_emit
  remuda._butler_matrix_config = saved_config
  os.remove(default_paths.config_path .. ".since")
  os.remove(default_paths.config_path .. ".acks")

  matrix.setup_network, matrix.status = saved_setup_network, saved_setup_status
  matrix.relay.start, matrix.relay.stop = saved_relay_start, saved_relay_stop
  remuda._butler_matrix_config = saved_matrix_config
  remuda._butler_matrix_paths = nil
  os.remove(default_paths.token_path)
  os.remove(default_paths.config_path)

  remuda.fs.write_atomic = real_write_atomic
  remuda.http = fake_http

  local registration_token = root .. "/registration-token"
  write(registration_token, "server-registration-token")
  local token_guidance = "This is not a valid access token for any account. If it is the server's registration token, use --register (creates the bot account). Nothing was written."
  local function failed_whoami_does_not_write(label, status, body)
    local failed_parent = root .. "/failed-output-" .. label
    local failed_dir = failed_parent .. "/butler"
    requests, resolved = {}, nil
    remuda.http = { request = function(spec) requests[#requests + 1] = spec; return {} end }
    matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
      "--owner", "@alice:example.org", "--token-file", registration_token, "--dir", failed_dir })
    assert(#requests == 1 and requests[1].url == "http://matrix.invalid/_matrix/client/v3/account/whoami",
      "token setup should verify the registration token with whoami")
    requests[1].callback({ status = status, body = body })
    assert(resolved and resolved.status == 1 and resolved.stderr:find(token_guidance, 1, true)
      and not resolved.stderr:find("private response body", 1, true)
      and not resolved.stderr:find("server-registration-token", 1, true),
      "registration-token failure should give safe --register guidance")
    assert(read(failed_dir .. "/token") == nil and read(failed_dir .. "/config") == nil,
      "failed whoami must not write token or config files")
    local parent_created, parent_error = remuda.fs.mkdir_new(failed_parent)
    assert(parent_created, "failed whoami created output directory: " .. tostring(parent_error))
    local child_created, child_error = remuda.fs.mkdir_new(failed_dir)
    assert(child_created, "failed whoami created nested output directory: " .. tostring(child_error))
    assert(os.remove(failed_dir) and os.remove(failed_parent), "failed-output test fixture cleanup failed")
  end
  failed_whoami_does_not_write("401", 401,
    '{"errcode":"M_UNKNOWN_TOKEN","error":"private response body"}')
  failed_whoami_does_not_write("errcode", 403,
    '{"errcode":"M_UNKNOWN_TOKEN","error":"private response body"}')
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

  write(output .. "/config", "previous-config\ndeny_room=!blocked:example.org\n"
    .. "deny_room=#spam:example.org\ndeny_server=evil.example.org\nrooms=open\n"
    .. "  deny_room = !indented:example.org\n")
  local kept, kept_error = matrix.setup_write(forced_plan, {
    token = "replacement-token", user_id = "@butler-demo:example.org",
    home_room = "!kept-home:example.org",
  })
  assert(kept, kept_error)
  local kept_config = read(output .. "/config")
  assert(kept_config:find("\ndeny_room=!blocked:example.org\n", 1, true)
    and kept_config:find("\ndeny_room=#spam:example.org\n", 1, true)
    and kept_config:find("\ndeny_server=evil.example.org\n", 1, true)
    and kept_config:find("\n  deny_room = !indented:example.org\n", 1, true)
    and not kept_config:find("previous-config", 1, true),
    "--force must keep hand-added deny_room=/deny_server= lines: " .. kept_config)
  write(output .. "/token", "previous-token\n")
  write(output .. "/config", "previous-config\n")

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

  local registration_rollback_dir = root .. "/registration-rollback/child"
  local registration_rollback_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--register", "--registration-token-file",
    registration_token_file, "--bot", "@butler-rollback:example.org",
    "--dir", registration_rollback_dir })
  assert(registration_rollback_plan)
  remuda.fs.write_atomic = function(path, contents, opts)
    if path == registration_rollback_dir .. "/config" then return nil, "simulated disk failure" end
    return real_write_atomic(path, contents, opts)
  end
  local registration_rollback_result, registration_rollback_error = matrix.setup_write(
    registration_rollback_plan, { token = "rollback-token", password = "rollback-password",
      user_id = "@butler-rollback:example.org", home_room = "!rollback:example.org" })
  assert(not registration_rollback_result and registration_rollback_error
    and read(registration_rollback_dir .. "/token") == nil
    and read(registration_rollback_dir .. "/password") == nil,
    "failed registration config write must roll back both token and generated password")
  local registration_rollback_parent = remuda.fs.mkdir_new(root .. "/registration-rollback")
  local registration_rollback_child = remuda.fs.mkdir_new(registration_rollback_dir)
  assert(registration_rollback_parent and registration_rollback_child,
    "failed registration write must remove newly created directories")
  os.remove(registration_rollback_dir)
  os.remove(root .. "/registration-rollback")
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
