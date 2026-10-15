-- Actual JSON, atomic filesystem writes, and native Codex parsers in a private core.
assert(remuda and remuda.json, "run with tests/butler_coordination_config.sh")
local permissions = dofile("packages/butler/permissions.lua")
local config = dofile("packages/butler/coordination_config.lua")
local _, is_symlink = permissions.fs_helpers(remuda.fs)
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function read(path)
  local f, _, code = io.open(path, "rb")
  if not f then return nil, code ~= 2 and "unreadable" or nil end
  local text = f:read("*a"); f:close()
  return text, text == nil and "unreadable" or nil -- same contract as main.lua read_checked
end
local fs = {
  read_checked = read, is_symlink = is_symlink, json = remuda.json,
  mkdir = remuda.mkdir,
  codex_home = os.getenv("HOME") .. "/.codex", -- fixture HOME holds no Codex layer
  native_servers = function(cwd, home) -- Codex's own effective view, as main.lua does
    local r = remuda.process.run({ argv = { "codex", "mcp", "list", "--json" }, timeout = 5, cwd = cwd,
      env = { CODEX_HOME = home } })
    if r.code ~= 0 then return nil end
    return remuda.json.decode(r.stdout)
  end,
  write = function(path, text) return remuda.fs.write_atomic(path, text, { private = true }) end,
}
fs.validate = config.validator(remuda.process.run, remuda.fs.mkdir_new, fs.write,
  function(path, recursive) if recursive then remuda.remove_dir_all(path) else os.remove(path) end end,
  function() return true end)
local function fixture(run)
  local dir = os.tmpname(); os.remove(dir); assert(remuda.fs.mkdir_new(dir))
  local ok, err = pcall(run, dir)
  remuda.remove_dir_all(dir)
  if not ok then error(err, 0) end
end
local function put(path, text)
  remuda.mkdir(path:match("^(.*)/[^/]+$")); assert(fs.write(path, text))
end
local function paths(dir)
  return dir .. "/.claude/settings.local.json", dir .. "/.codex/config.toml", dir .. "/.codex/rules/remuda.rules"
end
local function ensure(dir, kind)
  local report = config.ensure(dir, kind, fs, permissions)
  check(not report.error, report.error or "initialize")
  return report
end

