-- Butler paths: config/data homes, topic templates, Matrix credential paths,
-- the MCP config path, and the shell/JSON/path helpers built on them. main.lua
-- loads this before anything else resolves a path and rebinds the exported
-- locals.

-- `os.getenv` here reads the *daemon's own* environment, fixed forever at
-- whichever moment first birthed that daemon (see docs/install-butler.sh's
-- ceiling comment) -- so a butler-specific env var as the primary source
-- means anything else that races to auto-start a daemon first leaves no
-- later `exec butler` call able to inject a corrected value (that's the bug
-- this resolves). `HOME` (or `XDG_CONFIG_HOME`) is present in essentially
-- every process's environment regardless of what happened to birth the
-- daemon (the known exception: a systemd *system* unit with `User=` set but
-- no PAM session, or a process launched via `env -i`). Keep the resolved
-- paths even when files are absent so Matrix commands can explain how to
-- finish configuration. `REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG` remain
-- supported overrides, checked before the conventional XDG/HOME locations.
-- This mirrors install-butler.sh; scripts/check-butler-path-convention.lua
-- fails if the two defaults diverge.
local system = assert(remuda._butler_system)
local function available_home()
  local ok, home = pcall(system.home)
  if ok then return home end
end
local function default_config_home()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    return xdg
  end
  local home = available_home()
  return home and (home .. "/.config") or nil
end

local function default_data_home()
  local xdg = os.getenv("XDG_DATA_HOME")
  if xdg and xdg ~= "" then return xdg end
  local home = available_home()
  return home and (home .. "/.local/share") or nil
end

local function expand_home(path)
  if type(path) ~= "string" or path:sub(1, 1) ~= "~" then return path end
  local home = available_home()
  if not home then return nil end
  return path:gsub("^~", home)
end

local topic_config = {
  project_home = expand_home(os.getenv("REMUDA_BUTLER_PROJECT_HOME") or "~/projects"),
  templates = {},
}

remuda.butler = remuda.butler or {}
function remuda.butler.project_home(path)
  topic_config.project_home = expand_home(path)
end
function remuda.butler.template(name, setup)
  topic_config.templates[name] = setup
end

local data_home = default_data_home()
local butler_session_cwd = data_home and data_home .. "/remuda/butler/sessions/butler"
local mail_root = data_home and data_home .. "/remuda/butler/mail"
-- Resolve the path whether or not the file exists. Matrix commands report
-- missing credentials themselves, with both resolved paths and setup help.
local function resolve_path(override_env, filename, _what)
  local path = os.getenv(override_env)
  if not path or path == "" then
    local config_home = default_config_home()
    if not config_home then return nil end
    path = config_home .. "/remuda/butler/" .. filename
  end
  return path
end

local function file_exists(path)
  if not path then
    return false
  end
  -- Core lookup uses metadata; opening a FIFO here could block the daemon.
  local f = io.open(path, "r")
  if not f then
    return false
  end
  f:close()
  return true
end

local function load_topic_config()
  local path = os.getenv("REMUDA_BUTLER_TOPICS")
    or (default_config_home() and default_config_home() .. "/remuda/butler/topics.lua")
  if not path or not file_exists(path) then return end
  local configured = assert(loadfile(path))()
  if configured == nil then return end
  assert(type(configured) == "table", "Butler topics config must return a table")
  if configured.project_home then remuda.butler.project_home(configured.project_home) end
  for name, setup in pairs(configured.templates or {}) do remuda.butler.template(name, setup) end
end

-- Matrix is an optional Butler integration. Retain both resolved paths even
-- when absent so the CLI can explain what is missing. Start the relay only
-- when both credential files are readable; otherwise it stays inactive and
-- the CLI can guide the owner through setup.
local resolved_token_path = resolve_path("REMUDA_BUTLER_TOKEN", "token", "token file")
local resolved_config_path = resolve_path("REMUDA_BUTLER_CONFIG", "config", "config file")
remuda._butler_matrix_paths = {
  token_path = resolved_token_path,
  config_path = resolved_config_path,
}

local token_path, config_path = nil, nil
if file_exists(resolved_token_path) and file_exists(resolved_config_path) then
  token_path, config_path = resolved_token_path, resolved_config_path
  remuda._butler_matrix_config = { token_path = token_path, config_path = config_path }
else
  remuda._butler_matrix_config = nil
end
-- Matrix-enabled installs keep this beside their relay configuration. The
-- local-only mode has no configuration directory to rely on, so use a private
-- temporary filename for the same short-lived Claude MCP configuration.
local mcp_config_path = config_path and (config_path .. ".mcp.json") or (os.tmpname() .. ".mcp.json")
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\\"'\\\"'") .. "'"
end
local function valid_child_name(name, what)
  if type(name) ~= "string" or name == "" or name:sub(1, 1) == "."
      or name:find("/", 1, true) or name:find("\\", 1, true)
      or name:find("..", 1, true) or name:find("%c") then
    error((what or "name") .. " must be a single path component without separators, '..', or a leading dot", 0)
  end
  return name
end
local function create_fresh_directory(path)
  if not (remuda.fs and remuda.fs.mkdir_new) then return false end
  local parent = path:match("^(.*)/[^/]+$")
  if not parent then return false end
  remuda.mkdir(parent)
  local created, reason = remuda.fs.mkdir_new(path)
  return created == true
end
local function directory_is_under(path, root)
  if type(path) ~= "string" or type(root) ~= "string" or path == root then return false end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return path:sub(1, #prefix) == prefix
end
local function json_quote(s)
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"')
    :gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t') .. '"'
end
remuda._butler_paths = {
  topic_config = topic_config,
  data_home = data_home,
  butler_session_cwd = butler_session_cwd,
  mail_root = mail_root,
  file_exists = file_exists,
  load_topic_config = load_topic_config,
  token_path = token_path,
  config_path = config_path,
  -- Where the Matrix config is or would be, known even before Matrix is set up.
  resolved_config_path = resolved_config_path,
  mcp_config_path = mcp_config_path,
  shell_quote = shell_quote,
  valid_child_name = valid_child_name,
  create_fresh_directory = create_fresh_directory,
  directory_is_under = directory_is_under,
  json_quote = json_quote,
}
