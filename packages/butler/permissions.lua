-- The permission rule Butler grants its own root session: one allow rule for
-- the `remuda butler` CLI, added to the root session's
-- `.claude/settings.local.json`. Members, leads and Codex get nothing here.
local permissions = {}

-- Only `Bash(remuda butler[ VERB...]:*)`: a rule never reaches past this CLI.
function permissions.valid_rule(rule)
  local rest = type(rule) == "string" and rule:match("^Bash%(remuda butler([ %w%-]*):%*%)$")
  while rest and rest ~= "" do rest = rest:match("^ %w[%w%-]*(.*)$") end
  return rest == ""
end

-- The role is a constant at the launch call site, never a name or the environment.
function permissions.builtin(ctx)
  return type(ctx) == "table" and ctx.role == "root" and { "Bash(remuda butler:*)" } or {}
end

-- Joins the `butler.permission` rows for the root Butler. Returns the rules
-- and what was dropped (`{ id, rule }`); a bad row loses its rules only.
function permissions.rules(ctx, rows)
  local rules, seen, dropped = {}, {}, {}
  if type(ctx) ~= "table" or ctx.role ~= "root" then return rules, dropped end
  for _, row in ipairs(rows or {}) do
    local render = type(row.entry) == "table" and row.entry.rules or function() return {} end
    local ok, list = pcall(render, { role = "root", kind = "claude" })
    if not ok or type(list) ~= "table" then list = { ok and "(not a list)" or "(failed)" } end
    for _, rule in ipairs(list) do
      if not permissions.valid_rule(rule) then dropped[#dropped + 1] = { id = row.id, rule = rule }
      elseif not seen[rule] then seen[rule] = true; rules[#rules + 1] = rule end
    end
  end
  return rules, dropped
end

-- merge(text or nil, rules, json) -> new text or nil, report. nil text means
-- write nothing: the rule is present or withheld (the user's deny or ask
-- wins), or the file is not ours to edit (`report.error`). `json` is
-- remuda.json; its encoder sorts the keys, so the one write loses key order.
function permissions.merge(text, rules, json)
  local report = { added = {}, present = {}, withheld = {} }
  local array = getmetatable(json.array({}))
  local function is(value, want_array)
    return type(value) == "table" and value ~= json.null and (getmetatable(value) == array) == want_array
  end
  local function holds(values, rule)
    for _, value in ipairs(values or {}) do if value == rule then return true end end
  end
  local ok, settings = pcall(json.decode, text or "{}")
  if not ok or not is(settings, false) then report.error = "not valid JSON"; return nil, report end
  local perms = settings.permissions
  if perms == nil then perms = {}; settings.permissions = perms end
  if is(perms, false) and perms.allow == nil then perms.allow = json.array({}) end
  if not is(perms, false) or not is(perms.allow, true) or not is(perms.deny or perms.allow, true)
      or not is(perms.ask or perms.allow, true) then
    report.error = "wrong type"
    return nil, report
  end
  for _, rule in ipairs(rules) do
    local blocked = (holds(perms.deny, rule) and "deny") or (holds(perms.ask, rule) and "ask")
    if blocked then report.withheld[#report.withheld + 1] = { rule = rule, list = blocked }
    elseif holds(perms.allow, rule) then report.present[#report.present + 1] = rule
    else perms.allow[#perms.allow + 1] = rule; report.added[#report.added + 1] = rule end
  end
  if #report.added == 0 then return nil, report end
  return json.encode(settings, { pretty = true }) .. "\n", report
end

-- The file side. `fs`: read(path), is_symlink(path) (nil when it cannot
-- tell), mkdir(path), write(path, text, private) (atomic), json. Fails closed
-- and never raises: a failure is reported, and the launch goes on.
function permissions.ensure(path, rules, fs)
  local report = { added = {}, present = {}, withheld = {} }
  local ok, err = pcall(function()
    if #rules == 0 then return end
    local dir = path:match("^(.*)/[^/]+$")
    -- write_atomic would replace a link with a plain file, and we would read through it.
    for _, target in ipairs({ dir, path }) do
      local linked = fs.is_symlink(target)
      if linked ~= false then report.error = linked and "is a symlink" or "cannot check for a symlink"; return end
    end
    local existing = fs.read(path)
    local text
    text, report = permissions.merge(existing, rules, fs.json)
    if not text then return end
    if existing == nil then fs.mkdir(dir) end
    local wrote, why = fs.write(path, text, true)
    if not wrote then error(why or "write failed", 0) end
  end)
  if not ok then report = { added = {}, present = {}, withheld = {}, error = tostring(err) } end
  report.path = path
  return report
end

-- Writes only when the text differs, so a caller on a timer leaves the file
-- and its modification time alone (issue 236).
function permissions.write_if_changed(path, text, fs, private)
  if fs.read(path) == text then return "unchanged" end
  local wrote, why = fs.write(path, text, private)
  if not wrote then return nil, tostring(why or "write failed") end
  return "written"
end

-- An agent caller may hand the mod only a file inside its own working
-- directory; a caller outside any session (a person at a terminal) is not
-- restricted, and anything unknown is refused. Returns the path to open, or
-- nil and the refusal. `caller` is remuda.caller(), `cwd_of(session)` the
-- recorded launch directory, `realpath(path)` resolves symlinks and `..`.
-- ponytail: a link swapped between this check and the open is not closed;
-- upgrade to a core open-beneath helper when it exists.
function permissions.file_for_caller(path, caller, cwd_of, realpath, flag, pipe)
  if type(caller) == "table" and caller.kind == "outside" then return path end
  local function one_line(value) return (tostring(value):gsub("[\r\n]+", " "):gsub("%c", "?")) end
  local what = "refused: " .. flag .. one_line(path)
  local cwd = type(caller) == "table" and caller.kind == "session" and type(caller.session) == "string"
    and cwd_of(caller.session)
  if type(cwd) ~= "string" or cwd:sub(1, 1) ~= "/" then
    return nil, what .. ": cannot identify the calling session's working directory"
      .. "\nNext: run this from a Butler session, or from your own terminal"
  end
  local ok, root, real = pcall(function()
    local resolved = realpath(cwd)
    return resolved, resolved and realpath(path)
  end)
  if not ok or not root or not real then
    return nil, what .. " cannot be resolved (a missing file, or realpath is unavailable)"
      .. "\nNext: check that the file exists inside " .. one_line(cwd)
  end
  -- The trailing slash keeps a sibling like CWDx, and the directory itself, outside.
  if real:sub(1, #root + 1) == root .. "/" then return real end
  return nil, what .. " is outside this session's working directory " .. one_line(cwd)
    .. "\nNext: copy the file into " .. one_line(cwd) .. " and pass that path"
    .. (pipe and ", or pipe the text: cat FILE | remuda butler send NAME -" or "")
end

if type(remuda) == "table" then remuda._butler_permissions = permissions end
return permissions