-- Without a native Codex (CI has none) only the Codex-less behaviour is
-- exercised: literal fresh defaults, per-client independence, fail-closed shapes.
local codex_ok, codex_probe = pcall(remuda.process.run, { argv = { "codex", "--version" }, timeout = 5 })
if not (codex_ok and codex_probe and codex_probe.code == 0) then
  local bare = setmetatable({
    native_servers = function() return nil end,
    validate = config.validator(function() error("no native Codex") end, function() return true end,
      fs.write, os.remove, function() return false end),
  }, { __index = fs })
  fixture(function(dir)
    local report = config.ensure(dir, "claude", bare, permissions)
    check(not report.error and read(dir .. "/.claude/settings.local.json") ~= nil, "Claude initializes without Codex")
    local text = read(dir .. "/.codex/config.toml")
    check(text and text:find('command = "remuda"', 1, true) and not text:find("enabled", 1, true),
      "fresh Codex literal written without policy fields")
    check(#config.ensure(dir, "codex", bare, permissions).written == 0, "repeat is stable")
  end)
  fixture(function(dir)
    local split = setmetatable({ read_checked = function(path)
      if path:find("/.codex/", 1, true) then return nil, "unreadable" end
      return read(path)
    end }, { __index = bare })
    local report = config.ensure(dir, "claude", split, permissions)
    check(not report.error and report.blocked.codex ~= nil, "unreadable Codex file blocks only Codex")
  end)
  fixture(function(dir)
    local blind = setmetatable({ read_checked = function(path)
      if path:match("/%.git$") then return nil, "unreadable" end
      return read(path)
    end }, { __index = bare })
    local report = config.ensure(dir, "claude", blind, permissions)
    check(read(dir .. "/.claude/settings.local.json") == nil and not report.error, "unreadable .git withholds Claude file")
  end)
  fixture(function(dir)
    local _, toml = paths(dir)
    local body = 'description = """\n[mcp_servers.remuda]\n"""\n'
    put(toml, body)
    local report = config.ensure(dir, "codex", bare, permissions)
    check(report.error and read(toml) == body, "multiline TOML string fails closed")
  end)
  print("ok: workdir coordination config offline subset " .. count .. " assertions (no native Codex)")
  return
end

for _, kind in ipairs({ "claude", "codex" }) do
  fixture(function(dir)
    local report = ensure(dir, kind)
    check(#report.written == 3, "both clients initialized before either adapter starts")
    local claude, toml, rules = paths(dir)
    local before = { read(claude), read(toml), read(rules) }
    local settings = remuda.json.decode(before[1])
    check(settings.permissions.allow[1] == "Bash(remuda:*)", "CLI wildcard scoped to Remuda")
    check(settings.permissions.allow[2] == "mcp__remuda__*", "all tools on only Remuda server")
    for _, body in ipairs(before) do
      check(not body:find("fixture-session-capability-not-to-save", 1, true), "capability value never stored")
      check(not body:find(dir, 1, true), "workdir/session identity never serialized")
    end
    report = ensure(dir, kind == "claude" and "codex" or "claude")
    check(#report.written == 0 and #report.unchanged == 3, "shared workdir repeat across adapters is idempotent")
    check(read(claude) == before[1] and read(toml) == before[2] and read(rules) == before[3], "repeat retains exact bytes")
    for _, cmd in ipairs({ { "remuda", "exec", "butler" }, { "remuda", "-e", "return 1" },
      { "remuda", "butler", "send", "member", "hello" }, { "remuda", "mod", "update", "butler" } }) do
      local argv = { "codex", "execpolicy", "check", "--rules", rules, "--" }
      for _, word in ipairs(cmd) do argv[#argv + 1] = word end
      local result = remuda.process.run({ argv = argv, timeout = 5 })
      check(result.code == 0 and remuda.json.decode(result.stdout).decision == "allow", "Remuda CLI scope")
    end
    for _, cmd in ipairs({ { "curl", "https://example.invalid" }, { "remuda-other", "exec" }, { "bash", "-c", "remuda exec butler" } }) do
      local argv = { "codex", "execpolicy", "check", "--rules", rules, "--" }
      for _, word in ipairs(cmd) do argv[#argv + 1] = word end
      local result = remuda.process.run({ argv = argv, timeout = 5 })
      check(result.code == 0 and remuda.json.decode(result.stdout).decision ~= "allow", "unrelated executable not granted")
    end
  end)
end

fixture(function(dir)
  local claude, toml, rules = paths(dir)
  put(claude, '{"permissions":{"allow":["Skill(update-config)"],"deny":["mcp__remuda__butler_send"],"ask":["Bash(remuda exec:*)"]},"custom":{"keep":true}}')
  local custom_toml = 'sandbox_mode = "workspace-write"\napprovals_reviewer = "auto_review"\n[mcp_servers.remuda]\ncommand = "remuda"\n[mcp_servers.remuda.tools.butler_send]\napproval_mode = "prompt"\n'
  put(toml, custom_toml)
  local custom_rules = 'prefix_rule(pattern=["remuda", "exec"], decision="forbidden")\nprefix_rule(pattern=["remuda", "mod"], decision="prompt")\n'
  put(rules, custom_rules)
  ensure(dir, "codex")
  local obj = remuda.json.decode(read(claude))
  check(obj.custom.keep == true and obj.permissions.allow[1] == "Skill(update-config)", "user settings and Skill retained")
  check(obj.permissions.deny[1] == "mcp__remuda__butler_send" and obj.permissions.ask[1] == "Bash(remuda exec:*)", "deny/ask retained")
  check(read(toml):find('[mcp_servers.remuda.tools.butler_send]\napproval_mode = "prompt"', 1, true), "per-tool policy retained")
  check(read(toml):find('approvals_reviewer = "auto_review"', 1, true), "managed review not changed")
  check(read(rules):sub(1, #custom_rules) == custom_rules, "custom rule bytes retained")
  for _, row in ipairs({ { "exec", "forbidden" }, { "mod", "prompt" } }) do
    local result = remuda.process.run({ argv = { "codex", "execpolicy", "check", "--rules", rules, "--", "remuda", row[1], "butler" }, timeout = 5 })
    check(result.code == 0 and remuda.json.decode(result.stdout).decision == row[2], "specific restriction wins broad allow")
  end
  local snapshot = read(toml); check(#ensure(dir, "claude").written == 0 and read(toml) == snapshot, "custom merge repeat stable")
end)

-- MUST 1: a project layer outranks user/ancestor Codex config, so defaults that
-- would override an inherited disable/prompt are withheld.
for _, where in ipairs({ "home", "ancestor" }) do
  fixture(function(dir)
    local work, inherited_fs = dir .. "/a/b", fs
    remuda.mkdir(dir .. "/a"); remuda.mkdir(work)
    local layer = dir .. "/layer"
    put(layer .. "/config.toml", '[mcp_servers.remuda]\nenabled = false\ndefault_tools_approval_mode = "prompt"\n')
    if where == "home" then inherited_fs = setmetatable({ codex_home = layer }, { __index = fs })
    else put(dir .. "/.codex/config.toml", read(layer .. "/config.toml")) end
    local report = config.ensure(work, "codex", inherited_fs, permissions)
    check(not report.error, report.error or "inherited fixture")
    local text = read(work .. "/.codex/config.toml")
    check(text:find('command = "remuda"', 1, true), "non-policy defaults still written")
    check(not text:find("enabled", 1, true) and not text:find("default_tools_approval_mode", 1, true),
      "local default must not override inherited disable/prompt (" .. where .. ")")
  end)
end
fixture(function(dir)
  local blind = setmetatable({ codex_home = false }, { __index = fs })
  config.ensure(dir, "codex", blind, permissions)
  local text = read(dir .. "/.codex/config.toml")
  check(text and not text:find("enabled", 1, true), "unknown inherited layer withholds policy defaults")
end)

-- MUST 2: native Claude lookup is not established for a repo subdirectory or
-- worktree, so no (possibly ignored) Claude file is written there.
fixture(function(dir)
  remuda.mkdir(dir .. "/.git"); remuda.mkdir(dir .. "/sub"); remuda.mkdir(dir .. "/wt")
  put(dir .. "/wt/.git", "gitdir: /elsewhere\n")
  for _, sub in ipairs({ dir, dir .. "/sub", dir .. "/wt" }) do
    local report = config.ensure(sub, "claude", fs, permissions)
    check(not report.error and read(sub .. "/.claude/settings.local.json") == nil,
      "no Claude settings written where native lookup is unverified")
    check(read(sub .. "/.codex/config.toml") ~= nil, "Codex layer still initialized")
    check(report.withheld[1] and report.withheld[1].rule == "claude settings.local.json", "withhold is reported")
  end
end)

-- MUST 1 (sec-wcc2): inherited key spelled with a TOML escape is invisible to a
-- substring scan; Codex's own resolver sees it.
for _, where in ipairs({ "home", "ancestor" }) do
  fixture(function(dir)
    local work, inherited_fs = dir .. "/a/b", fs
    remuda.mkdir(dir .. "/a"); remuda.mkdir(work)
    local body = '["mcp_servers"."\\u0072emuda"]\ncommand = "x"\nenabled = false\ndefault_tools_approval_mode = "prompt"\n'
    check(not body:find("remuda", 1, true), "fixture hides the literal word")
    put(dir .. "/layer/config.toml", body)
    if where == "home" then inherited_fs = setmetatable({ codex_home = dir .. "/layer" }, { __index = fs })
    else put(dir .. "/.codex/config.toml", body) end
    config.ensure(work, "codex", inherited_fs, permissions)
    local text = read(work .. "/.codex/config.toml")
    check(text and text:find('command = "remuda"', 1, true), "non-policy defaults written")
    check(not text:find("enabled", 1, true) and not text:find("default_tools_approval_mode", 1, true),
      "escaped inherited key still withholds policy defaults (" .. where .. ")")
  end)
end
-- B: a Codex-less machine must not block Claude (or fresh literal Codex) init.
fixture(function(dir)
  local bare = setmetatable({ native_servers = function() return nil end,
    validate = config.validator(function() error("must not execute") end, function() return true end,
      fs.write, os.remove, function() return false end) }, { __index = fs })
  local report = config.ensure(dir, "claude", bare, permissions)
  local claude = paths(dir)
  check(not report.error and read(claude) ~= nil, "Claude initializes without Codex or native resolver")
  local text = read(dir .. "/.codex/config.toml")
  check(text and not text:find("enabled", 1, true), "policy fields withheld without a resolver")
end)
-- unreadable own .git is treated as possibly inside a repository
fixture(function(dir)
  local blind = setmetatable({ read_checked = function(path)
    if path:match("/%.git$") then return nil, "unreadable" end
    return read(path)
  end }, { __index = fs })
  local report = config.ensure(dir, "claude", blind, permissions)
  check(read(dir .. "/.claude/settings.local.json") == nil and not report.error, "unreadable .git withholds Claude file")
end)
-- S4: multiline strings are an unsupported shape: refused, file untouched.
fixture(function(dir)
  local _, toml = paths(dir)
  local body = 'description = """\n[mcp_servers.remuda]\n"""\n'
  put(toml, body)
  local report = config.ensure(dir, "codex", fs, permissions)
  check(report.error and read(toml) == body, "multiline TOML string fails closed")
end)
-- S3: a failed later write leaves earlier files and reports; no rollback.
fixture(function(dir)
  local calls = 0
  local failing = setmetatable({ write = function(path, text)
    calls = calls + 1
    if path:find("remuda.rules", 1, true) then return nil, "disk full" end
    return fs.write(path, text)
  end }, { __index = fs })
  local report = config.ensure(dir, "codex", failing, permissions)
  check(report.error and #report.written == 2 and read(dir .. "/.codex/config.toml") ~= nil
    and read(dir .. "/.codex/rules/remuda.rules") == nil, "partial write reported; no half-written file")
end)

-- SHOULD-B: independence extends to checks, reads and links, not just validation.
fixture(function(dir)
  local _, toml = paths(dir)
  local split = setmetatable({ read_checked = function(path)
    if path:find("/.codex/", 1, true) then return nil, "unreadable" end
    return read(path)
  end }, { __index = fs })
  local report = config.ensure(dir, "claude", split, permissions)
  check(not report.error and read(dir .. "/.claude/settings.local.json") ~= nil, "unreadable Codex file does not block Claude")
  check(report.blocked.codex ~= nil, "blocked Codex client is reported")
end)
fixture(function(dir)
  local linked = setmetatable({ is_symlink = function(path)
    if path:find("/.codex", 1, true) then return true end
    return fs.is_symlink(path)
  end }, { __index = fs })
  local report = config.ensure(dir, "claude", linked, permissions)
  check(not report.error and read(dir .. "/.claude/settings.local.json") ~= nil, "linked Codex dir does not block Claude")
  local own = config.ensure(dir, "codex", linked, permissions)
  check(own.error ~= nil, "launching Codex sees its own blocked reason")
end)
fixture(function(dir)
  -- a cwd that itself contains '/.claude' must not confuse client ownership
  local odd = dir .. "/.claude-parent"
  remuda.mkdir(odd)
  local report = config.ensure(odd, "codex", fs, permissions)
  check(not report.error and read(odd .. "/.codex/config.toml") ~= nil, "odd cwd name initializes Codex")
end)
fixture(function(dir)
  local rejecting = setmetatable({ validate = function(format) return format ~= "toml" end }, { __index = fs })
  local report = config.ensure(dir, "codex", rejecting, permissions)
  check(report.error and report.blocked.codex and read(dir .. "/.claude/settings.local.json") ~= nil,
    "validator rejection reports the launching client's error and still writes Claude")
end)

fixture(function(dir)
  local claude = paths(dir)
  local blocked = '{"permissions":{"deny":["mcp__remuda__*"],"ask":["Bash(remuda:*)"]}}'
  put(claude, blocked)
  local report = ensure(dir, "claude")
  check(#report.withheld == 2 and read(claude) == blocked, "exact wildcard deny/ask withholds generated Claude grants")
end)

for _, item in ipairs({
  { 1, '{"permissions":' }, { 1, '{"permissions":{"allow":[123]}}' },
  { 2, 'sandbox_mode = [' }, { 3, 'prefix_rule(pattern=[' },
  { 3, '# BEGIN Butler Remuda CLI v1\nprefix_rule(pattern=["curl"], decision="allow")\n# END Butler Remuda CLI v1\n' },
}) do
  fixture(function(dir)
    local files = { paths(dir) }; put(files[item[1]], item[2])
    local own = item[1] == 1 and "claude" or "codex"
    local report = config.ensure(dir, own, fs, permissions)
    check(report.error ~= nil and report.blocked[own], "malformed/modified file blocks its own client")
    check(read(files[item[1]]) == item[2], "malformed original untouched")
    local mine = item[1] == 1 and { 1 } or { 2, 3 }
    for _, i in ipairs(mine) do if i ~= item[1] then check(read(files[i]) == nil, "own client not partially created") end end
    -- B: the other client still initializes (a broken/absent client must not block it)
    local others = item[1] == 1 and { 2, 3 } or { 1 }
    for _, i in ipairs(others) do check(read(files[i]) ~= nil, "independent client still initialized") end
  end)
end

for _, header in ipairs({ '[mcp_servers."remuda"]', "[ 'mcp_servers' . 'remuda' ]" }) do
  fixture(function(dir)
    local _, toml = paths(dir)
    put(toml, header .. '\n"command" = "remuda"\n')
    ensure(dir, "codex")
    check(read(toml):find(header, 1, true) ~= nil, "simple quoted table is preserved")
    check(#ensure(dir, "claude").written == 0, "quoted table merge is idempotent")
  end)
end

fixture(function(dir)
  local no_validator = setmetatable({ validate = config.validator(function() error("must not execute") end,
    function() return true end, fs.write, os.remove, function() return false end) }, { __index = fs })
  local report = config.ensure(dir, "claude", no_validator, permissions)
  check(not report.error and #report.written == 3, "literal fresh defaults do not require installed Codex")
  check(#config.ensure(dir, "codex", no_validator, permissions).written == 0, "literal defaults repeat without Codex")
end)

fixture(function(dir)
  local unreadable = setmetatable({ read_checked = function() return nil, "unreadable" end }, { __index = fs })
  local report = config.ensure(dir, "codex", unreadable, permissions)
  check(report.error and #report.written == 0, "unreadable is not mistaken for missing")
  local linked = setmetatable({ is_symlink = function() return true end }, { __index = fs })
  report = config.ensure(dir, "codex", linked, permissions)
  check(report.error and #report.written == 0, "symlink/cannot-check fails closed")
end)
fixture(function(dir)
  local _, toml = paths(dir)
  local legacy = '[mcp_servers.remuda.env]\nREMUDA_SESSION_CAPABILITY = "fixture-session-capability-not-to-save"\n'
  put(toml, legacy)
  local report = config.ensure(dir, "codex", fs, permissions)
  check(report.error and report.blocked.codex and read(toml) == legacy, "legacy capability is neither copied nor rewritten")
end)

do
  local removed = false
  local validate = config.validator(function() error("must not run") end,
    function() return false end, function() error("must not write") end,
    function() removed = true end, function() return true end)
  check(not validate("toml", "invalid") and not removed, "failed exclusive temp creation never removes an unowned path")
end
fixture(function(dir)
  local report = config.ensure(dir, "monocle", fs, permissions)
  local claude, toml, rules = paths(dir)
  check(report.skipped and read(claude) == nil and read(toml) == nil and read(rules) == nil,
    "other adapters retain their existing policy")
end)
print("ok: workdir coordination config " .. count .. " assertions (native config/rules parsers, both adapters)")
