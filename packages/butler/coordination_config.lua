-- Workdir-local client defaults. Session capabilities and identity belong only
-- to launch overrides; this module never receives them.
local config = {}
local CLAUDE_RULES = { "Bash(remuda:*)", "mcp__remuda__*" }
local RULE_BLOCK = '# BEGIN Butler Remuda CLI v1\n'
  .. 'prefix_rule(pattern=["remuda"], decision="allow")\n'
  .. '# END Butler Remuda CLI v1\n'
local MCP_FIELDS = {
  { "command", '"remuda"' }, { "args", '["mcp"]' },
  { "env_vars", '["REMUDA_SESSION_CAPABILITY", "REMUDA_RUNTIME_DIR"]' },
  { "enabled", 'true' }, { "default_tools_approval_mode", '"approve"' },
}
local FRESH_TOML = "[mcp_servers.remuda]\n# Butler Remuda MCP defaults v1 (launch overrides own identity)\n"
for _, field in ipairs(MCP_FIELDS) do FRESH_TOML = FRESH_TOML .. field[1] .. " = " .. field[2] .. "\n" end

-- Fields a project layer would use to override an inherited (user/ancestor)
-- Codex restriction; withheld when an inherited layer mentions Remuda or
-- cannot be established.
local POLICY_FIELDS = { enabled = true, default_tools_approval_mode = true }

