-- Local model artifacts: a pinned catalog, cache placement, the opt-in gate and
-- the integrity policy for an optional on-device model (openbmb/MiniCPM5 via a
-- mistral.rs-style server). Weights are never shipped in the install; they are
-- downloaded once into the OS cache and verified before first use.
--
-- Pure: the caller reads the facts (file size, hash, free disk) and does the
-- I/O. Every function returns `value` or `nil, reason` so a caller can print a
-- single honest line instead of guessing. See docs/local-model.md.
--
-- `artifact_verified` means only "these bytes match the pin". It does not mean
-- a server is running, that inference is authorized, or that the model is good.

local local_model = {}

local MIB = 1024 * 1024
local DEFAULT_RESERVE = 512 * MIB
local MAX_SAFE_INTEGER = 9007199254740991 -- Lua numbers are exact only below 2^53

-- Pins are metadata reviewed on 2026-11-05, not downloaded-byte verification.
-- `sha256` is the LFS object id (the file hash), NOT the Xet hash in an HTTP
-- ETag; the two differ and a verifier using the ETag value would reject a good
-- file. `revision` is the immutable repository commit.
local MODELS = {
  {
    id = "minicpm5-1b-q4",
    repo = "openbmb/MiniCPM5-1B-GGUF",
    revision = "3d55fac80935ae6456986ad2384b5cbcc4d6c948",
    file = "MiniCPM5-1B-Q4_K_M.gguf",
    bytes = 688065920,
    sha256 = "81b64d05a23b17b34c475f42b3e72fbde62d4b92cc34541f7a8031d0752deafa",
    license = "apache-2.0",
    estimated_ram_mib = 1600,
    context = 4096,
  },
  {
    id = "minicpm5-2b-q4",
    repo = "openbmb/MiniCPM5-2B-GGUF",
    revision = "2079a22f3beaa4e306449978533478fe0522f4b3",
    file = "MiniCPM5-2B-Q4_K_M.gguf",
    bytes = 1561318368,
    sha256 = "ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd",
    license = "apache-2.0",
    estimated_ram_mib = 3200,
    context = 4096,
    max_context = 131072,
    -- mistral.rs rejects the standalone GGUF BPE pre-tokenizer; the agent
    -- runtime must stage this file beside the weights, verified the same way.
    tokenizer = {
      repo = "openbmb/MiniCPM5-2B",
      revision = "2079a22f3beaa4e306449978533478fe0522f4b3",
      file = "tokenizer.json",
      bytes = 9894271,
      sha256 = "3e065a558a034185fe299917b398685c1facd0169a9eea1e629eb30c171fed81",
      license = "apache-2.0",
    },
  },
  {
    id = "minicpm5-2b-q8",
    repo = "openbmb/MiniCPM5-2B-GGUF",
    revision = "2079a22f3beaa4e306449978533478fe0522f4b3",
    file = "MiniCPM5-2B-Q8_0.gguf",
    bytes = 2679710688,
    sha256 = "c5415f8989bf88a8288f1b55a3cc371af53c07b0faa220a63bd7a990cfaba078",
    license = "apache-2.0",
    estimated_ram_mib = 4400,
    context = 4096,
    max_context = 131072,
  },
}

-- How each platform reaches a runtime (mistral.rs v0.9.5, MIT): a published
-- asset where one exists, a documented source build otherwise, and an explicit
-- "no path" only when neither exists. This is coverage policy, not proof that a
-- binary runs here; GitHub's asset digest is the SHA-256 of the file. A source
-- build is never started silently during a Butler start.
--
-- MEASURED 2026-11-05 (macOS arm64): this 0.9.5 Metal binary loads
-- MiniCPM5-1B-Q4_K_M but the first completion fails with a shape mismatch, so
-- mistral.rs is not the default for MiniCPM5 yet. llama.cpp b12121 serves the
-- same file; see docs/local-model.md. Keeping these pins is still useful: they
-- are the assets a future fixed release or a different model would use.
local RUNTIME_RELEASE = "v0.9.5"
local RUNTIMES = {
  ["darwin/arm64"] = {
    asset = "mistralrs-metal-aarch64-apple-darwin.tar.gz",
    bytes = 50526033,
    sha256 = "dcfb2e6c43692e391e3bfa8a0f1e3140447a492d5af0ae00731476eb67641815",
    accelerator = "metal",
  },
  ["linux/x86_64"] = {
    asset = "mistralrs-cpu-x86_64-unknown-linux-gnu.tar.gz",
    bytes = 36346799,
    sha256 = "9b542da90b6541abd599ff275e3246fa6e144885bdcd67d1f0aefdba1729f7b5",
    accelerator = "cpu",
  },
  ["linux/aarch64"] = {
    asset = "mistralrs-cpu-aarch64-unknown-linux-gnu.tar.gz",
    bytes = 36234428,
    sha256 = "760f10bf201a1b26ce6b1caa6cd9f09b091f7ba3252af40493975ab50312ec1a",
    accelerator = "cpu",
  },
  ["windows/x86_64"] = {
    asset = "mistralrs-cpu-x86_64-pc-windows-msvc.zip",
    bytes = 34199612,
    sha256 = "64d567c299a5c97ef265aa0362649aafb968af47706810df640f74fe8ea4702a",
    accelerator = "cpu",
  },
  -- No published asset, but the upstream source build is documented:
  -- Intel mac uses the Accelerate (or MKL) feature and Xcode command line
  -- tools; Windows arm64 is a plain CPU build with VS Build Tools. Both are
  -- unverified here and stay visible as "source_build", not "unsupported".
  ["darwin/x86_64"] = { kind = "source_build", features = { "accelerate" }, accelerator = "cpu" },
  ["windows/arm64"] = { kind = "source_build", features = {}, accelerator = "cpu" },
}

