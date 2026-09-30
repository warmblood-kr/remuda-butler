return function(matrix)
  assert(type(matrix.setup_prepare) == "function", "Matrix setup validator is unavailable")
  assert(type(matrix.cli) == "function", "Matrix CLI router is unavailable")
  assert(matrix.cli({ "matrix", "setup" }) == matrix.setup_usage())
  assert(matrix.cli({ "matrix", "setup", "--help" }) == matrix.setup_usage())

  local root = os.tmpname()
  os.remove(root)
  assert(os.execute("mkdir -p " .. string.format("%q", root)))
  local password = root .. "/password"
  local token = root .. "/token"
  local output = root .. "/output"
  assert(os.execute("mkdir -p " .. string.format("%q", output)))
  local function write(path, content)
    local file = assert(io.open(path, "wb")); file:write(content or "secret"); file:close()
  end
  local function q(path) return string.format("%q", path) end
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

  write(password)
  assert(os.execute("chmod 600 " .. q(password)))
  local fake_http = remuda.http
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
  assert(calls == 0, "setup validation must not make network requests")
  assert(io.open(plan.token_path, "rb") == nil and io.open(plan.config_path, "rb") == nil,
    "setup validation must not create the output files")
  for _, value in pairs(plan) do
    assert(value ~= "secret", "setup plan must not contain secret contents")
  end
  local cli_text = matrix.cli({ "matrix", "setup", "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output })
  assert(cli_text:find("inputs validated", 1, true) and calls == 0,
    "setup CLI validation must not make network requests")
  remuda.http = fake_http

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
  local ca_file = root .. "/ca.pem"
  write(ca_file, "certificate")
  local ca_plan = matrix.setup_prepare({ "--homeserver", "https://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--dir", output, "--ca-file", ca_file })
  assert(ca_plan and ca_plan.ca_file == ca_file, "readable HTTPS CA file should validate")
  rejected({ "--homeserver", "https://matrix.invalid", "--owner", "@alice:example.org",
    "--bot", "@butler-demo:example.org", "--password-file", password, "--dir", output,
    "--pin", pin, "--ca-file", ca_file }, "choose one")

  assert(os.execute("chmod 644 " .. q(password)))
  rejected(args("--password-file", password, { "--bot", "@butler-demo:example.org" }), "mode 600")
  assert(os.execute("chmod 600 " .. q(password)))

  local source = root .. "/existing-source"
  write(source, "keep")
  write(output .. "/token", "existing")
  rejected(args("--password-file", password, { "--bot", "@butler-demo:example.org" }), "--force")
  local forced = matrix.setup_prepare(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--force" }))
  assert(forced, "--force should authorize replacing existing output files")

  os.remove(output .. "/token")
  assert(os.execute("ln -s " .. q(source) .. " " .. q(output .. "/token")))
  rejected(args("--password-file", password, { "--bot", "@butler-demo:example.org" }), "symlink")
  local symlink_force = matrix.setup_prepare(args("--password-file", password,
    { "--bot", "@butler-demo:example.org", "--force" }))
  assert(symlink_force, "--force should authorize replacing a symlink output")

  local default_dir = os.getenv("XDG_CONFIG_HOME")
  if not default_dir or default_dir == "" then default_dir = (os.getenv("HOME") or "") .. "/.config" end
  local default_paths = { token_path = default_dir .. "/remuda/butler/token",
    config_path = default_dir .. "/remuda/butler/config" }
  remuda._butler_matrix_paths = default_paths
  rejected({ "--homeserver", "http://matrix.invalid", "--owner", "@alice:example.org",
    "--bot", "@butler-demo:example.org", "--password-file", password }, "--default")
  local default = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--bot", "@butler-demo:example.org",
    "--password-file", password, "--default", "--force" })
  assert(default, "--default should authorize the resolved live paths")
  remuda._butler_matrix_paths = nil

  write(token)
  assert(os.execute("chmod 600 " .. q(token)))
  local token_plan = matrix.setup_prepare({ "--homeserver", "http://matrix.invalid",
    "--owner", "@alice:example.org", "--token-file", token, "--dir", output, "--force" })
  assert(token_plan and token_plan.secret_kind == "token" and token_plan.bot_mxid == nil,
    "token setup discovers the bot MXID with whoami in the network phase")

  os.execute("rm -rf " .. q(root))
end
