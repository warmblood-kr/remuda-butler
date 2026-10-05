-- Guard slice 0: observe and audit. `remuda butler guard` is the target of the
-- Claude Code PreToolUse and PermissionRequest hooks. It classifies the action
-- with a deterministic classifier, appends one JSON line to the audit log, and
-- never returns a decision: it changes nothing an agent can do. It fails open.
-- The switch (`guard on|off|status`) is a marker file beside the log; off by default.
-- This is a record, not a boundary: a same-user agent can bypass or edit it.
local M = {}

local MAX_INPUT = 64 * 1024 -- larger payloads use only bounded structured deny fields
local REDACT_PREFIX = 2048 -- redaction reads only this many bytes: its patterns are quadratic on long word runs
local SUMMARY_CAP = 200
local LOG_CAP = 1024 * 1024 -- the log rotates to LOG.1 past this size
-- A rotated LOG.1 moves to LOG.<UTC stamp> on the next rotation; only those dated
-- archives older than this many days are deleted, and only at rotation time.
M.RETENTION_DAYS = 90
local SCRIPT_HEAD = 120

-- Where the switch and the log live; remuda._butler_guard_dir lets a test redirect both.
local function dir()
  if type(remuda._butler_guard_dir) == "string" then return remuda._butler_guard_dir end
  local paths = remuda._butler_paths
  return paths and paths.data_home and (paths.data_home .. "/remuda/butler") or nil
end
M.dir = dir
function M.log_path() local d = dir(); return d and (d .. "/guard-audit.jsonl") end
local function switch_path() local d = dir(); return d and (d .. "/guard-observe") end

function M.enabled()
  local path = switch_path()
  local f = path and io.open(path, "r")
  if not f then return false end
  local text = f:read("*l")
  f:close()
  return text == "on"
end

function M.set(on)
  local path = switch_path()
  if not path then return nil, "Butler data directory is unknown" end
  pcall(remuda.mkdir, dir())
  return remuda.fs.write_atomic(path, on and "on\n" or "off\n", { private = true })
end

-- The approvals switch (`guard approvals on|off|status`) is a second marker file;
-- approval routing runs only while both switches are on.
local function approvals_path() local d = dir(); return d and (d .. "/guard-approvals") or nil end

function M.approvals_enabled()
  local path = approvals_path()
  local f = path and io.open(path, "r")
  if not f then return false end
  local text = f:read("*l")
  f:close()
  return text == "on"
end

function M.set_approvals(on)
  local path = approvals_path()
  if not path then return nil, "Butler data directory is unknown" end
  pcall(remuda.mkdir, dir())
  return remuda.fs.write_atomic(path, on and "on\n" or "off\n", { private = true })
end

-- Denials are a separate, opt-in switch from both audit and approvals.
local function deny_path() local d = dir(); return d and (d .. "/guard-deny") or nil end
function M.deny_enabled()
  local path = deny_path()
  local f = path and io.open(path, "r")
  if not f then return false end
  local text = f:read("*l")
  f:close()
  return text == "on"
end
function M.set_deny(on)
  local path = deny_path()
  if not path then return nil, "Butler data directory is unknown" end
  pcall(remuda.mkdir, dir())
  return remuda.fs.write_atomic(path, on and "on\n" or "off\n", { private = true })
end

-- The grants switch (`guard grants on|off|status`): off by default. With it off nothing reads the
-- grant store and every audit line carries grant_id "-".
local function grants_path() local d = dir(); return d and (d .. "/guard-grants") or nil end
function M.grants_enabled()
  local path = grants_path()
  local f = path and io.open(path, "r")
  if not f then return false end
  local text = f:read("*l")
  f:close()
  return text == "on"
end
function M.set_grants(on)
  local path = grants_path()
  if not path then return nil, "Butler data directory is unknown" end
  pcall(remuda.mkdir, dir())
  return remuda.fs.write_atomic(path, on and "on\n" or "off\n", { private = true })
end

-- Text safe for one log line: control characters become spaces, secret-looking
-- tokens are masked, invalid UTF-8 is replaced, and the result is capped.
local SECRET_PATTERNS = {
  { "[Aa]uthorization:%s*[Bb]earer%s+[%w._~+/=-]+", "Authorization: Bearer ***" },
  { "[Aa]uthorization:%s*[Bb]asic%s+[%w+/=]+", "Authorization: Basic ***" },
  { "[Bb]earer%s+[%w._~+/=-]+", "Bearer ***" },
  { "://[^/%s:@]+:[^/%s@]+@", "://***@" },
  { "sk%-[%w_-]+", "***" },
  { "gh[pousr]_[%w]+", "***" },
  { "github_pat_[%w_]+", "***" },
  { "xox[abpr]%-[%w-]+", "***" },
  { "AKIA[%u%d]+", "***" },
  { "eyJ[%w_-]+%.[%w_-]+%.[%w_-]*", "***" },
}
function M.redact(text, cap)
  text = tostring(text or ""):sub(1, REDACT_PREFIX):gsub("%c", " ")
  for _, rule in ipairs(SECRET_PATTERNS) do text = text:gsub(rule[1], rule[2]) end
  -- NAME=value and --flag value where the name says secret.
  text = text:gsub("([%w_]*[Tt][Oo][Kk][Ee][Nn][%w_]*)=[^%s;|&]+", "%1=***")
    :gsub("([%w_]*[Ss][Ee][Cc][Rr][Ee][Tt][%w_]*)=[^%s;|&]+", "%1=***")
    :gsub("([%w_]*[Pp][Aa][Ss][Ss][Ww]?[Oo]?[Rr]?[Dd]?[%w_]*)=[^%s;|&]+", "%1=***")
    :gsub("([%w_]*[Aa][Pp][Ii][_-]?[Kk][Ee][Yy][%w_]*)=[^%s;|&]+", "%1=***")
    :gsub("(%-%-[%w-]*[Tt][Oo][Kk][Ee][Nn][%w-]*)%s+[^%s;|&]+", "%1 ***")
    :gsub("([Xx]%-[%w-]*[Kk][Ee][Yy][%w-]*:%s*)[^\r\n'\"]+", "%1***")
    :gsub("(\"[%w_]*[Pp][Aa][Ss][Ss][%w_]*\"%s*:%s*\")[^\"]*", "%1***")
    :gsub("(\"[%w_]*[Tt][Oo][Kk][Ee][Nn][%w_]*\"%s*:%s*\")[^\"]*", "%1***")
    :gsub("(\"[%w_]*[Ss][Ee][Cc][Rr][Ee][Tt][%w_]*\"%s*:%s*\")[^\"]*", "%1***")
    :gsub("(%[['\"][%w_-]*[Kk][Ee][Yy][%w_-]*['\"]%]%s*=%s*['\"])[^'\"]*", "%1***")
    :gsub("(%[['\"][%w_-]*[Pp][Aa][Ss][Ss][%w_-]*['\"]%]%s*=%s*['\"])[^'\"]*", "%1***")
    :gsub("(%[['\"][%w_-]*[Tt][Oo][Kk][Ee][Nn][%w_-]*['\"]%]%s*=%s*['\"])[^'\"]*", "%1***")
    :gsub("(%-%-[%w-]*[Pp][Aa][Ss][Ss][%w-]*)%s+[^%s;|&]+", "%1 ***")
    :gsub("([?&])([%w_.%-]+)=([^&%s]*)", function(prefix, name, value)
      local lower = name:lower()
      if lower:find("sig", 1, true) or lower:find("auth", 1, true) or lower:find("cred", 1, true)
        or lower:find("key", 1, true) then return prefix .. name .. "=***" end
    end)
  if utf8 and not utf8.len(text) then text = text:gsub("[\128-\255]", "?") end
  cap = cap or SUMMARY_CAP
  if #text > cap then
    text = text:sub(1, cap)
    if utf8 then while #text > 0 and not utf8.len(text) do text = text:sub(1, -2) end end
    text = text .. "..."
  end
  return text