function config.merge_toml(text, validate, withhold_policy)
  text = text or ""
  -- Legacy inline capability assignments must not be copied to validator
  -- fixtures or rewritten. Session capabilities are launcher-owned.
  if text:match("REMUDA_SESSION_CAPABILITY[\"']?%s*=") then
    return nil, "existing capability assignment requires owner cleanup; unchanged"
  end
  if text ~= "" and not validate("toml", text) then return nil, "invalid TOML or Codex configuration; unchanged" end
  -- Only canonical sections are edited. Other TOML forms stay untouched and
  -- a native parser validates the proposed merge, catching aliases/inline keys.
  local lines, section, start, finish, keys = {}, nil, nil, nil, {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    local header = line:match("^%s*%[([^%[%]]+)%]%s*#?.*$")
    if header then
      header = header:gsub('"([%w_%-]+)"', "%1"):gsub("'([%w_%-]+)'", "%1")
        :gsub("%s*%.%s*", "."):gsub("^%s+", ""):gsub("%s+$", "")
      if section == "mcp_servers.remuda" then finish = #lines - 1 end
      section = header
      if section == "mcp_servers.remuda" then start = #lines end
    elseif section == "mcp_servers.remuda" then
      local key = line:match("^%s*[\"']?([%w_]+)[\"']?%s*=")
      if key then keys[key] = true end
    end
  end
  if section == "mcp_servers.remuda" then finish = #lines end
  -- Keep all original bytes; insert missing defaults at the end of its section.
  local additions = {}
  for _, field in ipairs(MCP_FIELDS) do
    if not keys[field[1]] and not (withhold_policy and POLICY_FIELDS[field[1]]) then additions[#additions + 1] = field[1] .. " = " .. field[2] .. "\n" end
  end
  if #additions == 0 then return nil end
  local defaults = "# Butler Remuda MCP defaults v1 (launch overrides own identity)\n" .. table.concat(additions)
  local proposed
  if not start then
    proposed = text .. (text:sub(-1) == "\n" and "\n" or "\n\n") .. "[mcp_servers.remuda]\n" .. defaults
  else
    local offset = 0
    for i = 1, math.min(finish, #lines - 1) do offset = offset + #lines[i] + 1 end
    offset = math.min(offset, #text)
    proposed = text:sub(1, offset) .. (text:sub(offset, offset) == "\n" and "" or "\n")
      .. defaults .. text:sub(offset + 1)
  end
  if not validate("toml", proposed) then
    return nil, "cannot safely merge TOML (noncanonical/conflicting Remuda settings or unavailable validator); unchanged"
  end
  return proposed
end

function config.merge_rules(text, validate)
  text = text or ""
  if text ~= "" and not validate("rules", text) then return nil, "invalid Codex rules; unchanged" end
  if text:find("# BEGIN Butler Remuda CLI", 1, true) or text:find("# END Butler Remuda CLI", 1, true) then
    local _, count = text:gsub(RULE_BLOCK:gsub("([^%w])", "%%%1"), "")
    local _, begins = text:gsub("# BEGIN Butler Remuda CLI", "")
    local _, ends = text:gsub("# END Butler Remuda CLI", "")
    if count ~= 1 or begins ~= 1 or ends ~= 1 then return nil, "modified/duplicate Butler rules block; unchanged" end
    -- Never replace a custom block or remove unrelated deny/prompt rules.
    return nil
  end
  local proposed = text .. (text ~= "" and text:sub(-1) ~= "\n" and "\n" or "") .. RULE_BLOCK
  if not validate("rules", proposed) then return nil, "cannot validate generated Codex rules; unchanged" end
  return proposed
end

-- true when an inherited Codex layer (CODEX_HOME or an ancestor .codex) may
-- already restrict the Remuda server, or that cannot be established.
function config.inherited_restricts(cwd, fs)
  if not fs.codex_home then return true end
  local files = { fs.codex_home .. "/config.toml" }
  local dir = cwd
  while true do
    dir = dir:match("^(.*)/[^/]*$")
    if not dir then break end
    files[#files + 1] = dir .. "/.codex/config.toml"
  end
  for _, path in ipairs(files) do
    local text, why = fs.read_checked(path)
    if why or (text and text:find("remuda", 1, true)) then return true end
  end
  return false
end

function config.ensure(cwd, kind, fs, permissions)
  local report = { cwd = cwd, kind = kind, written = {}, unchanged = {}, withheld = {} }
  if kind ~= "claude" and kind ~= "codex" then report.skipped = true; return report end
  local ok, err = pcall(function()
    local dirs = { cwd, cwd .. "/.claude", cwd .. "/.codex", cwd .. "/.codex/rules" }
    for _, dir in ipairs(dirs) do
      if fs.is_symlink(dir) ~= false then error("configuration directory is a symlink or cannot be checked", 0) end
    end
    local paths = { cwd .. "/.claude/settings.local.json", cwd .. "/.codex/config.toml",
      cwd .. "/.codex/rules/remuda.rules" }
    local before, after = {}, {}
    for i, path in ipairs(paths) do
      if fs.is_symlink(path) ~= false then error("configuration file is a symlink or cannot be checked", 0) end
      local why
      before[i], why = fs.read_checked(path)
      if why then error("cannot read existing configuration; unchanged", 0) end
    end
    local claude
    after[1], claude = permissions.merge(before[1], CLAUDE_RULES, fs.json)
    if claude.error then error("invalid Claude settings: " .. claude.error .. "; unchanged", 0) end
    report.withheld = claude.withheld
    local inherited = config.inherited_restricts(cwd, fs)
    if inherited then
      report.withheld[#report.withheld + 1] = { rule = "codex enabled/default_tools_approval_mode",
        list = "inherited Codex configuration may restrict Remuda" }
    end
    for _, list in ipairs({ "allow", "deny", "ask" }) do
      local decoded = fs.json.decode(before[1] or "{}")
      for _, value in ipairs(decoded.permissions and decoded.permissions[list] or {}) do
        if type(value) ~= "string" then error("invalid Claude permission entry; unchanged", 0) end
      end
    end
    local why
    after[2], why = config.merge_toml(before[2], fs.validate, inherited)
    if why then error(why, 0) end
    after[3], why = config.merge_rules(before[3], fs.validate)
    if why then error(why, 0) end
    -- Plan/validate every file before any target write, then check for a changed
    -- workdir snapshot. Daemon launch callbacks serialize shared-workdir merges.
    for i, path in ipairs(paths) do
      local current, read_error = fs.read_checked(path)
      if read_error or current ~= before[i] then error("configuration changed during initialization; unchanged", 0) end
    end
    for _, dir in ipairs({ cwd .. "/.claude", cwd .. "/.codex", cwd .. "/.codex/rules" }) do fs.mkdir(dir) end
    for i, path in ipairs(paths) do
      if after[i] then
        local wrote = fs.write(path, after[i], true)
        if not wrote then error("configuration atomic write failed (earlier files may have been written)", 0) end
        report.written[#report.written + 1] = path
      else report.unchanged[#report.unchanged + 1] = path end
    end
  end)
  if not ok then report.error = tostring(err) end
  return report
end

-- Native Codex validation is read-only and offline. Neither command starts an
-- MCP server. Output can contain user auth fields, so it is never forwarded.
function config.validator(run, mkdir, write, remove, available)
  return function(format, text)
    if not available() then
      -- These literal generated documents are valid without a native parser.
      -- Existing/custom documents require Codex; never guess at their syntax.
      return (format == "toml" and text:gsub("^%s+", "") == FRESH_TOML)
        or (format == "rules" and text == RULE_BLOCK)
    end
    local dir = os.tmpname()
    os.remove(dir)
    local file = dir .. (format == "toml" and "/config.toml" or "/check.rules")
    local owned = false
    local ok, result = pcall(function()
      owned = mkdir(dir) == true
      assert(owned, "cannot exclusively create validation directory")
      assert(write(file, text, true))
      local argv = format == "toml" and { "codex", "mcp", "list", "--json" }
        or { "codex", "execpolicy", "check", "--rules", file, "--", "remuda", "--version" }
      local answer = run({ argv = argv, timeout = 5, cwd = dir, env = { CODEX_HOME = dir } })
      return answer and answer.code == 0 and not answer.timed_out
    end)
    -- Codex may create auxiliary paths in its isolated temporary home. The
    -- caller owns recursive cleanup of exactly this freshly allocated dir.
    if owned then
      pcall(remove, file)
      pcall(remove, dir, true)
    end
    return ok and result == true
  end
end

remuda._butler_coordination_config = config
return config
