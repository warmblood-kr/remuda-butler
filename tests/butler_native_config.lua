-- Run from the repository root: luajit tests/butler_native_config.lua
-- Default-off selection for the native OpenCode bridge: config parsing,
-- capability probing and the per-launch decision. All seams injected.
local function literal(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = literal(item) end
    local keys = {}
    for key in pairs(value) do if type(key) ~= "number" then keys[#keys + 1] = key end end
    table.sort(keys)
    for _, key in ipairs(keys) do
      parts[#parts + 1] = string.format("[%q]=%s", key, literal(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

local codec = {
  encode = literal,
  decode = function(text) return assert(loadstring("return " .. text))() end,
}

remuda = {}
local module = dofile("packages/butler/native_config.lua")
local options = { json = codec }

-- 1. Config parsing is default-off and never silently enables.
local missing = module.read(nil, options)
assert(missing.enabled == false and missing.reason == "config_missing", "missing config is off")
local disabled = module.read(codec.encode({ version = 1, opencode = { enabled = false } }), options)
assert(disabled.enabled == false and disabled.reason == "disabled", "explicit off")
local enabled = module.read(codec.encode({ version = 1, opencode = { enabled = true } }), options)
assert(enabled.enabled == true and enabled.reason == "enabled", "explicit on")
local truthy = module.read(codec.encode({ version = 1, opencode = { enabled = "yes" } }), options)
assert(truthy.enabled == false, "only boolean true enables")
local bad = module.read("not json", options)
assert(bad.enabled == false and bad.reason:find("config_invalid", 1, true), "malformed is off")
local version = module.read(codec.encode({ version = 2, opencode = { enabled = true } }), options)
assert(version.enabled == false and version.reason == "config_version", "version is strict")
local string_version = module.read(codec.encode({ version = "1", opencode = { enabled = true } }), options)
assert(string_version.enabled == false and string_version.reason == "config_version",
  "a string version is not accepted")
local extra_top = module.read(codec.encode({ version = 1, extra = true,
  opencode = { enabled = true } }), options)
assert(extra_top.enabled == false and extra_top.reason:find("unknown_key", 1, true),
  "unknown top-level keys are refused")
local extra_inner = module.read(codec.encode({ version = 1,
  opencode = { enabled = true, extra = true } }), options)
assert(extra_inner.enabled == false and extra_inner.reason:find("unknown_key", 1, true),
  "unknown opencode keys are refused")
-- 1b. Each kind has its own strict default-off section.
local all = module.read(codec.encode({ version = 1, opencode = { enabled = true },
  codex = { enabled = true }, claude = { enabled = false } }), options)
assert(all.enabled == true and module.kind(all, "codex").enabled == true
  and module.kind(all, "claude").enabled == false
  and module.kind(all, "claude").reason == "disabled",
  "each kind is independent")
local section_missing = module.read(codec.encode({ version = 1,
  opencode = { enabled = true } }), options)
assert(module.kind(section_missing, "codex").enabled == false
  and module.kind(section_missing, "codex").reason == "config_missing_section",
  "a missing section stays unavailable")
local codex_extra = module.read(codec.encode({ version = 1,
  opencode = { enabled = true }, codex = { enabled = true, extra = true } }), options)
assert(codex_extra.enabled == true, "a bad Codex section does not disable OpenCode")
assert(module.kind(codex_extra, "codex").enabled == false
  and module.kind(codex_extra, "codex").reason:find("unknown_key", 1, true) ~= nil,
  "a bad Codex section is refused locally")

local nofile = module.load("cfg", { json = codec, read = function() return nil, "missing" end })
assert(nofile.enabled == false and nofile.reason == "config_missing", "missing file is off")
local unreadable = module.load("cfg", { json = codec, read = function() error("denied") end })
assert(unreadable.enabled == false and unreadable.reason:find("read_failed", 1, true),
  "unreadable config is off")

-- 2. Capability requires the exact protocol, a supported platform and the flag.
local ok_cap = { native_notice = true, protocol = "opencode-http-v1", platform = "macos" }
assert(module.parse_capability(codec.encode(ok_cap), options) == true, "valid capability")
assert(module.parse_capability(codec.encode({ native_notice = false,
  protocol = "opencode-http-v1", platform = "macos" }), options) == false,
  "native_notice false")
assert(module.parse_capability(codec.encode({ native_notice = true,
  protocol = "other", platform = "macos" }), options) == false, "protocol strict")
assert(module.parse_capability(codec.encode({ native_notice = true,
  protocol = "opencode-http-v1", platform = "windows" }), options) == false,
  "platform strict")

-- 3. Probe: exact argv, timeout cap, failures closed.
local seen
local good = { run = function(spec)
  seen = spec
  return { code = 0, stdout = codec.encode(ok_cap), stderr = "" }
end }
assert(module.probe({ json = codec, runner = good.run, remuda = "/bin/remuda" }) == true,
  "probe succeeds")
assert(seen.argv[1] == "/bin/remuda" and seen.argv[2] == "_opencode_tui"
  and seen.argv[3] == "--capability" and seen.timeout == 5, "probe argv/timeout")
local timed = { run = function() return { code = 0, timed_out = true, stdout = "" } end }
assert(module.probe({ json = codec, runner = timed.run }) == false, "timeout is off")
local exited = { run = function() return { code = 2, stdout = "" } end }
assert(module.probe({ json = codec, runner = exited.run }) == false, "nonzero exit is off")
local broken = { run = function() error("no binary") end }
assert(module.probe({ json = codec, runner = broken.run }) == false, "runner error is off")

print("ok - native config is default-off, strict and capability-gated")
