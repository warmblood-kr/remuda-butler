-- Run from the repository root: luajit tests/butler_native_launch.lua
-- Per-launch native decision glue: private binding dir/nonce, env, row join and
-- sticky disabled. All fs/random/config/clock seams injected; no daemon.
remuda = {}
local module = dofile("packages/butler/native_launch.lua")

local function fake(config, capability, random_ok, codex_help)
  local made = {}
  local calls = { probe = 0 }
  local config_module = {
    load = function(path, options) return config end,
    probe = function() calls.probe = calls.probe + 1
      return capability, capability and "capability_ok" or "capability_unsupported"
    end,
  }
  if config.kinds then
    config_module.kind = function(_, kind)
      return config.kinds[kind] or { enabled = false, reason = "config_missing_section" }
    end
  end
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
    runner = function() return { code = 0, stdout = codex_help or "{}", stderr = "" } end,
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

-- 1b. Codex new launch needs its own opt-in and the additive --binding
-- capability; Claude needs its own opt-in and never probes the wrapper.
local codex, codex_made = fake({ enabled = true, reason = "enabled",
  kinds = { codex = { enabled = true, reason = "enabled" } } }, true)
local codex_plan = codex.plan("lead", "codex")
assert(codex_plan.mode == "pty" and codex_plan.reason == "capability_unsupported",
  "an older Codex launcher stays PTY")
assert(#codex_made == 0, "an incapable Codex launch creates no binding")
local codex_on, codex_on_made = fake({ enabled = true, reason = "enabled",
  kinds = { codex = { enabled = true, reason = "enabled" } } }, true, nil,
  "--binding FILE")
local codex_native_plan = codex_on.plan("lead", "codex")
assert(codex_native_plan.mode == "native" and codex_native_plan.kind == "codex"
  and codex_native_plan.binding:find("/manifest.json", 1, true) ~= nil,
  "the capable Codex launcher selects its manifest binding")
assert(codex_on.env(codex_native_plan).REMUDA_BUTLER_BINDING_NONCE
  == codex_native_plan.nonce, "Codex gets only the nonce")
local codex_native = module.join(codex_native_plan,
  { id = "ses_codex", instance_id = "instance-3" }, "instance-3")
assert(codex_native.mode == "native" and codex_native.session_token == "ses_codex",
  "Codex uses the actual core row id, not an alias")
local claude_off, claude_off_made = fake({ enabled = true, reason = "enabled",
  kinds = { claude = { enabled = false, reason = "disabled" } } }, true)
local claude_off_plan = claude_off.plan("lead", "claude")
assert(claude_off_plan.mode == "pty" and claude_off_plan.reason == "disabled",
  "an unopted Claude launch stays PTY")
assert(#claude_off_made == 0, "an unopted Claude launch creates no binding")
local claude, claude_made, claude_calls = fake({ enabled = true, reason = "enabled",
  kinds = { claude = { enabled = true, reason = "enabled" } } }, true)
local claude_plan = claude.plan("lead", "claude")
assert(claude_plan.mode == "native" and claude_plan.kind == "claude",
  "the explicit Claude opt-in selects the channel binding")
assert(claude_calls.probe == 0, "Claude never probes the OpenCode wrapper")
assert(claude_plan.binding:find("/channel.json", 1, true) ~= nil,
  "the Claude helper binding is channel.json")
assert(claude_plan.name == "lead" and claude_plan.binding_dir ~= nil,
  "the channel entry knows its alias and private directory")
assert(next(claude.env(claude_plan)) == nil,
  "the Claude member env carries no channel secret or path")

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
  and native.instance == "instance-1" and native.path == plan.binding
  and native.session_token == "ses_abc",
  "join uses the live row id and instance")
local claude_native = module.join(claude_plan, { id = "ses_claude", instance_id = "instance-2" }, "instance-2")
assert(claude_native.mode == "native" and claude_native.session_token == "ses_claude"
  and claude_native.row_id == "ses_claude" and claude_plan.name == "lead"
  and claude_native.session_token ~= claude_plan.name,
  "Claude also uses the actual row id, never the matching alias")
-- 4b. The official id lookup yields; a replaced agent/module/decision makes
-- the join stale instead of installing a binding over a fresh one.
local old_row = { name = "lead", instance_id = "instance-1", alive = true }
local resolved = module.join(plan, old_row, "instance-1",
  function() return "core-id-lead" end, function() return true end)
assert(resolved.mode == "native" and resolved.row_id == "core-id-lead",
  "a verified lookup resolves the canonical id")
local stale = module.join(plan, old_row, "instance-1",
  function() return "core-id-lead" end, function() return false end)
assert(stale.mode == "stale" and stale.reason == "launch_replaced",
  "an unverified post-yield join is refused")
-- launch.lua calls the installed instance seam, so it must forward the
-- resolver and fence; dropping them would silently disable the old-daemon path.
local instance_resolved = on.join(plan, old_row, "instance-1",
  function() return "core-id-lead" end, function() return true end)
assert(instance_resolved.mode == "native" and instance_resolved.row_id == "core-id-lead",
  "the instance join forwards the identity resolver")
local instance_stale = on.join(plan, old_row, "instance-1",
  function() return "core-id-lead" end, function() return false end)
assert(instance_stale.mode == "stale" and instance_stale.reason == "launch_replaced",
  "the instance join forwards the stale fence")
local no_resolver = module.join(plan, old_row, "instance-1")
assert(no_resolver.mode == "disabled" and no_resolver.reason == "missing_row_identity",
  "no resolver and no id stays disabled")

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

-- 5b. The native Codex builder adds only --binding; off/old keeps the exact
-- previous argv.
remuda._butler_agent_builders, remuda._butler_telemetry_adapters = {}, {}
remuda._butler_agent_startup = remuda._butler_agent_startup or {}
dofile("packages/butler/agents/codex.lua")
local cargv = remuda._butler_agent_builders.codex({ name = "codexlead",
  telemetry = { status_path = "/tmp/codex-status" }, native = codex_native_plan })
assert(cargv[1] == "remuda" and cargv[2] == "_codex_tui" and cargv[3] == "--status"
  and cargv[4] == "/tmp/codex-status", "the exact old Codex prefix is preserved")
local bound = false
for index = 1, #cargv do
  if cargv[index] == "--binding" and cargv[index + 1] == codex_native_plan.binding then
    bound = true
  end
end
assert(bound and #cargv == 6, "a native Codex launch adds exactly --binding FILE")
local coff = remuda._butler_agent_builders.codex({ name = "codexlead",
  telemetry = { status_path = "/tmp/codex-status" } })
assert(#coff == 4 and not table.concat(coff, " "):find("--binding", 1, true),
  "an off/old Codex launch keeps the old argv")

-- 6. The wrapper argv for a bound launch; PTY uses the supported local TUI command.
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
assert(#pty_argv == 2 and pty_argv[1] == "opencode" and pty_argv[2] == "/work",
  "an unbound launch uses the exact OpenCode 1.19.5 local TUI argv")
local spaced = remuda._butler_agent_builders.opencode({ name = "lead", cwd = "/work with spaces" })
assert(#spaced == 2 and spaced[2] == "/work with spaces", "cwd stays one literal argument")
for _, spec in ipairs({ { name = "lead" }, { name = "lead", cwd = "" } }) do
  local bare = remuda._butler_agent_builders.opencode(spec)
  assert(#bare == 1 and bare[1] == "opencode", "missing/empty cwd adds no argument")
end

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
