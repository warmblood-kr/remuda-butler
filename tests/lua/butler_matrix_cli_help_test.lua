local function start_butler()
  local repo = assert(os.getenv("REMUDA_LUA_REPO"))
  T.install_mod("butler", repo)
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "Butler root start")
end

T.test("Matrix verbs use declared parser help with arguments, options, defaults and examples", function()
  start_butler()
  local verbs = {
    "status", "rooms", "history", "thread", "event", "get", "follow", "unfollow",
    "quarantine", "download", "send", "reply", "react", "upload", "redact", "join", "leave", "mark-all",
  }
  for _, verb in ipairs(verbs) do
    local help = T.eval("return remuda.butler.matrix.cli({\"matrix\", \"" .. verb .. "\", \"--help\"})")
    T.expect(help:find("Usage: remuda butler matrix " .. verb, 1, true),
      verb .. " help omitted its exact usage: " .. help)
    T.expect(help:find("Example:", 1, true), verb .. " help omitted an example: " .. help)
  end
  local history = T.eval('return remuda.butler.matrix.cli({"matrix", "history", "--help"})')
  T.expect(history:find("default: 20", 1, true) and history:find("1..200", 1, true),
    "history help omitted its default or range: " .. history)
  local download = T.eval('return remuda.butler.matrix.cli({"matrix", "download", "--help"})')
  T.expect(download:find("$HOME/matrix-<media>", 1, true),
    "download help omitted its default output path: " .. download)
  local setup = T.eval('return remuda.butler.matrix.cli({"matrix", "setup", "--help"})')
  T.expect(setup:find("Usage: remuda butler matrix setup [OPTIONS]", 1, true)
      and setup:find("--password-cmd", 1, true) and setup:find("allowlist (default)", 1, true)
      and setup:find("Example:", 1, true),
    "setup help omitted its options, default policy or example: " .. setup)
end)

T.test("Matrix setup parses options and trailing password-command argv through remuda.cli.parse", function()
  start_butler()
  local result = T.eval([[
    local setup = remuda.butler.matrix
    local output_dir = assert(os.getenv("REMUDA_LUA_SCRATCH")) .. "/matrix-setup-test"
    local plan, err = setup.setup_prepare({
      "--homeserver", "https://matrix.example.org", "--owner", "@alice:example.org",
      "--register", "--dir", output_dir, "--password-cmd", "printf", "%s", "secret",
    })
    if not plan then return "failed:" .. tostring(err) end
    local empty, missing = setup.setup_prepare({ "--password-cmd" })
    local _, duplicate = setup.setup_prepare({ "--force", "--force" })
    return remuda.json.encode({
      command = plan.password_cmd,
      secret = plan.password_secret,
      missing = missing,
      duplicate_rejected = duplicate ~= nil,
      empty_plan = empty == nil,
    })
  ]])
  T.expect(result:find('"printf"', 1, true) and result:find('"%s"', 1, true)
      and result:find('"secret"', 1, true)
      and result:find("--password-cmd requires a program", 1, true)
      and result:find('"duplicate_rejected":true', 1, true),
    "setup parser did not preserve the command argv or reject missing/repeated options: " .. result)
end)
