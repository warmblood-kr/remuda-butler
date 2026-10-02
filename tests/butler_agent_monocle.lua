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

local build = remuda._butler_agent_builders.monocle
local expected = { "monocle", "agent", "--workdir", "/work", "--session", "m1", "--auto-approve" }
local function eq(name, got, want)
  assert(#got == #want, name .. " has " .. #got .. " args; expected " .. #want)
  for i = 1, #want do assert(got[i] == want[i], name .. " arg " .. i .. ": " .. tostring(got[i])) end
end
eq("default argv", build({ dir = "/work", name = "m1" }), expected)
local modeled = { unpack(expected) }
modeled[#modeled + 1] = "--model"
modeled[#modeled + 1] = "gpt-5-mini"
eq("model argv", build({ dir = "/work", name = "m1", model = "gpt-5-mini" }), modeled)

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
remuda._butler_contribute = function() end
remuda.contribute = nil
dofile("packages/butler/agents_launch.lua")
remuda.new = function(name, argv) capture.name, capture.argv = name or "monocle-test", argv; return capture.name end
remuda.ls = function() return {} end
remuda._butler_choose({ "monocle" }, {
  name = "monocle-test",
  spec = function(kind) return { dir = "/work", name = "monocle-test", kind = kind } end,
  env = function() return {} end,
  skip_probe = true,
}, function(name, kind) capture.resolved_name, capture.resolved_kind = name, kind end)
assert(capture.resolved_kind == "monocle" and capture.resolved_name == "monocle-test",
  "launching monocle should resolve the monocle registry entry")
eq("resolved launch argv", capture.argv, {
  "monocle", "agent", "--workdir", "/work", "--session", "monocle-test", "--auto-approve",
})

-- With no contributed entries, the legacy launch fallback should still expose
-- the three built-in kinds in their normal order.
contributions = {}
local fallback = remuda._butler_configured_agent_order()
assert(table.concat(fallback, ",") == "claude,codex,monocle",
  "empty contribution fallback should include monocle after Claude and Codex")

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
