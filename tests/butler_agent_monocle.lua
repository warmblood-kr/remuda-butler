-- RED tests for the minimal Monocle Butler agent kind. Run from the repo root:
--   luajit tests/butler_agent_monocle.lua

local remuda = {
  _butler_agent_builders = {},
  _butler_agent_startup = { claude = { modals = {} }, codex = { modals = {} } },
  _butler_telemetry_adapters = {},
  _butler_state = {},
  _butler_compaction_state = {},
  _butler_agent_support = {},
  _butler_test_mode = true,
  _butler_mail = {},
  butler = {},
}
_G.remuda = remuda

dofile("packages/butler/agents/monocle.lua")
dofile("packages/butler/agents/claudecode.lua")
dofile("packages/butler/agents/codex.lua")

local build = remuda._butler_agent_builders.monocle
local expected = { "monocle", "agent", "--workdir", "/work", "--session", "m1", "--auto-approve" }
local function eq(name, got, want)
  assert(#got == #want, name .. " has " .. #got .. " args; expected " .. #want)
  for i = 1, #want do assert(got[i] == want[i], name .. " arg " .. i .. ": " .. tostring(got[i])) end
end
eq("argv with cwd", build({ cwd = "/work", name = "m1" }), expected)
local modeled = { unpack(expected) }
modeled[#modeled + 1] = "--model"
modeled[#modeled + 1] = "gpt-5-mini"
eq("model argv", build({ cwd = "/work", name = "m1", model = "gpt-5-mini" }), modeled)
eq("argv without cwd", build({ name = "m1" }), {
  "monocle", "agent", "--session", "m1", "--auto-approve",
})
local valid_spec, invalid_spec_error = pcall(build, { cwd = "/work" })
assert(not valid_spec and tostring(invalid_spec_error):find("string name", 1, true),
  "Monocle builder must reject a non-spec table without a session name")

remuda._butler_agent_support.mcp_config_path = function() return "mcp.json" end
remuda._butler_agent_support.status_settings = function(path) return path .. ".settings" end
remuda._butler_claude_autocompact_supported = false
local claude_without_cwd = remuda._butler_agent_builders.claude({ name = "c", system_prompt = "p" })
local claude_with_cwd = remuda._butler_agent_builders.claude({ name = "c", cwd = "/work", system_prompt = "p" })
eq("Claude ignores cwd", claude_with_cwd, claude_without_cwd)
local codex_spec = { telemetry = { status_path = "S" } }
local codex_without_cwd = remuda._butler_agent_builders.codex(codex_spec)
local codex_with_cwd = remuda._butler_agent_builders.codex({ telemetry = codex_spec.telemetry, cwd = "/work" })
eq("Codex ignores cwd", codex_with_cwd, codex_without_cwd)

local startup = remuda._butler_agent_startup.monocle
local idle_screen = "banner\nanswer\n  \n❯ "
local working_screen = "banner\n⏵ bash {\"cmd\":\"sleep\"}"
assert(startup.ready(idle_screen), "Monocle is ready when the last non-empty screen line is ❯")
assert(not startup.ready(working_screen), "a tool line is not a ready prompt")
assert(startup.working(working_screen), "a non-ready final line means Monocle is working")
assert(not startup.working(idle_screen), "the ready prompt is not working")

-- Load the declarative built-in registry as the daemon does, but keep launch
-- resolution in-process so this test never needs the monocle executable.
remuda.schedule = function() return "schedule" end
remuda.cancel = function() end
remuda.exec = function() end
setmetatable(_G, { __index = { remuda = remuda } })
local module = dofile("packages/butler/init.lua")
local rows = module.contributes["butler.agent"]
local by_id = {}
for _, row in ipairs(rows) do by_id[row.id] = row end
assert(by_id.claude and by_id.codex and by_id.monocle, "built-in registry must include monocle")
assert(by_id.claude.order == 10 and by_id.codex.order == 20 and by_id.monocle.order == 30,
  "Monocle should follow Claude and Codex in the built-in order")
assert(by_id.monocle.executable == "monocle" and by_id.monocle.requires == "monocle",
  "Monocle registry row should resolve the monocle executable")
assert(by_id.monocle.automatic == false, "Monocle should be explicit-only in automatic launch order")
assert(by_id.monocle.ready(remuda, idle_screen) and not by_id.monocle.ready(remuda, working_screen),
  "Monocle registry ready callback should use its startup predicate")
assert(by_id.monocle.working(remuda, working_screen) and not by_id.monocle.working(remuda, idle_screen),
  "Monocle registry working callback should use its startup predicate")
assert(by_id.monocle.login[1] == "monocle login" and by_id.monocle.dialogs == nil,
  "Monocle registry should keep its login marker without dialog handling")

local contributions = rows
local capture = {}
remuda._butler_chooser_config = {
  bus = { agents = {} },
  call_callback = function(fn, ...) return pcall(fn, remuda, ...) end,
  numbered_option = function() end,
  bottom_screen_lines = function() return {} end,
  file_exists = function() return false end,
  contributions = function(point)
    if point == "butler.agent" then return contributions end
    return {}
  end,
  system = { find_command = function(name) return name end },
}
remuda._butler_prompt_delivery = {}
remuda._butler_system = remuda._butler_chooser_config.system
local fallback_rows = {}
remuda._butler_contribute = function(point, id, entry)
  if point == "butler.agent" then fallback_rows[id] = entry end
end
remuda.contribute = nil
dofile("packages/butler/agents_launch.lua")
assert(fallback_rows.monocle and fallback_rows.monocle.order == 30,
  "legacy launch fallback should register Monocle after Claude and Codex")
assert(fallback_rows.monocle.login[1] == "monocle login"
  and fallback_rows.monocle.working(nil, working_screen),
  "legacy Monocle registration should retain its login and working predicates")
remuda.new = function(name, argv) capture.name, capture.argv = name or "monocle-test", argv; return capture.name end
remuda.ls = function() return {} end
remuda._butler_choose({ "monocle" }, {
  name = "monocle-test",
  cwd = "/work",
  spec = function(kind) return { cwd = "/work", name = "monocle-test", kind = kind } end,
  env = function() return {} end,
  skip_probe = true,
}, function(name, kind) capture.resolved_name, capture.resolved_kind = name, kind end)
assert(capture.resolved_kind == "monocle" and capture.resolved_name == "monocle-test",
  "launching monocle should resolve the monocle registry entry")
eq("resolved launch argv", capture.argv, {
  "monocle", "agent", "--workdir", "/work", "--session", "monocle-test", "--auto-approve",
})

-- With no contributed entries, the legacy automatic launch fallback should
-- retain Claude and Codex without selecting explicit-only Monocle.
contributions = {}
local fallback = remuda._butler_configured_agent_order()
assert(table.concat(fallback, ",") == "claude,codex",
  "empty contribution fallback should keep monocle out of automatic launches")
contributions = rows
local configured = remuda._butler_configured_agent_order()
assert(table.concat(configured, ",") == "claude,codex",
  "the registered Monocle kind should not be auto-selected")

-- Compaction intentionally remains unsupported for this kind, and neither
-- telemetry nor the provider-specific quota report gains a Monocle row.
remuda._butler_system = {}
remuda._butler_compaction_run_config = {
  _butler_trace = function() end,
  registered_agent_kind = function() end,
  registered_agent_working = function() end,
  compaction_config = function() return {} end,
  compaction_mail_defers = function() return false end,
  compaction_mail_alert = function() end,
  bottom_screen_lines = function() return {} end,
  unknown_dialog_signature = function() end,
  read_claude_settings = function() end,
  statusline_model_matches = function() end,
  clear_legacy_restore_state = function() end,
  mail_root = nil,
}
remuda._butler_bus = { agents = { m1 = { kind = "monocle", parent = "butler" } } }
remuda._butler_compaction_has_session = function() return true end
remuda._butler_send = function() end
dofile("packages/butler/compaction_run.lua")
assert(remuda._butler_compaction_execute("m1") == "skipped_unsupported_kind",
  "Monocle compaction should follow the unsupported-kind skip path")
assert(remuda._butler_telemetry_adapters.monocle == nil, "Monocle should not have telemetry")
local quota = dofile("packages/butler/quota.lua")
local quota_text = quota.render({ at = 1790829600, monocle = { mode = "subscription" } })
assert(not quota_text:find("monocle:", 1, true), "quota should not add a Monocle row")

-- Exercise the real launch spec closure for Claude and Monocle. The fake
-- chooser captures its spec and completes as a failed attempt, so no process
-- is started and launch setup remains isolated from external CLIs.
local launch_specs = {}
local real_choose = remuda._butler_chooser.choose
remuda._butler_chooser.choose = function(candidates, opts, done)
  local kind = candidates[1]
  launch_specs[kind] = opts.spec(kind)
  done(nil, nil, { { kind = kind, reason = "not_found" } })
end
remuda.butler.launch_failure_lines = function() return { "not launched" } end
remuda._butler_launch_config = {
  bus = { agents = {}, identities = {}, identity_ids = {}, tokens = {}, unread_seeded = {} },
  valid_child_name = function(name) return name end,
  register_identity = function(name, kind) return { id = "id-" .. name, kind = kind } end,
  identity_record = function() end,
  next_token = function() return "token" end,
}
_G._butler_session_trace = function() end
dofile("packages/butler/launch.lua")
for _, kind in ipairs({ "claude", "monocle" }) do
  remuda._butler_launch_impl.launch_agent(kind, kind .. "-spec", "/work", nil, nil)
  assert(launch_specs[kind].cwd == "/work", kind .. " launch spec should carry the launch cwd")
end
remuda._butler_chooser.choose = real_choose
