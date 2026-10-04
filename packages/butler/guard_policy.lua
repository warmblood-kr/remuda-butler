-- Guard slice 0: observe and audit. `remuda butler guard` is the target of the
-- Claude Code PreToolUse and PermissionRequest hooks. It classifies the action
-- with a deterministic classifier, appends one JSON line to the audit log, and
-- never returns a decision: it changes nothing an agent can do. It fails open.
-- The switch (`guard on|off|status`) is a marker file beside the log; off by default.
-- This is a record, not a boundary: a same-user agent can bypass or edit it.
local M = {}

local MAX_INPUT = 64 * 1024 -- larger hook payloads are logged by tool name only
local REDACT_PREFIX = 2048 -- redaction reads only this many bytes: its patterns are quadratic on long word runs
local SUMMARY_CAP = 200
local LOG_CAP = 1024 * 1024 -- the log rotates to LOG.1 past this size
local SCRIPT_HEAD = 120

-- Where the switch and the log live; remuda._butler_guard_dir lets a test redirect both.
local function dir()
  if type(remuda._butler_guard_dir) == "string" then return remuda._butler_guard_dir end
  local paths = remuda._butler_paths
  return paths and paths.data_home and (paths.data_home .. "/remuda/butler") or nil
end
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
local PROTECTED = { "/.ssh", "/.claude", "/.codex", "/.config/remuda", "/.local/share/remuda", "/remuda/butler" }
local HOOK_FILES = { "settings.json", "settings.local.json", "hooks.json", "config.toml", "managed-settings.json" }

local function expand(path, h)
  if type(path) ~= "string" then return "" end
  if h then path = path:gsub("^~", h):gsub("%$HOME", h):gsub("%${HOME}", h) end
  return path
end

local function protected(path)
  for _, p in ipairs(PROTECTED) do
    if (path .. "/"):find(p .. "/", 1, true) then return true end
  end
end

