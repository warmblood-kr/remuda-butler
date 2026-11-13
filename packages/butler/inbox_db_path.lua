-- Where core's remuda.db.open would keep a mod database, without opening it.
--
-- remuda.db.open creates a missing file. An inbox marked `sqlite-active` is
-- authoritative membership, so startup must test the existing file before that
-- call: opening a lost database would silently create an empty one. This
-- module only mirrors core's documented root
-- (<state>/remuda/db/MOD/NAME.db) and never touches the filesystem, so it can
-- be tested without a daemon. Keep it in step with core's db_lua.rs.
local M = {}

local function nonempty(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function component(value)
  return nonempty(value) and not value:find("[/\\]") and not value:find("..", 1, true)
end

local function join(separator, ...)
  local parts = {...}
  local value = parts[1]
  for index = 2, #parts do
    local last = value:sub(-1)
    if last ~= "/" and last ~= "\\" then value = value .. separator end
    value = value .. parts[index]
  end
  return value
end

-- POSIX: XDG_STATE_HOME, else $HOME/.local/state.
-- Windows: LOCALAPPDATA, else %USERPROFILE%/AppData/Local.
-- platform is system.platform(); env is the daemon's environment.
function M.database_file(platform, env, mod, name)
  if type(env) ~= "table" then return nil, "environment is unavailable" end
  if not component(mod) or not component(name) then
    return nil, "mod and database names must be plain path components"
  end
  local separator, base
  if platform == "windows" then
    separator = "\\"
    base = nonempty(env.LOCALAPPDATA)
    if not base then
      local profile = nonempty(env.USERPROFILE)
      if profile then base = join(separator, profile, "AppData", "Local") end
    end
    if not base then return nil, "LOCALAPPDATA and USERPROFILE are not set" end
  elseif platform == "posix" then
    separator = "/"
    base = nonempty(env.XDG_STATE_HOME)
    if not base then
      local home = nonempty(env.HOME)
      if not home then return nil, "XDG_STATE_HOME and HOME are not set" end
      base = join(separator, home, ".local", "state")
    end
  else
    return nil, "unknown platform: " .. tostring(platform)
  end
  return join(separator, base, "remuda", "db", mod, name .. ".db")
end

-- "present", "absent", or nil, reason when the filesystem cannot answer.
-- realpath answers from metadata and opens no descriptor (closing one could
-- drop a lock this process holds). It proves presence, not that the path is a
-- readable regular file. fallback_open is io.open for cores without realpath;
-- it cannot tell "denied" from "absent", so callers on such a core keep the
-- older fail-open marker behavior.
function M.path_state(fs, path, fallback_open)
  if type(fs) == "table" and type(fs.realpath) == "function" then
    local ok, resolved, reason = pcall(fs.realpath, path)
    if not ok then return nil, tostring(resolved) end
    if resolved ~= nil then return "present" end
    if type(reason) == "string" and reason:sub(1, 9) == "not_found" then
      return "absent"
    end
    return nil, tostring(reason or "filesystem check failed")
  end
  if type(fallback_open) == "function" then
    local ok, file = pcall(fallback_open, path, "r")
    if not ok then return nil, tostring(file) end
    if file then
      pcall(file.close, file)
      return "present"
    end
  end
  return "absent"
end

if type(remuda) == "table" then remuda._butler_inbox_db_path = M end
return M
