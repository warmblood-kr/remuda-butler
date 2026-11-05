-- Production glue for a NEW native OpenCode launch (phase 2, default off).
-- It owns only the private binding path/nonce and the per-launch decision; the
-- core wrapper/helper owns the server, manifest and validation, and Butler
-- never reads the manifest (it contains auth). All external seams are
-- injectable for unit tests.
local M = {}

local NONCE_BYTES = 16

local function hex(bytes)
  if type(bytes) ~= "string" or bytes == "" then return nil end
  local out = {}
  for index = 1, #bytes do
    out[index] = string.format("%02x", bytes:byte(index))
  end
  return table.concat(out)
end

local function default_read(path)
  local file, err = io.open(path, "r")
  if not file then
    if tostring(err or ""):lower():find("no such file", 1, true) then return nil, "missing" end
    return nil, tostring(err or "open_failed")
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function config_path(paths)
  local home = type(paths.default_config_home) == "function" and paths.default_config_home()
  if type(home) ~= "string" or home == "" then return nil end
  return home .. "/remuda/butler/native.json"
end

local function enabled(self)
  local path = config_path(self.paths)
  if not path then return { enabled = false, reason = "config_home_unavailable" } end
  return self.config.load(path, { json = self.json, read = self.read })
end

local function capability(self)
  local cached = self.capability_cache
  if cached then return cached.ok, cached.reason end
  local ok, why = self.config.probe({ json = self.json, runner = self.runner,
    remuda = self.remuda })
  self.capability_cache = { ok = ok, reason = why }
  return ok, why
end

function M.new(options)
  options = options or {}
  local self = {
    paths = assert(options.paths, "native launch paths are required"),
    config = assert(options.config, "native config module is required"),
    fs = type(options.fs) == "table" and options.fs or {},
    json = options.json, read = options.read or default_read,
    runner = options.runner, remuda = options.remuda or "remuda",
    random = options.random }
  self.config_path = function() return config_path(self.paths) end
  self.enabled = function() return enabled(self) end
  self.capability = function() return capability(self) end
  self.prepare = function(name) return M.prepare(self, name) end
  self.plan = function(name, kind) return M.plan(self, name, kind) end
  self.env = function(plan) return M.env(plan) end
  self.join = function(plan, row, instance) return M.join(plan, row, instance) end
  self.disable = function(agent, reason) return M.disable(agent, reason) end
  return self
end

local function valid_name(paths, name)
  if type(paths.valid_child_name) == "function" then
    local ok, err = pcall(paths.valid_child_name, name)
    if not ok then return false, tostring(err) end
  elseif type(name) ~= "string" or name == "" or name:find("/", 1, true)
      or name:find("..", 1, true) then
    return false, "invalid name"
  end
  return true
end

-- A private directory created by us earlier is fine on a relaunch; the core
-- reports that as `exists`. Anything else is a pre-launch failure.
local function ensure_private_dir(fs, path)
  if type(fs) ~= "table" or type(fs.mkdir_new) ~= "function" then
    return false, "mkdir_new_unavailable"
  end
  local ok, created, reason = pcall(fs.mkdir_new, path)
  if not ok then return false, tostring(created) end
  if created == true or reason == "exists" then return true end
  return false, tostring(reason or "mkdir_failed")
end

local function private_dirs(self, name)
  local data_home = self.paths.data_home
  if type(data_home) ~= "string" or data_home == "" or data_home:sub(1, 1) ~= "/" then
    return nil, "data_home_unavailable"
  end
  local base = data_home .. "/remuda/butler/bindings"
  local ok_base, base_err = ensure_private_dir(self.fs, base)
  if not ok_base then return nil, "binding_base_failed: " .. tostring(base_err) end
  local named = base .. "/" .. name
  local ok_dir, dir_err = ensure_private_dir(self.fs, named)
  if not ok_dir then return nil, "binding_parent_failed: " .. tostring(dir_err) end
  return named
