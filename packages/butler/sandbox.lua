-- Codex sandbox profile: `writable` directories added to the workspace-write
-- roots and `sandbox == "full"` (no sandbox). A profile is {sandbox=, writable=}
-- and travels with the member row so a relaunch re-applies it.
local sandbox = {}
-- The core's caller as captured when caller_principal loaded (never a later remuda.caller); nil when unavailable.
-- A direct load without Butler's main has no principal: no caller, so no agent (the unavailable-caller policy).
local principal = remuda._butler_caller_principal
local core_caller = principal and principal.core_caller or function() return nil end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Directories as a list; a string is newline-separated (the MCP tool form).
local function dir_list(value)
  if value == nil then return {} end
  if type(value) == "string" then
    local list = {}
    for line in value:gmatch("[^\n]+") do list[#list + 1] = line end
    return list
  end
  if type(value) == "table" then return value end
  error("writable must be a list of absolute directories.\nNext: pass --writable /absolute/dir", 0)
end

local function is_directory(path)
  local f = io.open(path .. "/.", "r")
  if f then f:close() end
  return f ~= nil
end

-- A root that is /, $HOME or an ancestor of $HOME (after symlinks) is full access in
-- all but name; only `--sandbox full` may grant that.
local function too_broad(real, realpath)
  if real == "/" then return true end
  local home = os.getenv("HOME")
  if not home or home == "" then return true end
  home = type(realpath) == "function" and realpath(home) or home
  if not home then return true end
  return home == real or home:sub(1, #real + 1) == real .. "/"
end

-- Credential and Butler state directories a member must not be able to write:
-- a root that is, contains or lies inside one of them is refused.
local function touches(real, protected, realpath)
  for _, dir in ipairs(protected) do
    local p = type(realpath) == "function" and realpath(dir) or dir
    p = p or dir
    if real == p or real:sub(1, #p + 1) == p .. "/" or p:sub(1, #real + 1) == real .. "/" then return p end
  end
end

-- Directories under the home directory that hold credentials, plus those the caller names
-- (Butler's config, data and runtime directories).
function sandbox.protected(extra)
  local list = {}
  local home = os.getenv("HOME")
  if home and home ~= "" then
    for _, rel in ipairs({ ".ssh", ".aws", ".gnupg", ".codex", ".claude", ".config/remuda", ".local/share/remuda" }) do
      list[#list + 1] = home .. "/" .. rel
    end
  end
  for _, dir in ipairs(extra or {}) do
    if type(dir) == "string" and dir ~= "" then list[#list + 1] = dir end
  end
  return list
end

-- Returns nil for no profile, else a normalized profile; refuses with a Next: line.
function sandbox.normalize(kind, sandbox_mode, writable, realpath, protected)
  local dirs = dir_list(writable)
  if sandbox_mode ~= nil and sandbox_mode ~= "full" then
    error("--sandbox accepts only `full`.\nNext: remuda butler launch codex NAME --sandbox full", 0)
  end
  if #dirs == 0 and sandbox_mode == nil then return nil end
  if kind ~= "codex" then
    error("--writable and --sandbox apply to Codex members only.\nNext: launch with `codex`, e.g. remuda butler launch codex NAME --writable /abs/dir", 0)
  end
  local roots, seen = {}, {}
  for _, dir in ipairs(dirs) do
    if type(dir) ~= "string" or dir:sub(1, 1) ~= "/" or dir:find("%c") then
      error("--writable needs an absolute directory, got " .. tostring(dir) .. ".\nNext: pass an absolute path, e.g. --writable \"$PWD/dir\"", 0)
    end
    local real = type(realpath) == "function" and realpath(dir) or dir
    if not real or not is_directory(real) then
      error("--writable directory does not exist: " .. dir .. ".\nNext: create it first, or pass an existing absolute directory", 0)
    end
    if sandbox_mode ~= "full" and too_broad(real, realpath) then
      error("--writable " .. dir .. " covers your whole home or more.\nNext: name a subdirectory (for example --writable DIR/flutter-sdk); full access is granted only by a person at a terminal with --sandbox full", 0)
    end
    local hit = sandbox_mode ~= "full" and touches(real, sandbox.protected(protected), realpath)
    if hit then
      error("--writable " .. dir .. " reaches " .. hit .. ", which holds credentials or Butler state.\nNext: name a different directory; full access is granted only by a person at a terminal with --sandbox full", 0)
    end
    if not seen[real] then seen[real] = true; roots[#roots + 1] = real end
  end
  return { sandbox = sandbox_mode, writable = roots }
end

-- The `-c` pairs the Codex builder appends. json_quote is also a valid TOML basic string.
function sandbox.flags(profile, json_quote)
  local flags = {}
  if not profile then return flags end
  if profile.writable and #profile.writable > 0 then
    local quoted = {}
    for _, dir in ipairs(profile.writable) do quoted[#quoted + 1] = json_quote(dir) end
    flags[#flags + 1] = "-c"
    flags[#flags + 1] = "sandbox_workspace_write.writable_roots=[" .. table.concat(quoted, ",") .. "]"
  end
  if profile.sandbox == "full" then
    flags[#flags + 1] = "-c"
    flags[#flags + 1] = 'sandbox_mode="danger-full-access"'
  end
  return flags
end

-- The profile a live member row carries (nil when none), for display and relaunch.
function sandbox.of(agent)
  if agent and (agent.sandbox or agent.writable) then return { sandbox = agent.sandbox, writable = agent.writable } end
end

-- Short form for session listings.
function sandbox.summary(profile)
  if not profile then return nil end
  if profile.sandbox == "full" then return "sandbox=full" end
  if profile.writable and #profile.writable > 0 then return "writable=" .. #profile.writable end
end

-- One guidance line for the member's welcome mail and AGENTS.md.
function sandbox.guidance_line(profile)
  if not profile then return "" end
  if profile.sandbox == "full" then return "Sandbox: full access (no sandbox).\n" end
  if profile.writable and #profile.writable > 0 then
    return "Writable roots in addition to the workspace: " .. table.concat(profile.writable, ", ") .. "\n"
  end
  return ""
end

-- The command only the owner can run, for a refusal message.
function sandbox.owner_command(words, profile, cwd)
  local parts = { words }
  parts[#parts + 1] = "--sandbox full"
  for _, dir in ipairs(profile and profile.writable or {}) do parts[#parts + 1] = "--writable " .. shell_quote(dir) end
  if cwd then parts[#parts + 1] = "--cwd " .. shell_quote(cwd) end
  return table.concat(parts, " ")
end

function sandbox.refuse_full(command)
  error("--sandbox full is granted only by a person at a terminal, not by a Butler agent.\n"
    .. "Next: ask the owner to run: " .. command, 0)
end

-- Full access needs proof of a person at a terminal: the caller captured at load must be a table of
-- kind "outside". Anything else (a session, a service, unavailable or raising) is refused, so a core
-- without remuda.caller cannot grant full access to library/raw entry points (#474). The name is kept
-- for the three call sites; read it as "not proven a person".
function sandbox.caller_is_agent()
  local caller = core_caller()
  return not (type(caller) == "table" and caller.kind == "outside")
end

remuda._butler_sandbox = sandbox