end

local function home()
  local ok, h = pcall(function() return remuda._butler_system.home() end)
  return ok and h or os.getenv("HOME")
end

-- Classification: first match wins, most serious class first.
local PROTECTED = { "/.ssh", "/.config/remuda", "/.local/share/remuda/butler" }
local HOOK_FILES = { "settings.json", "settings.local.json", "hooks.json", "config.toml", "managed-settings.json" }
M.PROTECTED, M.HOOK_FILES = PROTECTED, HOOK_FILES

local function expand(path, h)
  if type(path) ~= "string" then return "" end
  if h then path = path:gsub("^~", h):gsub("%$HOME", h):gsub("%${HOME}", h) end
  return path
end

-- Hook/settings files under any .claude/.codex dir, plus the user-level instruction files anchored to the real home.
local INSTRUCTION_FILES = { "/.codex/AGENTS.md", "/.claude/CLAUDE.md" }
local function weakens(path, h)
  local lower = path:lower()
  if lower:find("/%.claude/") or lower:find("/%.codex/") then
    local base = path:match("([^/]+)$") or ""
    for _, f in ipairs(HOOK_FILES) do if base == f then return true end end
  end
  if h then
    for _, f in ipairs(INSTRUCTION_FILES) do if lower == (h .. f):lower() then return true end end
  end
  return false
end