local WINDOWS_RESERVED = {
  CON = true, PRN = true, AUX = true, NUL = true,
  COM1 = true, COM2 = true, COM3 = true, COM4 = true, COM5 = true,
  COM6 = true, COM7 = true, COM8 = true, COM9 = true,
  LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true, LPT5 = true,
  LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
}

local function copy(value)
  local out = {}
  for key, item in pairs(value or {}) do out[key] = item end
  return out
end

-- A byte count or size from the caller: finite, non-negative, whole.
local function is_size(value)
  return type(value) == "number" and value == value and value >= 0
    and value <= MAX_SAFE_INTEGER and value % 1 == 0
end

local function join_path(root, name)
  local trimmed = root:gsub("[/\\]+$", "")
  local sep = (root:match("^%a:[/\\]") or root:match("^\\\\")) and "\\" or "/"
  return trimmed .. sep .. name
end

local function is_absolute(path)
  if type(path) ~= "string" or path == "" then return false end
  if path:find("[%z\1-\31]") then return false end -- NUL/control: native validation later
  if path:sub(1, 1) == "/" then return true end
  if path:match("^%a:[/\\]") then return true end
  return path:match("^\\\\[%w%._%-]+\\[%w%._%-]+") ~= nil -- UNC: \\server\share
end

-- A plain file name: ASCII, no separator, no colon (Windows ADS), no control
-- character, no trailing dot or space, no reserved device name. Canonicalization
-- and symlink protection stay in the native I/O layer.
local function is_plain_filename(name)
  if type(name) ~= "string" or name == "" or #name > 128 then return false end
  if not name:match("^[A-Za-z0-9][A-Za-z0-9._%-]*$") then return false end
  if name:sub(-1) == "." or name:sub(-1) == " " then return false end
  local stem = name:match("^([^.]+)") or name
  return WINDOWS_RESERVED[stem:upper()] == nil
end

-- `models` lists the pinned artifacts smallest first; callers print them.
function local_model.models()
  local out = {}
  for index, entry in ipairs(MODELS) do out[index] = copy(entry) end
  return out
end

function local_model.model(id)
  for _, entry in ipairs(MODELS) do
    if entry.id == id then return copy(entry) end
  end
  return nil, "unknown model '" .. tostring(id) .. "'"
end

-- `runtime` answers with the one prebuilt binary for this machine, or why not.
-- The caller must normalize arm64/aarch64 at its own boundary, not here.
function local_model.runtime(platform, arch)
  if type(platform) ~= "string" or type(arch) ~= "string" then
    return nil, "platform and arch are required"
  end
  local entry = RUNTIMES[platform .. "/" .. arch]
  if not entry then
    return nil, "no runtime path for " .. platform .. "/" .. arch
  end
  local out = copy(entry)
  out.kind = out.kind or "prebuilt"
  out.release = RUNTIME_RELEASE
  return out
end

-- Opt-in is exactly `true`; a string, a number or a missing file never enables
-- a download or a listening server.
function local_model.gate(configured)
  if configured == true then return true end
  return false, "local model is off; set local_model = true to enable it"
end

-- `cache_home` is the OS cache root the caller resolved (XDG_CACHE_HOME,
-- ~/Library/Caches, %LOCALAPPDATA%); consent and config live elsewhere because
-- a cache directory may be deleted by the system.
function local_model.cache_root(cache_home)
  if not is_absolute(cache_home) then
    return nil, "cache home must be an absolute path"
  end
  local models = join_path(join_path(join_path(cache_home, "remuda"), "butler"), "models")
  return models
end

function local_model.artifact_path(root, entry)
  if not is_absolute(root) then return nil, "cache root must be an absolute path" end
  if type(entry) ~= "table" then return nil, "artifact is unknown" end
  if not is_plain_filename(entry.file) then return nil, "artifact file name is not allowed" end
  return join_path(root, entry.file)
