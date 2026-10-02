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

-- File arguments. An agent caller may have the mod read or write only inside
-- its own working directory; a caller outside any session (a person at a
-- terminal) is not restricted, and anything unknown is refused. `caller` is
-- remuda.caller(), `cwd_of(session)` the recorded launch directory,
-- `realpath(path)` resolves symlinks and `..`.
-- ponytail: a link swapped between these checks and the open is not closed;
-- upgrade to a core open-beneath helper when it exists.
local function one_line(value) return (tostring(value):gsub("[\r\n]+", " "):gsub("%c", "?")) end
local UNKNOWN = ": cannot identify the calling session's working directory"
  .. "\nNext: run this from a Butler session, or from your own terminal"
-- Windows opens a device for these base names in any directory, with or
-- without an extension: what /dev is on a posix system.
local function windows_device(name)
  -- COM and LPT are reserved with a superscript 1, 2 or 3 too (UTF-8 here).
  local stem = name:lower():match("^[^%.]*"):gsub(" +$", ""):gsub("\194[\185\178\179]$", "1")
  return stem == "con" or stem == "prn" or stem == "aux" or stem == "nul" or stem == "conin$" or stem == "conout$"
    or stem:match("^com%d$") ~= nil or stem:match("^lpt%d$") ~= nil