end

local function fresh_nonce(self)
  local ok_random, bytes = pcall(self.random, NONCE_BYTES)
  if not ok_random or type(bytes) ~= "string" or bytes == "" then
    return nil, "nonce_unavailable"
  end
  local nonce = hex(bytes)
  if not nonce then return nil, "nonce_unavailable" end
  return nonce
end

-- Private nonce dir: mkdir_new for each level (0700), nonce hex of the core
-- CSPRNG. The wrapper gets `<dir>/manifest.json` and creates that file itself.
-- A failed create is a pre-launch condition, reported explicitly.
function M.prepare(self, name)
  local ok_name, name_err = valid_name(self.paths, name)
  if not ok_name then return nil, nil, name_err end
  local named, dir_err = private_dirs(self, name)
  if not named then return nil, nil, dir_err end
  local nonce, nonce_err = fresh_nonce(self)
  if not nonce then return nil, nil, nonce_err end
  local binding_dir = named .. "/" .. nonce
  local ok_leaf, created, leaf_reason = pcall(self.fs.mkdir_new, binding_dir)
  if not ok_leaf or created ~= true then
    return nil, nil, "binding_leaf_failed: " .. tostring(created or leaf_reason)
  end
  -- The wrapper contract takes the manifest FILE path and creates it in the
  -- parent: never hand it the owned nonce directory.
  return binding_dir .. "/manifest.json", nonce
end

-- One decision per NEW launch. Only a completely enabled+capable+prepared
-- OpenCode launch is native; anything else is an unbound PTY launch.
function M.plan(self, name, kind)
  if kind and kind ~= "opencode" then return { mode = "pty", reason = "kind_not_native" } end
  local config = self.enabled()
  if config.enabled ~= true then return { mode = "pty", reason = config.reason } end
  local capable, capability_reason = self.capability()
  if not capable then return { mode = "pty", reason = capability_reason } end
  local binding, nonce, why = self.prepare(name)
  if not binding then return { mode = "pty", reason = "binding_failed: " .. tostring(why) } end
  return { mode = "native", binding = binding, nonce = nonce }
end

-- The per-launch env carries only the nonce. The core assigns Session.id.
function M.env(plan)
  if not plan or plan.mode ~= "native" then return {} end
  return { REMUDA_BUTLER_BINDING_NONCE = plan.nonce }
end

-- Join the live row to the launch decision. Missing or mismatched identity
-- never falls back to PTY: the session stays bound/disabled so a later notice
-- can alert, and the binding still belongs to this exact instance.
function M.join(plan, row, instance)
  if not plan or plan.mode ~= "native" then return { mode = "pty" } end
  if type(instance) ~= "string" or instance == "" then
    return { mode = "disabled", reason = "missing_instance_identity",
      path = plan.binding, nonce = plan.nonce }
  end
  if type(row) ~= "table" or type(row.id) ~= "string" or row.id == ""
      or type(row.instance_id) ~= "string" or row.instance_id == "" then
    return { mode = "disabled", reason = "missing_row_identity",
      path = plan.binding, nonce = plan.nonce }
  end
  if row.instance_id ~= instance then
    return { mode = "disabled", reason = "instance_mismatch",
      path = plan.binding, nonce = plan.nonce }
  end
  return { mode = "native", path = plan.binding, nonce = plan.nonce,
    row_id = row.id, instance = instance }
end

function M.disable(agent, reason)
  if type(agent) ~= "table" or type(agent.native) ~= "table" then return end
  agent.native.mode = "disabled"
  agent.native.reason = tostring(reason or "disabled")
end

function M.install(options)
  local instance = M.new(options)
  remuda._butler_native_launch = instance
  remuda.butler = remuda.butler or {}
  remuda.butler.native_launch = instance
  return instance
end

remuda.butler = remuda.butler or {}
remuda.butler.native_launch = M
return M
