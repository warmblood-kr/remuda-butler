-- Run from the repository root: luajit tests/butler_native_launch.lua
-- Per-launch native decision glue: private binding dir/nonce, env, row join and
-- sticky disabled. All fs/random/config/clock seams injected; no daemon.
remuda = {}
local module = dofile("packages/butler/native_launch.lua")

local function fake(config, capability, random_ok)
  local made = {}
  local calls = { probe = 0 }
  local config_module = {
    load = function(path, options) return config end,
    probe = function() calls.probe = calls.probe + 1
      return capability, capability and "capability_ok" or "capability_unsupported"
    end,
  }
  local paths = { data_home = "/data",
    default_config_home = function() return "/cfg" end,
    valid_child_name = function(name) return name end }
  local fs = { mkdir_new = function(path)
    if random_ok == false and path:find("/bindings/", 1, true)
        and path:match("^/data/remuda/butler/bindings/[^/]+/[^/]+$") then
      return false, "leaf denied"
    end
    made[#made + 1] = path
    return true
  end }
  local instance = module.new({ paths = paths, config = config_module, fs = fs,
    json = {}, read = function() return nil, "missing" end,
    runner = function() return { code = 0, stdout = "{}" } end,
    random = function(n)
      if random_ok == false then error("no entropy") end
      return string.rep("\1", n)
    end })
  return instance, made, calls
end

-- 1. Default off and capability failure are PTY for a NEW launch.
local off, off_made = fake({ enabled = false, reason = "disabled" }, true)
local off_plan = off.plan("lead")
assert(off_plan.mode == "pty" and off_plan.reason == "disabled", "default off is PTY")
assert(#off_made == 0, "no binding is created when the feature is off")
local no_cap, no_cap_made = fake({ enabled = true, reason = "enabled" }, false)
assert(no_cap.plan("lead").mode == "pty", "missing capability is PTY")
assert(#no_cap_made == 0, "no binding is created without a capability")

-- 1b. Only OpenCode is eligible, and the kind check creates no directory.
local codex, codex_made = fake({ enabled = true, reason = "enabled" }, true)
local codex_plan = codex.plan("lead", "codex")
assert(codex_plan.mode == "pty" and codex_plan.reason == "kind_not_native",
  "a non-OpenCode launch stays PTY")
assert(#codex_made == 0, "a non-OpenCode launch creates no binding")

-- 1c. A core without the private-dir seam is PTY, never a crash.
local no_fs = module.new({
  paths = { data_home = "/data", default_config_home = function() return "/cfg" end,
    valid_child_name = function(name) return name end },
  config = { load = function() return { enabled = true, reason = "enabled" } end,
    probe = function() return true, "capability_ok" end },
  fs = nil, random = function(n) return string.rep("\1", n) end })
local no_fs_plan = no_fs.plan("lead")
assert(no_fs_plan.mode == "pty" and no_fs_plan.reason:find("binding_base_failed", 1, true),
  "a missing private-dir seam is a pre-launch PTY")

-- 2. Enabled + capable creates a private path chain and hex nonce.
local on, made, calls = fake({ enabled = true, reason = "enabled" }, true)
local plan = on.plan("lead")
assert(plan.mode == "native", "both gates select native")
local nonce_dir = "/data/remuda/butler/bindings/lead/" .. string.rep("01", 16)
assert(plan.binding == nonce_dir .. "/manifest.json",
  "the wrapper gets the manifest FILE path, not the directory")
assert(plan.nonce == string.rep("01", 16), "nonce is hex of the random bytes")
assert(made[1] == "/data/remuda/butler/bindings", "base dir created")
assert(made[2] == "/data/remuda/butler/bindings/lead", "per-name dir created")
assert(made[3] == nonce_dir, "the owned nonce dir is created")
assert(made[4] == nil, "the manifest file is left for the wrapper to create")
assert(on.env(plan).REMUDA_BUTLER_BINDING_NONCE == plan.nonce, "env carries only the nonce")
assert(on.env({ mode = "pty" }).REMUDA_BUTLER_BINDING_NONCE == nil, "PTY has no native env")
assert(calls.probe == 1, "capability is probed once")
on.plan("lead")
assert(calls.probe == 1, "capability probe is cached per boot")

-- 2b. Every byte is encoded, including 0x0A, so the nonce is always full hex.
local binary = module.new({
  paths = { data_home = "/data", default_config_home = function() return "/cfg" end,
    valid_child_name = function(name) return name end },
  config = { load = function() return { enabled = true, reason = "enabled" } end,
    probe = function() return true, "capability_ok" end },
  fs = { mkdir_new = function() return true end },
  random = function() return string.rep("\10", 16) end })
local binary_plan = binary.plan("lead")
assert(binary_plan.nonce == string.rep("0a", 16),
  "newline bytes are hex-encoded, not dropped")

-- 3. A failed binding create is a pre-launch PTY, never a partial native plan.
local failed = fake({ enabled = true, reason = "enabled" }, true, false)
local failed_plan = failed.plan("lead")
assert(failed_plan.mode == "pty" and failed_plan.reason:find("binding_failed", 1, true),
  "binding failure is reported for a new launch")

-- 4. Join requires the exact live row identity; missing identity disables and
-- never falls back to PTY.
local native = module.join(plan, { id = "ses_abc", instance_id = "instance-1" }, "instance-1")
assert(native.mode == "native" and native.row_id == "ses_abc"
  and native.instance == "instance-1" and native.path == plan.binding,
  "join uses the live row id and instance")
local no_id = module.join(plan, { instance_id = "instance-1" }, "instance-1")
assert(no_id.mode == "disabled" and no_id.reason == "missing_row_identity",
  "missing row id disables, never PTY")
local no_instance = module.join(plan, { id = "ses_abc" }, "instance-1")
assert(no_instance.mode == "disabled", "missing instance disables, never PTY")
assert(module.join({ mode = "pty" }, { id = "ses_abc", instance_id = "x" }, "x").mode == "pty",
  "a PTY plan stays PTY")
local no_live_instance = module.join(plan, { id = "ses_abc", instance_id = "instance-1" })
assert(no_live_instance.mode == "disabled" and no_live_instance.reason == "missing_instance_identity",
  "a missing returned instance disables, never PTY")
local crossed = module.join(plan, { id = "ses_abc", instance_id = "instance-2" }, "instance-1")
assert(crossed.mode == "disabled" and crossed.reason == "instance_mismatch",
  "a row from another instance disables, never PTY")

-- 5. disable() is sticky and keeps the binding metadata.
local agent = { native = native }
module.disable(agent, "server_gone")
assert(agent.native.mode == "disabled" and agent.native.reason == "server_gone"
  and agent.native.path == plan.binding, "disable keeps the binding but stops delivery")

-- 6. The wrapper argv for a bound launch; PTY keeps the old command.
remuda._butler_agent_builders, remuda._butler_agent_startup = {}, {}
remuda._butler_telemetry_adapters = {}
dofile("packages/butler/agents/opencode.lua")
local argv = remuda._butler_agent_builders.opencode({ name = "lead", cwd = "/work",
  native = plan })
assert(argv[1] == "remuda" and argv[2] == "_opencode_tui"
  and argv[3] == "--binding" and argv[4] == plan.binding
  and argv[5] == "--cwd" and argv[6] == "/work" and #argv == 6,
  "the native launch is the exact wrapper argv")
for _, value in ipairs(argv) do
  assert(not tostring(value):find("REMUDA_SESSION_ID", 1, true),
    "Butler never invents a session id")
end
local pty_argv = remuda._butler_agent_builders.opencode({ name = "lead", cwd = "/work" })
assert(pty_argv[1] == "opencode" and pty_argv[2] == "--standalone",
  "an unbound launch stays the PTY command")

-- 7. A relaunch reuses the private name dir (core reason `exists`) and still
-- gets a fresh nonce leaf.
local leaves = {}
local rel_existing = module.new({
  paths = { data_home = "/data", default_config_home = function() return "/cfg" end,
    valid_child_name = function(name) return name end },
  config = { load = function() return { enabled = true, reason = "enabled" } end,
    probe = function() return true, "capability_ok" end },
  fs = { mkdir_new = function(path)
    if path == "/data/remuda/butler/bindings"
        or path == "/data/remuda/butler/bindings/lead" then
      return false, "exists"
    end
    leaves[#leaves + 1] = path
    return true
  end },
  random = function(n) return string.rep("\2", n) end })
local relaunch = rel_existing.plan("lead")
assert(relaunch.mode == "native" and #leaves == 1
  and leaves[1] == "/data/remuda/butler/bindings/lead/" .. string.rep("02", 16)
  and relaunch.binding == leaves[1] .. "/manifest.json",
  "an existing private name dir does not block a relaunch")

print("ok - native launch decision is default-off, private and sticky")