end

-- An exact, hex-only compare; a 64-character non-hex string is not a hash.
local function is_hex64(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-fA-F]+$") ~= nil
end

function local_model.same_hash(expected, observed)
  if not is_hex64(expected) or not is_hex64(observed) then return false end
  return expected:lower() == observed:lower()
end

local function hash_state(entry, facts)
  if not facts.present then return "missing" end
  if not is_size(facts.bytes) then return "unreadable" end
  if facts.bytes ~= entry.bytes then
    return facts.bytes < entry.bytes and "truncated" or "size_mismatch"
  end
  if type(facts.sha256) ~= "string" or facts.sha256 == "" then
    return "verification_required"
  end
  if not local_model.same_hash(entry.sha256, facts.sha256) then return "corrupt" end
  return "artifact_verified"
end

-- `evaluate` is the whole artifact decision, without touching the filesystem:
-- facts = { present, bytes, sha256, free_bytes, reserve_bytes }. It does not
-- consult the opt-in gate; `plan` does that before any caller may act.
function local_model.evaluate(entry, facts)
  if type(facts) ~= "table" then return nil, "facts must be a table" end
  if type(entry) ~= "table" or not is_size(entry.bytes) then
    return nil, "artifact size is invalid"
  end
  local state = hash_state(entry, facts)
  if state == "artifact_verified" then return { status = state, path = facts.path } end
  if state == "verification_required" then
    return { status = state, needs_verification = true, reason = "cached size matches; hash unread" }
  end
  if state ~= "missing" then
    return { status = state, repair = true, reason = "cached file failed verification" }
  end
  if not is_hex64(entry.sha256) then return nil, "artifact hash is invalid" end
  local reserve = DEFAULT_RESERVE
  if facts.reserve_bytes ~= nil then reserve = facts.reserve_bytes end
  if not is_size(reserve) then return nil, "reserve is invalid" end
  if entry.bytes + reserve > MAX_SAFE_INTEGER then return nil, "size requirement overflows" end
  if not is_size(facts.free_bytes) then
    return { status = "unknown_space", reason = "free disk space is unknown" }
  end
  if facts.free_bytes < entry.bytes + reserve then
    return { status = "no_space", need_bytes = entry.bytes + reserve, free_bytes = facts.free_bytes }
  end
  return { status = "download", bytes = entry.bytes }
end

-- `plan` is the only function a downloading caller may act on: the gate comes
-- first, so a disabled Butler cannot fetch or repair anything.
function local_model.plan(enabled, entry, facts)
  local open = local_model.gate(enabled)
  if not open then return { status = "disabled", reason = "local model is off" } end
  return local_model.evaluate(entry, facts)
end

-- `status` is what doctor prints: policy, pinned runtime and artifact state are
-- three separate answers. "Enabled" never implies a server is running, and an
-- unsupported platform says so instead of falling back to a source build.
function local_model.status(options)
  options = options or {}
  local out = { enabled = local_model.gate(options.enabled), backend = "off", artifact = "unknown" }
  if not out.enabled then
    out.detail = "local model is off"
    return out
  end
  local runtime, reason = local_model.runtime(options.platform, options.arch)
  if not runtime then
    out.backend, out.detail = "unsupported", reason
    return out
  end
  out.backend = runtime.kind == "prebuilt" and "runtime_pinned" or "source_build_required"
  out.accelerator = runtime.accelerator
  if options.artifact == nil then
    out.detail = "no artifact selected"
    return out
  end
  if type(options.artifact) ~= "table"
      or type(options.artifact.sha256) ~= "string"
      or not is_size(options.artifact.bytes) then
    out.artifact = "invalid"
    out.detail = "artifact entry is incomplete"
    return out
  end
  local decision, why = local_model.evaluate(options.artifact, options.facts)
  if not decision then
    out.artifact, out.detail = "invalid", why
    return out
  end
  out.artifact = decision.status
  out.detail = decision.reason
  return out
end

-- A URL shown in logs or mail loses its query string (signed CDN links carry
-- credentials there). A URL with userinfo is refused outright: the secret sits
-- before the host and would survive any query stripping. Callers should log an
-- artifact id, not a URL, wherever they can.
function local_model.redact_url(url)
  if type(url) ~= "string" or url == "" then return nil, "url is required" end
  if not url:match("^https?://") then return nil, "url must be http or https" end
  local authority = url:match("^https?://([^/?#]+)")
  if authority and authority:find("@", 1, true) then
    return nil, "url must not carry userinfo"
  end
  return (url:gsub("[?#].*$", ""))
end

if type(remuda) == "table" then remuda._butler_local_model = local_model end
return local_model