local function protected(path, h)
  h = h or home()
  path = path:gsub("/+$", "")
  if h then
    for _, p in ipairs(PROTECTED) do
      local root = h .. p
      if path == root or path:sub(1, #root + 1) == root .. "/" then return true end
    end
  end
  local actual = dir()
  if actual and (path == actual or path:sub(1, #actual + 1) == actual .. "/") then return true end
  if h and path == h .. "/.local/share/remuda/butler" then return true end
end

local function file_class(path, ctx)
  path = expand(path, ctx.home)
  if weakens(path, ctx.home) then return "weaken" end
  if protected(path, ctx.home) then return "escape" end
  local cwd = ctx.cwd
  if path:sub(1, 1) == "/" and type(cwd) == "string" and cwd ~= "" then
    if path ~= cwd and path:sub(1, #cwd + 1) ~= cwd .. "/" then return "escape" end
  end
  return "other"
end

local WORD_STRIP = { sudo = true, env = true, command = true, nohup = true, time = true, exec = true, builtin = true }
local function words(segment)
  local out = {}
  local token, quote, escaped = {}, nil, false
  local function flush()
    if #token > 0 then out[#out + 1] = table.concat(token); token = {} end
  end
  for i = 1, #segment do
    local c = segment:sub(i, i)
    if escaped then token[#token + 1] = c; escaped = false
    elseif quote then
      if c == quote then quote = nil else token[#token + 1] = c end
    elseif c == "\\" then escaped = true
    elseif c == "'" or c == '"' then quote = c
    elseif c:match("%s") then flush()
    else token[#token + 1] = c end
  end
  if escaped then token[#token + 1] = "\\" end
  flush()
  local cleaned = {}
  for _, w in ipairs(out) do
    w = w:gsub("^[({!]+", ""):gsub("[)}]+$", "")
    if w ~= "" then cleaned[#cleaned + 1] = w end
  end
  out = cleaned
  local i = 1
  while out[i] do
    local word = out[i]
    if word == "env" then
      table.remove(out, i)
      if out[i] == "-i" or out[i] == "--ignore-environment" then table.remove(out, i) end
      if out[i] == "--" then table.remove(out, i) end
      while out[i] and (out[i]:find("^[%w_]+=") or out[i] == "-i" or out[i] == "--ignore-environment"
        or out[i] == "-u" or out[i] == "--unset") do
        local takes_value = out[i] == "-u" or out[i] == "--unset"
        table.remove(out, i)
        if takes_value and out[i] then table.remove(out, i) end
      end
    elseif word == "sudo" then
      table.remove(out, i)
      while out[i] and out[i]:sub(1, 1) == "-" do
        local takes_value = out[i] == "-u" or out[i] == "--user" or out[i] == "-g" or out[i] == "--group"
          or out[i] == "-h" or out[i] == "--host" or out[i] == "-p" or out[i] == "--prompt"
          or out[i] == "-C" or out[i] == "-D"
        table.remove(out, i)
        if takes_value and out[i] then table.remove(out, i) end
      end
    elseif word == "timeout" then
      table.remove(out, i)
      while out[i] and out[i]:sub(1, 1) == "-" do
        local takes_value = out[i] == "-s" or out[i] == "--signal" or out[i] == "-k" or out[i] == "--kill-after"
        table.remove(out, i)
        if takes_value and out[i] then table.remove(out, i) end
      end
      if out[i] and out[i]:match("^%d") then table.remove(out, i) end
    elseif word == "nice" or word == "xargs" then
      local wrapper = word
      table.remove(out, i)
      while out[i] and (out[i]:sub(1, 1) == "-" or (wrapper == "nice" and out[i]:match("^%-%d"))) do
        local option = out[i]
        local takes_value = wrapper == "nice" and (option == "-n" or option == "--adjustment")
          or wrapper == "xargs" and (option == "-a" or option == "-d" or option == "-E" or option == "-I"
            or option == "-L" or option == "-n" or option == "-P" or option == "-s"
            or option == "--arg-file" or option == "--delimiter" or option == "--eof"
            or option == "--replace" or option == "--max-lines" or option == "--max-args"
            or option == "--max-procs" or option == "--max-chars")
        table.remove(out, i)
        if takes_value and out[i] then table.remove(out, i) end
      end
    elseif WORD_STRIP[word] or word == "then" or word == "do" or word == "else" then
      table.remove(out, i)
    elseif word:find("^[%w_]+=") then
      table.remove(out, i)
    else
      break
    end
  end
  return out
end
local function has(w, set) for _, x in ipairs(w) do if set[x] then return true end end end
local function has_flag(w, letters)
  for i = 2, #w do
    local a = w[i]
    if a:find("^%-%-?[%a]") and not a:find("^%-%-") and a:find("[" .. letters .. "]") then return true end
    if a == "--recursive" or a == "--force" then return true end
  end
end

local RANK = { weaken = 1, control = 2, identity = 3, push = 4, destroy = 5, escape = 6, net = 7, script = 8, other = 9 }
local NET = { curl = true, wget = true, scp = true, sftp = true, ssh = true, nc = true, ncat = true, ftp = true, rsync = true }
local WRITERS = { rm = true, mv = true, cp = true, tee = true, dd = true, chmod = true, chown = true, ln = true,
  touch = true, truncate = true, install = true }
local IDENTITY = { approve = true, deny = true, ["approve-text"] = true, ["typed-lines"] = true,
  ["shell-lines"] = true, ["status-commands"] = true }

-- Global `remuda` options that take the next word as their value (`--opt=value` is one word and needs no entry).
local VALUE_OPT = { ["-s"] = true, ["--server"] = true, ["-c"] = true, ["--config"] = true,
  ["--runtime-dir"] = true, ["--socket"] = true, ["--data-home"] = true }
local function segment_class(w, text, ctx)
  local first = (w[1] or ""):match("([^/]+)$") or ""
  if text:find("--dangerously", 1, true) or text:find("--yolo", 1, true) or text:find("bypassPermissions", 1, true)
      or text:find("danger-full-access", 1, true) or text:find("--sandbox%s+full") then
    return "weaken"
  end
  local touches_protected = false
  for _, a in ipairs(w) do
    local p = expand((a:gsub("^[<>]+", "")), ctx.home)
    if p:find("/", 1, true) and protected(p, ctx.home) then touches_protected = true end
    if weakens(p, ctx.home) and (WRITERS[first] or first == "sed" or text:find(">", 1, true)) then return "weaken" end
  end
  if first == "kill" or first == "pkill" or first == "killall" then return "control" end
  if first == "remuda" then
    if has(w, { stop = true, restart = true, kill = true }) then return "control" end
    -- Classify the butler verb first: RANK puts weaken/control/identity above script, so a later `run` or `-ex`
    -- argument of a butler verb must not downgrade it. Script markers count only before the `butler` word.
    local butler_at = #w + 1
    for i, a in ipairs(w) do
      if a == "butler" then
        butler_at = i
        local verb = w[i + 1]
        if verb == "close" then return "control" end
        if verb == "guard" and w[i + 2] == "approvals" and (w[i + 3] == "on" or w[i + 3] == "off") then return "weaken" end
        if verb == "guard" and w[i + 2] == "grants" and (w[i + 3] == "on" or w[i + 3] == "off") then return "weaken" end
        if verb == "guard" and (w[i + 2] == "on" or w[i + 2] == "off") then return "weaken" end
        if IDENTITY[verb or ""] then return "identity" end
        if verb == "matrix" and (w[i + 2] == "join" or w[i + 2] == "leave" or w[i + 2] == "invite"
            or w[i + 2] == "mark-all") then
          return "identity"
        end
        break
      end
    end
    -- The CLI's Lua entry points are `lua`, `exec`, `repl` (as the verb) and -e / --eval (the value may be attached:
    -- -e'code', --eval=code). `run` starts a command in a session, so it is script-class too; `eval` is kept as one.
    -- Only the verb (the first word that is not an option or the value of a VALUE_OPT) counts, so `remuda send NAME run it`
    -- is a message, not a script.
    local i = 2
    while i < butler_at do
      local a = w[i]
      if a:find("^%-e") or a:find("^%-%-eval") then return "script" end
      if VALUE_OPT[a] then i = i + 1
      elseif a:sub(1, 1) ~= "-" then
        if a == "lua" or a == "exec" or a == "repl" or a == "eval" or a == "run" then return "script" end
        break
      end
      i = i + 1
    end
  end
  if first == "git" and has(w, { push = true }) then return "push" end
  if first == "gh" and w[2] == "pr" and w[3] == "merge" then return "push" end
  if first == "rm" and has_flag(w, "rRf") then return "destroy" end
  if first == "git" and ((has(w, { reset = true }) and has(w, { ["--hard"] = true }))
      or has(w, { clean = true })) then return "destroy" end
  if first == "dd" or first == "mkfs" or first == "shred" or first == "diskutil" then return "destroy" end
  if touches_protected and (WRITERS[first] or first == "sed" or text:find(">", 1, true)) then return "escape" end
  if NET[first] or (first == "gh" and w[2] == "api") then return "net" end
  return "other"
end

local function split_commands(command)
  local segments, buf, quote, escaped = {}, {}, nil, false
  local function push(text)
    for _, seg in ipairs(split_commands(text)) do segments[#segments + 1] = seg end
  end
  local function flush()
    local seg = table.concat(buf)
    if seg:match("%S") then segments[#segments + 1] = seg end
    buf = {}
  end
  local function substitution_end(start)
    local depth, q, esc = 1, nil, false
    local j = start + 2
    while j <= #command do
      local c = command:sub(j, j)
      if esc then esc = false
      elseif c == "\\" then esc = true
      elseif q then if c == q then q = nil end
      elseif c == "'" or c == '"' then q = c
      elseif command:sub(j, j + 1) == "$(" then depth = depth + 1; j = j + 1
      elseif c == ")" then depth = depth - 1; if depth == 0 then return j end end
      j = j + 1
    end
  end
  local i = 1
  while i <= #command do
    local c = command:sub(i, i)
    if escaped then buf[#buf + 1] = c; escaped = false; i = i + 1
    elseif quote ~= "'" and command:sub(i, i + 1) == "$(" then
      local finish = substitution_end(i)
      if finish then
        push(command:sub(i + 2, finish - 1))
        buf[#buf + 1] = command:sub(i, finish)
        i = finish + 1
      else buf[#buf + 1] = c; i = i + 1 end
    elseif quote ~= "'" and c == "`" then
      local finish = command:find("`", i + 1, true)
      if finish then
        push(command:sub(i + 1, finish - 1))
        buf[#buf + 1] = command:sub(i, finish)
        i = finish + 1
      else buf[#buf + 1] = c; i = i + 1 end
    elseif quote then
      buf[#buf + 1] = c
      if c == quote then quote = nil elseif quote == '"' and c == "\\" then escaped = true end
      i = i + 1
    elseif c == "'" or c == '"' then quote = c; buf[#buf + 1] = c; i = i + 1
    elseif c == "\\" then escaped = true; buf[#buf + 1] = c; i = i + 1
    elseif c == "|" and command:sub(i - 1, i - 1) == ">" then
      buf[#buf + 1] = c
      i = i + 1
    elseif c == ";" or c == "|" or c == "&" or c == "\r" or c == "\n" then
      flush()
      if (c == "|" or c == "&") and command:sub(i + 1, i + 1) == c then i = i + 1 end
      i = i + 1
    else buf[#buf + 1] = c; i = i + 1 end
  end
  flush()
  return segments
end

local function bypass_flag(text)
  local tokens = words(tostring(text or ""))
  for i, raw in ipairs(tokens) do
    local token = raw:lower()
    local option = token:match("^%-%-") ~= nil
    local setting_value = (tokens[i - 1] or ""):lower()
    local next_value = (tokens[i + 1] or ""):lower()
    if option and token:match("^%-%-dangerously[%w%-]*$") or token == "--yolo"
      or option and token:match("^%-%-bypasspermissions$")
      or token:match("^%-%-permission%-mode=bypasspermissions$")
      or token == "bypasspermissions" and (setting_value == "--permission-mode" or setting_value == "--permission_mode")
      or token == "--danger-full-access"
      or token == "danger-full-access" and (option or setting_value == "--permission-mode" or setting_value == "--sandbox"
        or setting_value:match("^sandbox_mode="))
      or token == "--sandbox=full" or token == "--sandbox-full"
      or token:match("^sandbox_mode=danger%-full%-access$")
      or (token == "full" and (setting_value == "--sandbox" or setting_value == "--sandbox="))
      or (token == "-a" or token == "--ask-for-approval") and next_value == "never"
      or token == "--ask-for-approval=never" or token == "-a=never"
      or token == "-c" and next_value:match("^approval_policy=never$")
      or token:match("^approval_policy=never$") and setting_value == "-c" then return true end
  end
  return false
end

local function protected_write_path(path, ctx)
  path = expand(path:gsub("^[<>]+", ""):gsub("[<>]+$", ""), ctx.home)
  if path == "" then return false end
  if path:sub(1, 1) ~= "/" then path = (ctx.cwd or "") .. "/" .. path end
  return weakens(path, ctx.home) or protected(path, ctx.home) == true
end

local function owner_or_daemon_command(w, text)
  local first = (w[1] or ""):match("([^/]+)$") or ""
  if first ~= "remuda" then return nil end
  local remuda_at
  for i, word in ipairs(w) do if (word:match("([^/]+)$") or word) == "remuda" then remuda_at = i; break end end
  if not remuda_at then return nil end
  local butler_at
  for i = remuda_at + 1, #w do if w[i] == "butler" then butler_at = i; break end end
  if butler_at then
    local verb, sub = w[butler_at + 1], w[butler_at + 2]
    if verb == "guard" and (sub == "on" or sub == "off" or sub == "approvals" or sub == "deny") then
      return "Butler owner control"
    end
    -- Only the switch is owner control; `guard grants` and `guard grants status` are read-only views.
    if verb == "guard" and sub == "grants" and (w[butler_at + 3] == "on" or w[butler_at + 3] == "off") then
      return "Butler owner control"
    end
    if verb == "approve" or verb == "deny" or verb == "approve-text" or verb == "typed-lines"
      or verb == "shell-lines" or verb == "status-commands" then return "Butler owner control" end
  end
  local subcommand
  local i = remuda_at + 1
  while i <= #w do
    local word = w[i]
    if VALUE_OPT[word] then
      i = i + 2
    elseif word:sub(1, 1) ~= "-" then
      subcommand = word
      break
    else
      i = i + 1
    end
  end
  if subcommand == "stop" or subcommand == "restart" or subcommand == "kill" then
    local servers, test_servers_only = 0, true
    for i = remuda_at + 1, #w do
      if w[i] == "-s" or w[i] == "--server" then
        servers = servers + 1
        local name = w[i + 1]
        if not name or not name:match("^h%d+c?$") then test_servers_only = false end
      elseif w[i]:match("^%-s") or w[i]:match("^%-%-server=") then
        test_servers_only = false
      end
      if w[i] == "-c" or w[i] == "--config" or w[i]:match("^%-%-socket=")
          or w[i]:match("^%-%-runtime%-dir=") or w[i]:match("^%-%-data%-home=") or w[i]:match("^%-%-config=")
          or w[i] == "--socket" or w[i] == "--runtime-dir" or w[i] == "--data-home" then
        test_servers_only = false
      end
    end
    if servers > 0 and test_servers_only then return nil end
    return "Remuda daemon control"
  end
end

local function protected_push(w)
  if ((w[1] or ""):match("([^/]+)$") or "") ~= "git" then return false end
  local push_at
  for i, word in ipairs(w) do if word == "push" then push_at = i; break end end
  if not push_at then return false end
  local guarded, branch_named = false, false
  for i = push_at + 1, #w do
    local word = w[i]
    if word == "--force" or word:match("^%-%-force%-with%-lease") or word == "--delete"
      or (word:match("^%-%w+$") and word:find("f", 2, true))
      or (word:match("^%-%w+$") and word:find("d", 2, true)) then guarded = true end
    if word:match("^[+:]") then guarded = true end
    local ref = word:gsub("^%+", ""):gsub("^[^=]+=", "")
    for name in ref:gmatch("[^:]+") do
      name = name:gsub("^refs/heads/", "")
      if name == "main" or name == "master" or name == "trunk" then branch_named = true end
    end
  end
  return guarded and branch_named
end

local function protected_redirect(command, ctx)
  local quote, escaped, i = nil, false, 1
  while i <= #command do
    local c = command:sub(i, i)
    if escaped then escaped = false
    elseif c == "\\" and quote ~= "'" then escaped = true
    elseif quote then if c == quote then quote = nil end
    elseif c == "'" or c == '"' then quote = c
    elseif c == ">" and command:sub(i - 1, i - 1) ~= "-" then
      local j = i + 1
      if command:sub(j, j) == ">" then j = j + 1 end
      if command:sub(j, j) == "|" then j = j + 1 end
      while command:sub(j, j):match("%s") do j = j + 1 end
      if command:sub(j, j) == "&" then
        j = j + 1
        if command:sub(j, j):match("%d") then i = j
        end
      else
        local target
        local delimiter = command:sub(j, j)
        if delimiter == "'" or delimiter == '"' then
          local finish = command:find(delimiter, j + 1, true)
          if finish then target = command:sub(j + 1, finish - 1); i = finish end
        else
          local finish = j
          while finish <= #command and not command:sub(finish, finish):match("[%s;|&]") do finish = finish + 1 end
          target = command:sub(j, finish - 1)
          i = finish - 1
        end
        if target and target ~= "" and protected_write_path(target, ctx) then return true end
      end
    end
    i = i + 1
  end
  return false
end

local function sed_in_place(w)
  for i = 2, #w do if w[i] == "-i" or w[i] == "--in-place" or w[i]:match("^%-i[^-].*") then return true end end
  return false
end

local function writer_touches_protected(first, w, ctx)
  local candidates = {}
  local destination_only = first == "cp" or first == "ln" or first == "install"
  if first == "dd" then
    for i = 2, #w do
      local output = w[i]:match("^of=(.+)$")
      if output then candidates[#candidates + 1] = output end
    end
  elseif destination_only then
    if #w > 1 then candidates[1] = w[#w] end
  else
    for i = 2, #w do
      local path = w[i]
      if path:find("/", 1, true) or path:match("^~") or path:match("^%.%.?") then candidates[#candidates + 1] = path end
    end
  end
  for _, path in ipairs(candidates) do if protected_write_path(path, ctx) then return true end end
  return false
end

local function segment_deny_reason(seg, ctx)
  local w = words(seg)
  -- The grant store is written only by Butler itself. Code that names its module or the test flag is denied (a
  -- remuda -e/lua/exec/run command; shell wrappers are unwrapped below), as is setting the flag's env var. Plain
  -- reads of repo files that mention them (git diff, rg) are not. Cooperative: text, not a boundary. Writes to the
  -- data dir itself are the protected-write checks further down.
  if (seg:find("guard_grants", 1, true) or seg:find("_butler_test", 1, true) or seg:find("REMUDA_BUTLER_TEST", 1, true))
      and (segment_class(w, seg, ctx) == "script" or seg:find("REMUDA_BUTLER_TEST=", 1, true)) then
    return "Butler grant store"
  end
  local executable = (w[1] or ""):match("([^/]+)$") or ""
  if executable == "sh" or executable == "bash" or executable == "zsh" or executable == "dash"
      or executable == "ksh" or executable == "ash" then
    for i = 2, #w do
      if w[i] == "-c" or w[i]:match("^%-%w*c%w*$") then
        local body = {}
        for j = i + 1, #w do body[#body + 1] = w[j] end
        if #body > 0 then
          for _, nested in ipairs(split_commands(table.concat(body, " "))) do
            local reason = segment_deny_reason(nested, ctx)
            if reason then return reason end
          end
        end
        return nil
      end
    end
  end
  if executable == "eval" then
    local body = {}
    for i = 2, #w do body[#body + 1] = w[i] end
    for _, nested in ipairs(split_commands(table.concat(body, " "))) do
      local reason = segment_deny_reason(nested, ctx)
      if reason then return reason end
    end
  elseif executable == "find" then
    for i = 2, #w do
      if w[i] == "-exec" or w[i] == "-execdir" then
        local body = {}
        for j = i + 1, #w do
          if w[j] == ";" or w[j] == "+" then break end
          body[#body + 1] = w[j]
        end
        if #body > 0 then
          for _, nested in ipairs(split_commands(table.concat(body, " "))) do
            local reason = segment_deny_reason(nested, ctx)
            if reason then return reason end
          end
        end
      end
    end
  end
  if bypass_flag(seg) then return "Agent permission bypass flag" end
  local owner = owner_or_daemon_command(w, seg)
  if owner then return owner end
  if protected_push(w) then return "Protected branch push" end
  local first = (w[1] or ""):match("([^/]+)$") or ""
  local redirect = protected_redirect(seg, ctx)
  local writer = WRITERS[first] or (first == "sed" and sed_in_place(w))
  if redirect or (writer and writer_touches_protected(first, w, ctx)) then return "Protected settings or directory write" end
end

-- Return a short constant reason for a narrowly recognised high-impact action.
-- Unknown tools and actions return nil; this is an opt-in cooperative guardrail.
function M.deny_reason(tool, input, ctx)
  ctx = ctx or {}
  if ctx.home == nil then ctx.home = home() end
  input = type(input) == "table" and input or {}
  tool = tostring(tool or "")
  if tool == "Bash" or tool == "PowerShell" then
    local command = type(input.command) == "string" and input.command or ""
    -- A here-doc or a pipe puts the code in one segment and the script runner in another, so the module-name test
    -- reads the whole string and the script test any segment. Still cooperative: text, not a boundary.
    local segments = split_commands(command)
    if command:find("guard_grants", 1, true) or command:find("_butler_test", 1, true)
        or command:find("REMUDA_BUTLER_TEST", 1, true) then
      for _, seg in ipairs(segments) do
        if segment_class(words(seg), seg, ctx) == "script" then return "Butler grant store" end
      end
    end
    for _, seg in ipairs(segments) do
      local reason = segment_deny_reason(seg, ctx)
      if reason then return reason end
    end
    return nil
  end
  if tool:find("run_script$") and type(input.code) == "string" and (input.code:find("guard_grants", 1, true)
      or input.code:find("_butler_test", 1, true) or input.code:find("REMUDA_BUTLER_TEST", 1, true)) then
    return "Butler grant store"
  end
  if tool == "Write" or tool == "Edit" or tool == "MultiEdit" or tool == "NotebookEdit" then
    local path = input.file_path or input.notebook_path
    if type(path) == "string" and protected_write_path(path, ctx) then return "Protected settings or directory write" end
  end
  return nil
end

-- tool_name + tool_input (decoded hook fields) -> one class name.
function M.classify(tool, input, ctx)
  ctx = ctx or {}
  if ctx.home == nil then ctx.home = home() end
  input = type(input) == "table" and input or {}
  tool = tostring(tool or "")
  if tool == "Bash" or tool == "PowerShell" then
    local command = type(input.command) == "string" and input.command or ""
    local best = "other"
    for _, seg in ipairs(split_commands(command)) do
      local class = segment_class(words(seg), seg, ctx)
      if RANK[class] < RANK[best] then best = class end
    end
    return best
  end
  if tool == "Write" or tool == "Edit" or tool == "MultiEdit" or tool == "NotebookEdit" then
    return file_class(input.file_path or input.notebook_path, ctx)
  end
  if tool == "WebFetch" or tool == "WebSearch" then return "net" end
  if tool:find("run_script$") then return "script" end
  return "other"
end

-- One short, redacted description of what the tool call does.
function M.summary(tool, input, cap)
  input = type(input) == "table" and input or {}
  tool = tostring(tool or "")
  if tool:find("run_script$") then
    local code = type(input.code) == "string" and input.code or ""
    return string.format("size=%d %s", #code, M.redact(code, SCRIPT_HEAD))
  end
  local value = input.command or input.file_path or input.notebook_path or input.url or input.query or input.pattern
  if type(value) ~= "string" then
    local keys = {}
    for k, v in pairs(input) do if type(v) == "string" then keys[#keys + 1] = k end end
    table.sort(keys)
    value = keys[1] and input[keys[1]]
  end
  return M.redact(value or "", cap)
end

local STAMP = "%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ"

-- Rotated files beside the log: LOG.1 and the dated archives LOG.<stamp>[-N] (stamp is nil for LOG.1).
local function archives()
  local out = {}
  local ok, names = pcall(remuda.list_dir, dir())
  for _, name in ipairs(ok and type(names) == "table" and names or {}) do
    local suffix = name:match("^guard%-audit%.jsonl%.(.+)$") or ""
    local stamp = suffix:match("^(" .. STAMP .. ")$") or suffix:match("^(" .. STAMP .. ")%-%d+$")
    if suffix == "1" or stamp then out[#out + 1] = { path = dir() .. "/" .. name, stamp = stamp } end
  end
  return out
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

-- Sticky marker: a switch was turned off while its audit line could not be written. The next
-- successful audit line clears it. Its text is shown by `guard status|stats`, so it is sanitised.
local function unaudited_path() local d = dir(); return d and (d .. "/guard-unaudited") or nil end
local function unaudited_note()
  local f = unaudited_path() and io.open(unaudited_path(), "r")
  if not f then return "" end
  local why = (f:read("*l") or ""):gsub("[%c]", "?"):sub(1, SUMMARY_CAP)
  f:close()
  return "\nWARNING: a guard switch was turned off and NOT audited: " .. why
    .. " (cleared by the next audit line)"
end

function M.rotate(path, now)
  now = now or os.time()
  if exists(path .. ".1") then
    -- Two rotations in one second must not overwrite an archive: add a counter.
    local dated, n = path .. "." .. os.date("!%Y%m%dT%H%M%SZ", now), 0
    local target = dated
    while exists(target) do n = n + 1; target = dated .. "-" .. n end
    os.rename(path .. ".1", target)
  end
  -- A failed rename returns false: the caller must not truncate the live log.
  if not os.rename(path, path .. ".1") then return false end
  local cutoff = os.date("!%Y%m%dT%H%M%SZ", now - M.RETENTION_DAYS * 86400)
  for _, a in ipairs(archives()) do
    if a.stamp and a.stamp < cutoff then os.remove(a.path) end
  end
  return true
end

-- Append one JSON line to the audit log (0600, rotated). Returns true, or nil and why.
local function write_line(record)
  local path = M.log_path()
  if not path then return nil, "no audit path" end
  local ok, why = pcall(function()
    pcall(remuda.mkdir, dir())
    local f = io.open(path, "r")
    local size = 0
    if f then size = f:seek("end") or 0; f:close() end
    if size >= LOG_CAP and M.rotate(path) then f = nil end -- a failed rotate keeps appending to the live log
    if not f then assert(remuda.fs.write_atomic(path, "", { private = true })) end
    local out = assert(io.open(path, "a"))
    local line = '{"time":' .. remuda.json.encode(os.date("!%Y-%m-%dT%H:%M:%SZ"))
    for _, key in ipairs({ "session", "kind", "event", "tool", "class", "summary" }) do
      line = line .. ',"' .. key .. '":' .. remuda.json.encode(tostring(record[key] or ""))
    end
    -- grant_id names the grant that allowed the call; no hook line carries one while nothing allows (enforcement is a later PR).
    line = line .. ',"grant_id":' .. remuda.json.encode(tostring(record.grant_id or "-"))
    for _, key in ipairs({ "id", "hash" }) do
      if record[key] then line = line .. ',"' .. key .. '":' .. remuda.json.encode(tostring(record[key])) end
    end
    assert(out:write(line .. "}\n"))
    out:close()
  end)
  if not ok then return nil, tostring(why) end
  return true
end

-- Append one line; then, if a guard-unaudited marker exists, record its text in a 'switch' line
-- and only then delete it (the marker stays when that line cannot be written).
function M.append(record)
  local ok, why = write_line(record)
  if not ok then return nil, why end
  local path = unaudited_path()
  local f = path and io.open(path, "r")
  if f then
    local text = (f:read("*l") or ""):gsub("%c", " "):sub(1, SUMMARY_CAP)
    f:close()
    if write_line({ session = "operator", event = "switch", tool = "", class = "other",
        summary = "earlier off NOT audited: " .. text }) then os.remove(path) end
  end
  return true
end

local function note(text)
  if type(remuda.log) == "function" then pcall(remuda.log, "warn", text) end
end

-- Record a non-hook observation (for example a recognised Codex prompt) when the switch is on.
function M.observe(event, session, kind, detail)
  if not M.enabled() then return end
  M.append({ session = session, kind = kind, event = event, tool = "", class = "other",
    summary = M.redact(detail) })
end

local function hook(caller)
  local env = caller and caller.env or {}
  local text = caller and caller.stdin
  local record = { session = env.REMUDA_BUTLER_AGENT_ALIAS or env.REMUDA_BUTLER_SESSION_NAME or "",
    kind = env.REMUDA_BUTLER_AGENT_KIND or "" }
  if type(text) ~= "string" then record.event = "no-input"; record.tool = ""; record.class = "other"; return record end
  if #text > MAX_INPUT then
    record.event = "oversized"
    record.tool = text:match('"tool_name"%s*:%s*"([^"]*)"') or ""
    record.class = "other"
    record.summary = "payload " .. #text .. " bytes"
    if M.deny_enabled() then
      local decoded_ok, oversized = pcall(remuda.json.decode, text)
      if decoded_ok and type(oversized) == "table" and oversized.hook_event_name == "PreToolUse" then
        local tool = tostring(oversized.tool_name or "")
        local original = type(oversized.tool_input) == "table" and oversized.tool_input or {}
        local safe_input = {}
        if tool == "Bash" or tool == "PowerShell" then
          safe_input.command = type(original.command) == "string" and original.command:sub(1, 4096) or ""
        elseif tool == "Write" or tool == "Edit" or tool == "MultiEdit" or tool == "NotebookEdit" then
          safe_input.file_path, safe_input.notebook_path = original.file_path, original.notebook_path
        end
        local partial = { hook_event_name = "PreToolUse", tool_name = tool, tool_input = safe_input, cwd = oversized.cwd }
        local reason = M.deny_reason(tool, safe_input, { cwd = oversized.cwd })
        if reason then
          record.event, record.tool = "PreToolUse", tool
          record.class = M.classify(tool, safe_input, { cwd = oversized.cwd })
          record.summary = M.summary(tool, safe_input)
          return record, partial
        end
      end
    end
    return record
  end
  local decoded_ok, hook_json = pcall(remuda.json.decode, text)
  if not decoded_ok or type(hook_json) ~= "table" then
    record.event, record.tool, record.class, record.summary = "unparsed", "", "other", ""
    return record
  end
  record.event = tostring(hook_json.hook_event_name or "")
  record.tool = tostring(hook_json.tool_name or "")
  record.class = M.classify(record.tool, hook_json.tool_input, { cwd = hook_json.cwd })
  record.summary = M.summary(record.tool, hook_json.tool_input)
  return record, hook_json
end

local SWITCH_NOTE = "Applies to sessions launched from now on; running sessions keep their settings."

-- Record who changed a switch, as evidence from the forwarded env (the caller's alias, else "operator"),
-- not as a control: the weaken-class deny is the control. Returns true, or nil and why.
local function switched(caller, text)
  local env = caller and caller.env or {}
  local ok, appended, why = pcall(M.append, { session = env.REMUDA_BUTLER_AGENT_ALIAS or "operator",
    kind = env.REMUDA_BUTLER_AGENT_KIND, event = "switch", tool = "", class = "other", summary = text })
  if ok and appended then return true end
  return nil, "audit not written: " .. tostring(ok and why or appended)
end

-- Change a switch with its audit line. Turning one off is audited first; when the line cannot be
-- written it still turns off (fail open: the switch only narrows enforcement, and the owner must
-- never be locked out) but says so loudly and leaves the sticky guard-unaudited marker. Turning one
-- on is audited once it took effect. Returns true and a warning text for an unaudited off.
local function change(caller, label, on, set)
  local warning
  if not on then
    local ok, why = switched(caller, label .. " off")
    if not ok then
      warning = "switched off, NOT audited: " .. tostring(why)
      io.stderr:write("guard: " .. label .. " " .. warning .. "\n")
      if unaudited_path() then
        pcall(remuda.fs.write_atomic, unaudited_path(), tostring(why):gsub("%c", " ") .. "\n", { private = true })
      end
    end
  end
  local written, why = set(on)
  if not written then
    -- The off line is already in the log: say it did not take effect.
    if not on then
      switched(caller, label .. " off failed: " .. tostring(why))
      -- Nothing turned off, so an unaudited-off marker would only mislead.
      if warning and unaudited_path() then os.remove(unaudited_path()) end
    end
    return nil, why
  end
  if on then
    local ok, audit_why = switched(caller, label .. " on")
    if not ok then note("guard switch not audited: " .. tostring(audit_why)) end
  end
  return true, warning
end

local STATS_LINE_CAP = 16 * 1024 -- a longer line is tampered or foreign: counted as unreadable, never decoded
local KNOWN_CLASS = { push = 1, destroy = 1, escape = 1, net = 1, control = 1, weaken = 1, identity = 1,
  script = 1, other = 1 }
-- Every audit event name a producer appends (hooks, switch, approvals) must be listed here, or stats counts it as "other".
local KNOWN_EVENT = { PreToolUse = 1, PermissionRequest = 1, deny = 1, policy_error = 1, ["no-input"] = 1,
  oversized = 1, unparsed = 1, switch = 1, approval_requested = 1, approval_approved = 1,
  approval_denied = 1, approval_expired = 1, approval_failed = 1, approval_limited = 1, grant_created = 1,
  grant_refused = 1, grant_register_refused = 1, grant_revoked = 1, grant_revoke_unsaved = 1, grants_frozen = 1,
  grants_unfrozen = 1, owner_line_refused = 1, grants_unfreeze_failed = 1, grant_used = 1, grant_limited = 1 }
local TIME = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"

-- Call fn(line) for each line of f, or fn(nil) for one that is over the cap; memory stays bounded.
local function each_line(f, fn)
  local pending, skipping = "", false
  while true do
    local chunk, err = f:read(65536)
    if not chunk then
      if err then fn(nil) end -- not a readable file (for example a directory)
      break
    end
    pending = pending .. chunk
    local pos = 1 -- a cursor, so the rest of the chunk is not copied once per line
    while true do
      local nl = pending:find("\n", pos, true)
      if not nl then break end
      local len = nl - pos
      if skipping or len > STATS_LINE_CAP then fn(nil) else fn(pending:sub(pos, nl - 1)) end
      skipping = false
      pos = nl + 1
    end
    pending = pending:sub(pos)
    if #pending > STATS_LINE_CAP then pending, skipping = "", true end
  end
  if skipping or #pending > STATS_LINE_CAP then fn(nil) elseif #pending > 0 then fn(pending) end
end

-- `guard stats`: counts per class and per event over the log and its archives. It prints only known
-- class and event names (the rest count as "other"), so a tampered file cannot reach the terminal.
local function stats()
  local files = { M.log_path() }
  for _, a in ipairs(archives()) do files[#files + 1] = a.path end
  local total, unreadable, first, last, class, event = 0, 0, nil, nil, {}, {}
  for _, path in ipairs(files) do
    local f = io.open(path, "r")
    if f then
      local ok = pcall(each_line, f, function(line)
        local decoded, r = false, nil
        if line and line ~= "" then decoded, r = pcall(remuda.json.decode, line) end -- a blank line is unreadable, not worth a decode
        if not (decoded and type(r) == "table") then unreadable = unreadable + 1; return end
        total = total + 1
        if type(r.time) == "string" and r.time:match(TIME) then
          if not first or r.time < first then first = r.time end
          if not last or r.time > last then last = r.time end
        end
        local c = KNOWN_CLASS[r.class] and r.class or "other"
        local e = KNOWN_EVENT[r.event] and r.event or "other"
        class[c], event[e] = (class[c] or 0) + 1, (event[e] or 0) + 1
      end)
      if not ok then unreadable = unreadable + 1 end
      f:close()
    end
  end
  if total == 0 and unreadable == 0 then
    return "guard stats: no audit lines yet. Next: remuda butler guard on" .. unaudited_note()
  end
  local out = { "guard stats: lines: " .. total .. (first and (" since " .. first .. " until " .. last) or "")
    .. (unreadable > 0 and (" (unreadable: " .. unreadable .. ")") or "") }
  for _, kv in ipairs({ { "class", class }, { "event", event } }) do
    local names = {}
    for name in pairs(kv[2]) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do out[#out + 1] = kv[1] .. " " .. name .. ": " .. kv[2][name] end
  end
  return table.concat(out, "\n") .. unaudited_note()
end

-- `remuda butler guard [on|off|status]`. Without an argument it is the hook: it
-- always returns an empty answer (no decision) and exit 0.
function M.run(args, caller)
  local verb = args[2]
  if verb == nil then
    local reply
    local function audit(record)
      local ok, appended, why = pcall(M.append, record)
      if not ok then note("guard audit not written: " .. tostring(appended))
      elseif not appended then note("guard audit not written: " .. tostring(why)) end
    end
    local ok, err = pcall(function()
      if not M.enabled() then return end
      local record, hook_json = hook(caller)
      if hook_json and record.event == "PreToolUse" and M.deny_enabled() then
        local policy_ok, reason = pcall(M.deny_reason, record.tool, hook_json.tool_input, { cwd = hook_json.cwd })
        if not policy_ok then
          record.event = "policy_error"
          audit(record)
          note("guard policy failed open: " .. tostring(reason))
          return
        end
        if reason then
          record.event = "deny"
          reply = '{"hookSpecificOutput":{"hookEventName":'
            .. remuda.json.encode("PreToolUse") .. ',"permissionDecision":"deny","permissionDecisionReason":'
            .. remuda.json.encode("Butler guard: " .. reason) .. "}}"
          audit(record)
          return
        end
      end
      audit(record)
      local routing = remuda.butler.guard_approval
      if routing then reply = routing.maybe_request(record, hook_json) end
    end)
    if not ok then note("guard failed open: " .. tostring(err)) end
    return reply or ""
  end
  if #args == 3 and verb == "approvals" and (args[3] == "on" or args[3] == "off") then
    local written, why = change(caller, "guard approvals", args[3] == "on", M.set_approvals)
    local warn = why
    if not written then return remuda.fail("guard approvals switch not changed: " .. tostring(why), 1) end
    return "guard approvals are now " .. args[3] .. ". " .. SWITCH_NOTE
      .. (warn and ("\n" .. warn) or "")
      .. (args[3] == "on" and " Needs `guard on`; the owner answers Claude permission prompts in Matrix,"
        .. " and with no answer Claude shows its own prompt." or "")
  end
  if #args == 3 and verb == "approvals" and args[3] == "status" then
    return "guard approvals: " .. (M.approvals_enabled() and "on" or "off") .. " (guard: "
      .. (M.enabled() and "on" or "off") .. "; routing runs only when both are on)\n" .. SWITCH_NOTE
  end
  if #args == 3 and verb == "grants" and (args[3] == "on" or args[3] == "off") then
    local written, why = change(caller, "guard grants", args[3] == "on", M.set_grants)
    local warn = why
    if not written then return remuda.fail("guard grants switch not changed: " .. tostring(why), 1) end
    return "guard grants are now " .. args[3] .. ". There is no way to create a grant from the CLI."
      .. (warn and ("\n" .. warn) or "")
  end
  if #args == 3 and verb == "grants" and args[3] == "status" then
    return "guard grants: " .. (M.grants_enabled() and "on" or "off") .. " (guard: " .. (M.enabled() and "on" or "off")
      .. "; with the switch off the grant store is not read)"
  end
  if #args == 2 and verb == "grants" then return remuda.butler.guard_grants.list() end
  if #args == 3 and verb == "deny" and (args[3] == "on" or args[3] == "off") then
    local written, why = change(caller, "guard deny", args[3] == "on", M.set_deny)
    local warn = why
    if not written then return remuda.fail("guard deny switch not changed: " .. tostring(why), 1) end
    return "guard deny is now " .. args[3] .. ". " .. SWITCH_NOTE
      .. (warn and ("\n" .. warn) or "")
      .. (args[3] == "on" and " Needs `guard on`; recognised high-impact calls are denied." or "")
  end
  if #args == 3 and verb == "deny" and args[3] == "status" then
    return "guard deny: " .. (M.deny_enabled() and "on" or "off") .. " (guard: "
      .. (M.enabled() and "on" or "off") .. "; denial runs only when both are on)\n" .. SWITCH_NOTE
  end
  if #args == 2 and (verb == "on" or verb == "off") then
    local written, why = change(caller, "guard", verb == "on", M.set)
    local warn = why
    if not written then return remuda.fail("guard switch not changed: " .. tostring(why), 1) end
    return "guard is now " .. verb .. ". " .. SWITCH_NOTE
      .. (warn and ("\n" .. warn) or "")
      .. (verb == "on" and " It records calls; `guard deny on` also enables recognised denials." or "")
  end
  if #args == 2 and verb == "status" then
    return "guard: " .. (M.enabled() and "on" or "off") .. " (audit; deny: "
      .. (M.deny_enabled() and "on" or "off") .. ")\nlog: " .. tostring(M.log_path())
      .. "\n" .. SWITCH_NOTE .. unaudited_note()
  end
  if #args == 2 and verb == "stats" then return stats() end
  return remuda.fail("Usage: remuda butler guard on|off|status | approvals on|off|status | deny on|off|status | grants [on|off|status] | stats", 2)
end

-- Hook entries merged into the per-session settings file while the switch is on.
-- prompt_command keeps stdout for PermissionRequest decisions; pre_command keeps it
-- for PreToolUse denials. Both are optional so the settings bytes stay unchanged.
function M.hooks_json(command, json_quote, prompt_command, pre_command)
  local entry = '{"matcher":"*","hooks":[{"type":"command","command":' .. json_quote(command) .. "}]}"
  if pre_command then
    entry = '{"matcher":"*","hooks":[{"type":"command","command":' .. json_quote(pre_command) .. "}]}"
  end
  local prompt = entry
  if prompt_command then
    prompt = '{"matcher":"*","hooks":[{"type":"command","command":' .. json_quote(prompt_command)
      .. ',"timeout":330}]}'
  end
  return '"PreToolUse":[' .. entry .. '],"PermissionRequest":[' .. prompt .. "]"
end

remuda.butler = remuda.butler or {}
remuda.butler.guard_policy = M
return M