end
local function windows_key(path)
  local text = path:gsub("/", "\\")
  -- The forms a resolver returns: \\?\C:\dir and \\?\UNC\server\share\dir.
  local verbatim = text:match("^\\\\%?\\(.*)$")
  if verbatim then
    local unc = verbatim:match("^[Uu][Nn][Cc]\\(.*)$")
    text = unc and ("\\\\" .. unc) or verbatim
    if not unc and not text:match("^%a:\\") then return nil, "device" end
  end
  -- \\.\pipe\name, \\.\NUL: the device namespace, never a file.
  if text:match("^\\\\[%.%?]\\") then return nil, "device" end
  local head, rest = text:match("^(%a:)\\(.*)$")
  if not head then
    local server, share, tail = text:match("^\\\\([^\\]+)\\([^\\]+)(.*)$")
    if server then head, rest = "//" .. server .. "/" .. share, tail
    -- Not absolute (C:name, sub\name, name): no key, but its names are still checked.
    else rest = text:gsub("^%a:", "") end
  end
  local parts, why = { head and head:lower() }, nil
  for part in rest:gmatch("[^\\]+") do
    if part:find(":", 1, true) or windows_device(part) then return nil, "device" end
    -- `.`, `..`, and any name Windows would shorten (a trailing dot or space).
    if part:find("[%. ]$") then why = "unresolved" end
    parts[#parts + 1] = part:lower()
  end
  if not head then return nil end
  if why then return nil, why end
  return table.concat(parts, "/")
end
-- The form two paths are compared in, or nil when `path` is not an absolute
-- file path on `platform` ("windows"; anything else is posix). Windows: a
-- drive root or UNC with either slash, compared without regard to case. The
-- second value says why not: "device" (a device name or an alternate stream,
-- named for a path that is not absolute too),
-- "unresolved" (a `.` or `..` left in place, on posix too: the prefix test
-- would lie about such a path).
-- ponytail: lower() folds ASCII only, so a non-ASCII case difference is
-- refused; upgrade to a core case-folding word if that is ever met.
function permissions.path_key(path, platform)
  if type(path) ~= "string" then return nil end
  if platform == "windows" then return windows_key(path) end
  if path:sub(1, 1) ~= "/" then return nil end
  if ("/" .. path .. "/"):find("/%.%.?/") then return nil, "unresolved" end
  return path
end
local path_key = permissions.path_key

-- The caller's recorded working directory and its resolved form (nil: cannot resolve).
local function session_cwd(caller, cwd_of, realpath, platform)
  local cwd = type(caller) == "table" and caller.kind == "session" and type(caller.session) == "string"
    and cwd_of(caller.session)
  -- A recorded `..` is the resolver's to settle: the root is its answer.
  local key, why = path_key(cwd, platform)
  if not key and why ~= "unresolved" then return nil end
  local ok, root = pcall(realpath, cwd)
  return cwd, ok and root or nil
end
-- Both are keys. The trailing slash keeps a sibling like CWDx outside.
local function inside(real, root) return real ~= nil and root ~= nil and real:sub(1, #root + 1) == root .. "/" end
local DEVICE = " names a device or a stream, not a file"
local RELATIVE = " is not an absolute path"

-- A file to READ. Returns the path to open, or nil and the refusal.
function permissions.file_for_caller(path, caller, cwd_of, realpath, flag, pipe, platform)
  local what = "refused: " .. flag .. one_line(path)
  -- A device is refused by its name, before anything opens or resolves it, and
  -- for a terminal caller too: opening a pipe blocks the daemon.
  local key, why = path_key(path, platform)
  if type(caller) == "table" and caller.kind == "outside" then
    if why == "device" then return nil, what .. DEVICE .. "\nNext: pass a regular file" end
    return path
  end
  local cwd, root = session_cwd(caller, cwd_of, realpath, platform)
  if not cwd then return nil, what .. UNKNOWN end
  -- A relative path would resolve against the daemon's directory, not the caller's.
  if not key and not why then
    return nil, what .. RELATIVE .. "\nNext: pass the full path of a file inside " .. one_line(cwd)
  end
  key = nil
  local ok, real = true, nil
  if why ~= "device" then ok, real = pcall(realpath, path) end
  if ok and real then key, why = path_key(real, platform) end
  if why == "device" then return nil, what .. DEVICE .. "\nNext: pass a regular file inside " .. one_line(cwd) end
  if not root or not ok or not real or why == "unresolved" then
    return nil, what .. " cannot be resolved (a missing file, or realpath is unavailable)"
      .. "\nNext: check that the file exists inside " .. one_line(cwd)
  end
  if inside(key, path_key(root, platform)) then return real end
  return nil, what .. " is outside this session's working directory " .. one_line(cwd)
    .. "\nNext: copy the file into " .. one_line(cwd) .. " and pass that path"
    .. (pipe and ", or pipe the text: cat FILE | remuda butler send NAME -" or "")
end

-- A file to WRITE (matrix download). `path` is -o PATH or nil; `name` is the
-- default file name. The parent directory is resolved (the file need not
-- exist) and must be the working directory or inside it; an existing link at
-- the target is refused. Returns the path to write (nil for an outside caller
-- without -o: the old default), or nil and the refusal.
function permissions.output_for_caller(path, name, caller, cwd_of, realpath, is_symlink, platform)
  local what = "refused: " .. (path and ("-o " .. one_line(path)) or "download")
  if type(caller) == "table" and caller.kind == "outside" then
    -- Not confined, but a pipe opened for writing blocks the daemon as well.
    local given, why = path_key(path, platform)
    if why == "device" then return nil, what .. DEVICE .. "\nNext: pass -o with a regular file path" end
    -- A relative path would land in the daemon's directory, not the caller's.
    if path ~= nil and not given and not why then return nil, what .. RELATIVE .. "\nNext: pass -o with the full path" end
    return path
  end
  local cwd, root = session_cwd(caller, cwd_of, realpath, platform)
  if not cwd then return nil, what .. UNKNOWN end
  local function refuse(why) return nil, what .. why .. "\nNext: pass -o with a path inside " .. one_line(cwd) end
  local windows = platform == "windows"
  local separator = windows and "\\" or "/"
  local parent, base = root, name
  if path then
    local given, why = path_key(path, platform)
    if why == "device" then return refuse(DEVICE) end
    if not given and not why then return refuse(RELATIVE) end
    local dir
    dir, base = path:match(windows and "^(.*)[/\\]([^/\\]*)$" or "^(.*)/([^/]*)$")
    if not dir or base == "" or base == "." or base == ".." then return refuse(" has no file name") end
    -- `C:` alone is the current directory of that drive, not its root.
    if dir == "" or (windows and dir:match("^%a:$")) then dir = dir .. separator end
    local ok, real = pcall(realpath, dir)
    parent = ok and real or nil
  end
  if not root or not parent or type(base) ~= "string" then
    return refuse(" cannot be resolved (a missing directory, or realpath is unavailable)")
  end
  -- A default name comes from the sender: on Windows it must be one plain name.
  if windows and base:find("[/\\]") then return refuse(" has no file name") end
  if windows and (base:find(":", 1, true) or windows_device(base)) then return refuse(DEVICE) end
  if windows and base:find("[%. ]$") then return refuse(" ends in a dot or a space, which Windows drops") end
  local parent_key, root_key = path_key(parent, platform), path_key(root, platform)
  if not parent_key or not root_key or (parent_key ~= root_key and not inside(parent_key, root_key)) then
    return refuse(" is outside this session's working directory " .. one_line(cwd))
  end
  local target = (parent:sub(-1) == separator and parent or parent .. separator) .. base
  local linked = is_symlink(target)
  if linked ~= false then return refuse(linked and " is a symlink" or " cannot be checked for a symlink") end
  return target
end

-- The realpath and is_symlink helpers the checks above are handed. Both answer
-- nil when they cannot tell, and every nil is a refusal. `core_fs` is remuda.fs;
-- `run(argv)` is remuda.process.run for a core without fs.realpath, where
-- posix asks `realpath` and `test -L` and Windows has no answer.
function permissions.fs_helpers(core_fs, run, platform)
  if type(core_fs) == "table" and type(core_fs.realpath) == "function" and type(core_fs.is_symlink) == "function" then
    return function(path)
      local ok, real = pcall(core_fs.realpath, path)
      return ok and type(real) == "string" and real ~= "" and real or nil
    end, function(path)
      local ok, linked, why = pcall(core_fs.is_symlink, path)
      if ok and type(linked) == "boolean" then return linked end
      -- Nothing there, so no link there: a new file may be written. Any other nil cannot tell.
      if ok and linked == nil and why == "not_found" then return false end
      return nil
    end
  end
  local function shell(argv)
    if platform == "windows" then return nil end
    local ok, result = pcall(run, argv)
    return ok and type(result) == "table" and not result.timed_out and result or nil
  end
  return function(path)
    local result = shell({ "realpath", path })
    local real = result and result.code == 0 and type(result.stdout) == "string" and result.stdout:gsub("\n$", "")
    return real and real ~= "" and real or nil
  end, function(path)
    local result = shell({ "test", "-L", path })
    if result and (result.code == 0 or result.code == 1) then return result.code == 0 end
    return nil
  end
end

if type(remuda) == "table" then remuda._butler_permissions = permissions end
return permissions