local function file_class(path, ctx)
  path = expand(path, ctx.home)
  local lower = path:lower()
  if lower:find("/%.claude/") or lower:find("/%.codex/") then
    local base = path:match("([^/]+)$") or ""
    for _, f in ipairs(HOOK_FILES) do if base == f then return "weaken" end end
  end
  if protected(path) then return "escape" end
  local cwd = ctx.cwd
  if path:sub(1, 1) == "/" and type(cwd) == "string" and cwd ~= "" then
    if path ~= cwd and path:sub(1, #cwd + 1) ~= cwd .. "/" then return "escape" end
  end
  return "other"
end

local WORD_STRIP = { sudo = true, env = true, command = true, nohup = true, time = true, exec = true, builtin = true }
local function words(segment)
  local out = {}
  for w in segment:gmatch("%S+") do out[#out + 1] = w:gsub("^[\"']+", ""):gsub("[\"']+$", "") end
  while out[1] and (WORD_STRIP[out[1]] or out[1]:find("^[%w_]+=")) do table.remove(out, 1) end
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

local function segment_class(w, text, ctx)
  local first = (w[1] or ""):match("([^/]+)$") or ""
  if text:find("--dangerously", 1, true) or text:find("--yolo", 1, true) or text:find("bypassPermissions", 1, true)
      or text:find("danger-full-access", 1, true) or text:find("--sandbox%s+full") then
    return "weaken"
  end
  local touches_protected = false
  for _, a in ipairs(w) do
    local p = expand((a:gsub("^[<>]+", "")), ctx.home)
    if p:find("/", 1, true) and protected(p) then touches_protected = true end
    local lp = p:lower()
    if lp:find("/%.claude/") or lp:find("/%.codex/") then
      local base = p:match("([^/]+)$") or ""
      for _, f in ipairs(HOOK_FILES) do
        if base == f and (WRITERS[first] or first == "sed" or text:find(">", 1, true)) then return "weaken" end
      end
    end
  end
  if first == "kill" or first == "pkill" or first == "killall" then return "control" end
  if first == "remuda" then
    if has(w, { stop = true, restart = true, kill = true }) then return "control" end
    for i, a in ipairs(w) do
      if a == "butler" then
        local verb = w[i + 1]
        if verb == "close" then return "control" end
        if verb == "guard" and w[i + 2] == "approvals" and (w[i + 3] == "on" or w[i + 3] == "off") then return "weaken" end
        if verb == "guard" and (w[i + 2] == "on" or w[i + 2] == "off") then return "weaken" end
        if IDENTITY[verb or ""] then return "identity" end
        if verb == "matrix" and (w[i + 2] == "join" or w[i + 2] == "leave" or w[i + 2] == "invite"
            or w[i + 2] == "mark-all") then
          return "identity"
        end
      end
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
  local segments = {}
  for seg in (command:gsub("&&", "\n"):gsub("||", "\n"):gsub("[;|&]", "\n")):gmatch("[^\n]+") do
    segments[#segments + 1] = seg
  end
  return segments
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

-- Append one JSON line to the audit log (0600, rotated). Returns true, or nil and why.
function M.append(record)
  local path = M.log_path()
  if not path then return nil, "no audit path" end
  local ok, why = pcall(function()
    pcall(remuda.mkdir, dir())
    local f = io.open(path, "r")
    local size = 0
    if f then size = f:seek("end") or 0; f:close() end
    if size >= LOG_CAP then os.remove(path .. ".1"); os.rename(path, path .. ".1"); f = nil end
    if not f then assert(remuda.fs.write_atomic(path, "", { private = true })) end
    local out = assert(io.open(path, "a"))
    local line = '{"time":' .. remuda.json.encode(os.date("!%Y-%m-%dT%H:%M:%SZ"))
    for _, key in ipairs({ "session", "kind", "event", "tool", "class", "summary" }) do
      line = line .. ',"' .. key .. '":' .. remuda.json.encode(tostring(record[key] or ""))
    end
    for _, key in ipairs({ "id", "hash" }) do
      if record[key] then line = line .. ',"' .. key .. '":' .. remuda.json.encode(tostring(record[key])) end
    end
    assert(out:write(line .. "}\n"))
    out:close()
  end)
  if not ok then return nil, tostring(why) end
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

-- `remuda butler guard [on|off|status]`. Without an argument it is the hook: it
-- always returns an empty answer (no decision) and exit 0.
function M.run(args, caller)
  local verb = args[2]
  if verb == nil then
    local reply
    local ok, err = pcall(function()
      if not M.enabled() then return end
      local record, hook_json = hook(caller)
      local appended, why = M.append(record)
      if not appended then note("guard audit not written: " .. tostring(why)) end
      local routing = remuda.butler.guard_approval
      if routing then reply = routing.maybe_request(record, hook_json) end
    end)
    if not ok then note("guard failed open: " .. tostring(err)) end
    return reply or ""
  end
  if #args == 3 and verb == "approvals" and (args[3] == "on" or args[3] == "off") then
    local written, why = M.set_approvals(args[3] == "on")
    if not written then return remuda.fail("guard approvals switch not changed: " .. tostring(why), 1) end
    return "guard approvals are now " .. args[3] .. ". " .. SWITCH_NOTE
      .. (args[3] == "on" and " Needs `guard on`; the owner answers Claude permission prompts in Matrix,"
        .. " and with no answer Claude shows its own prompt." or "")
  end
  if #args == 3 and verb == "approvals" and args[3] == "status" then
    return "guard approvals: " .. (M.approvals_enabled() and "on" or "off") .. " (guard: "
      .. (M.enabled() and "on" or "off") .. "; routing runs only when both are on)\n" .. SWITCH_NOTE
  end
  if #args == 2 and (verb == "on" or verb == "off") then
    local written, why = M.set(verb == "on")
    if not written then return remuda.fail("guard switch not changed: " .. tostring(why), 1) end
    return "guard is now " .. verb .. ". " .. SWITCH_NOTE
      .. (verb == "on" and " It records only; it never blocks or asks." or "")
  end
  if #args == 2 and verb == "status" then
    return "guard: " .. (M.enabled() and "on" or "off") .. " (audit only, never blocks)\nlog: " .. tostring(M.log_path())
      .. "\n" .. SWITCH_NOTE
  end
  return remuda.fail("Usage: remuda butler guard on|off|status | approvals on|off|status", 2)
end

-- Hook entries merged into the per-session settings file while the switch is on.
-- prompt_command (optional): the PermissionRequest command when approvals are on. It keeps
-- stdout, which carries the decision, and its timeout outlasts the approval wait.
function M.hooks_json(command, json_quote, prompt_command)
  local entry = '{"matcher":"*","hooks":[{"type":"command","command":' .. json_quote(command) .. "}]}"
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
