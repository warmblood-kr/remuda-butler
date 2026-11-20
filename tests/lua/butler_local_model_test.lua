-- Pure, host-independent table tests for packages/butler/local_model.lua.
-- Run directly with `lua tests/lua/butler_local_model_test.lua`, or through
-- `tests/lua_tests.sh tests/lua/butler_local_model_test.lua` for the core harness.
local model = dofile("packages/butler/local_model.lua")

local suites = {}
local function suite(name, cases, check)
  suites[#suites + 1] = { name = name, cases = cases, check = check }
end

local function hex64(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

suite("catalog is pinned", {
  { "minicpm5-1b-q4", 688065920 },
  { "minicpm5-2b-q4", 1561318368 },
  { "minicpm5-2b-q8", 2679710688 },
}, function(case)
  local entry = assert(model.model(case[1]))
  assert(entry.bytes == case[2], case[1] .. " byte pin changed")
  assert(entry.license == "apache-2.0", case[1] .. " license changed")
  assert(hex64(entry.sha256), case[1] .. " sha256 is not 64 lowercase hex characters")
  assert(entry.file:match("%.gguf$"), case[1] .. " is not a gguf file")
  assert(entry.repo:match("^openbmb/"), case[1] .. " repo is not OpenBMB")
  assert(type(entry.revision) == "string" and #entry.revision == 40, case[1] .. " lacks a revision")
  -- A product default below the model maximum: 4k tokens is cheap, 128k is not.
  assert(entry.context == 4096, case[1] .. " default context changed")
end)

suite("catalog hashes are the LFS file hashes", {
  { "minicpm5-1b-q4", "81b64d05a23b17b34c475f42b3e72fbde62d4b92cc34541f7a8031d0752deafa" },
  { "minicpm5-2b-q4", "ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd" },
  { "minicpm5-2b-q8", "c5415f8989bf88a8288f1b55a3cc371af53c07b0faa220a63bd7a990cfaba078" },
}, function(case)
  local entry = assert(model.model(case[1]))
  assert(entry.sha256 == case[2], case[1] .. " pin is not the LFS object id")
end)

suite("2B carries its tokenizer as a pinned asset", {
  { "minicpm5-2b-q4", 9894271, "3e065a558a034185fe299917b398685c1facd0169a9eea1e629eb30c171fed81" },
}, function(case)
  local entry = assert(model.model(case[1]))
  local tokenizer = assert(entry.tokenizer, "2B tokenizer asset missing")
  assert(tokenizer.bytes == case[2], "tokenizer byte pin changed")
  assert(tokenizer.sha256 == case[3], "tokenizer hash pin changed")
  assert(tokenizer.revision == entry.revision, "tokenizer revision differs from the model revision")
  assert(tokenizer.file == "tokenizer.json", "tokenizer file name changed")
end)

suite("catalog copies cannot be edited in place", {
  { "size" },
}, function()
  local first = model.models()[1]
  first.bytes = 1
  assert(model.models()[1].bytes == 688065920, "models() leaked the catalog table")
end)

suite("unknown ids explain themselves", {
  { "nope" },
  { nil },
}, function(case)
  local entry, reason = model.model(case[1])
  assert(entry == nil and type(reason) == "string", "unknown id must return nil, reason")
end)

suite("runtime matrix answers only what is published", {
  { "darwin", "arm64", "metal", "mistralrs-metal-aarch64-apple-darwin.tar.gz" },
  { "linux", "x86_64", "cpu", "mistralrs-cpu-x86_64-unknown-linux-gnu.tar.gz" },
  { "linux", "aarch64", "cpu", "mistralrs-cpu-aarch64-unknown-linux-gnu.tar.gz" },
  { "windows", "x86_64", "cpu", "mistralrs-cpu-x86_64-pc-windows-msvc.zip" },
  { "darwin", "x86_64", "cpu", nil, "source_build" },
  { "windows", "arm64", "cpu", nil, "source_build" },
  { "linux", "riscv64", false },
}, function(case)
  local entry, reason = model.runtime(case[1], case[2])
  if case[3] == false then
    assert(entry == nil and reason:find("no runtime path", 1, true), "missing platform must be refused by name")
    return
  end
  assert(entry.accelerator == case[3], case[1] .. "/" .. case[2] .. " accelerator")
  if case[4] then
    assert(entry.asset == case[4], case[1] .. "/" .. case[2] .. " asset")
    assert(hex64(entry.sha256), case[1] .. "/" .. case[2] .. " runtime sha256")
    assert(entry.kind == "prebuilt", case[1] .. "/" .. case[2] .. " kind")
  else
    assert(entry.kind == case[5], case[1] .. "/" .. case[2] .. " kind: " .. tostring(entry.kind))
    assert(entry.asset == nil, "a source path carries no prebuilt asset")
  end
  assert(entry.release == "v0.9.5", case[1] .. "/" .. case[2] .. " release pin")
end)

suite("runtime rejects incomplete arguments", {
  { nil, "arm64" },
  { "linux", nil },
}, function(case)
  local entry, reason = model.runtime(case[1], case[2])
  assert(entry == nil and reason:find("required", 1, true), "missing argument must be refused")
end)

suite("opt-in is exactly true", {
  { true, true },
  { false, false },
  { nil, false },
  { "true", false },
  { 1, false },
  { {}, false },
}, function(case)
  local enabled, reason = model.gate(case[1])
  assert(enabled == case[2], "gate(" .. tostring(case[1]) .. ")")
  if not case[2] then assert(reason:find("off", 1, true), "a closed gate says so") end
end)

suite("cache root stays under the cache home", {
  { "/home/u", "/home/u/remuda/butler/models" },
  { "/home/u/", "/home/u/remuda/butler/models" },
  { "C:\\Users\\u", "C:\\Users\\u\\remuda\\butler\\models" },
  { "\\\\srv\\share\\u", "\\\\srv\\share\\u\\remuda\\butler\\models" },
  { "", false },
  { "relative/dir", false },
  { nil, false },
}, function(case)
  local root, reason = model.cache_root(case[1])
  if case[2] == false then
    assert(root == nil and type(reason) == "string", "a bad cache home is refused")
    return
  end
  assert(root == case[2], "cache root: " .. tostring(root))
end)

suite("artifact paths reject unsafe names", {
  { "/cache", "MiniCPM5-2B-Q4_K_M.gguf", "/cache/MiniCPM5-2B-Q4_K_M.gguf" },
  { "/cache/", "a.gguf", "/cache/a.gguf" },
  { "/cache", "../escape.gguf", false },
  { "/cache", "a/b.gguf", false },
  { "/cache", "a\\b.gguf", false },
  { "/cache", "a:b.gguf", false },          -- Windows alternate data stream
  { "/cache", "CON.gguf", false },          -- reserved device name
  { "/cache", "COM1", false },
  { "/cache", "trailing.gguf.", false },
  { "/cache", "trailing.gguf ", false },
  { "/cache", "nul\0.gguf", false },
  { "relative", "a.gguf", false },
  { "/ca\0che", "a.gguf", false },
  { "/cache", "", false },
}, function(case)
  local path, reason = model.artifact_path(case[1], { file = case[2] })
  if case[3] == false then
    assert(path == nil and type(reason) == "string", "unsafe artifact must be refused: " .. tostring(case[2]))
    return
  end
  assert(path == case[3], "artifact path: " .. tostring(path))
end)

suite("hash compare is exact and hex-only", {
  { "aa" .. string.rep("0", 62), "aa" .. string.rep("0", 62), true },
  { "AA" .. string.rep("0", 62), "aa" .. string.rep("0", 62), true },
  { "aa" .. string.rep("0", 62), "bb" .. string.rep("0", 62), false },
  { "aa" .. string.rep("0", 62), "aa" .. string.rep("0", 61), false },
  { "aa" .. string.rep("0", 62), nil, false },
  { "zz" .. string.rep("0", 62), "zz" .. string.rep("0", 62), false },
}, function(case)
  assert(model.same_hash(case[1], case[2]) == case[3], "same_hash " .. tostring(case[2]))
end)

local entry = assert(model.model("minicpm5-2b-q4"))
local good = entry.sha256

suite("evaluate decides without touching the filesystem", {
  { "verified", { present = true, bytes = 1561318368, sha256 = good, path = "/m/x.gguf" }, "artifact_verified" },
  { "truncated", { present = true, bytes = 1561318367, sha256 = good }, "truncated" },
  { "oversize", { present = true, bytes = 1561318369, sha256 = good }, "size_mismatch" },
  { "corrupt", { present = true, bytes = 1561318368, sha256 = string.rep("b", 64) }, "corrupt" },
  { "missing hash", { present = true, bytes = 1561318368 }, "verification_required" },
  { "huge free", { present = false, free_bytes = 9007199254740992 }, "unknown_space" },
  { "unreadable size", { present = true, bytes = "1.5GB", sha256 = good }, "unreadable" },
  { "missing + room", { present = false, free_bytes = 1561318368 + 512 * 1024 * 1024 }, "download" },
  { "missing + no room", { present = false, free_bytes = 100 }, "no_space" },
  { "missing + unknown space", { present = false }, "unknown_space" },
}, function(case)
  local decision = assert(model.evaluate(entry, case[2]))
  assert(decision.status == case[3], case[1] .. ": got " .. tostring(decision.status))
  if decision.status == "artifact_verified" then assert(decision.path == "/m/x.gguf", "verified keeps the path") end
  if decision.status == "verification_required" then
    assert(decision.needs_verification == true and decision.repair == nil,
      "an unread hash asks for verification, it does not delete the file")
  end
  if decision.status == "download" then assert(decision.bytes == 1561318368, "download names its bytes") end
  if decision.status == "no_space" then
    assert(decision.need_bytes == 1561318368 + 512 * 1024 * 1024, "no_space names the requirement")
  end
end)

suite("evaluate fail-closed on malformed facts", {
  { "facts string", "x" },
  { "negative free", { present = false, free_bytes = -1 } },
  { "fractional free", { present = false, free_bytes = 1.5 } },
  { "negative reserve", { present = false, free_bytes = 0, reserve_bytes = -2000000000 } },
  { "fractional reserve", { present = false, free_bytes = 0, reserve_bytes = 0.5 } },
  { "reserve false", { present = false, free_bytes = 0, reserve_bytes = false } },
  { "nan free", { present = false, free_bytes = 0 / 0 } },
}, function(case)
  local decision, reason = model.evaluate(entry, case[2])
  -- Either a named refusal, or a non-download status. Never a fetch.
  if decision then
    assert(decision.status ~= "download" and decision.status ~= "artifact_verified",
      case[1] .. " reached " .. tostring(decision.status))
  else
    assert(type(reason) == "string", case[1] .. " must explain its refusal")
  end
end)

suite("a malformed manifest cannot start a download", {
  { "no hash", { present = false, free_bytes = 4 * 1024 * 1024 * 1024 } },
  { "bad hash", { present = false, free_bytes = 4 * 1024 * 1024 * 1024 } },
}, function(case)
  local broken = { id = "broken", bytes = 1561318368 }
  if case[1] == "bad hash" then broken.sha256 = "not-a-hash" end
  local decision, reason = model.evaluate(broken, case[2])
  assert(decision == nil and reason:find("hash is invalid", 1, true), case[1] .. " must be refused")
end)

suite("evaluate honours an explicit reserve", {
  { 1561318368, 0, "download" },
  { 1561318367, 0, "no_space" },
}, function(case)
  local decision = assert(model.evaluate(entry, {
    present = false, free_bytes = case[1], reserve_bytes = case[2],
  }))
  assert(decision.status == case[3], "reserve boundary")
end)

suite("plan gates before any effect", {
  { nil, "disabled" },
  { false, "disabled" },
  { "true", "disabled" },
  { true, "download" },
}, function(case)
  local plan = assert(model.plan(case[1], entry, { present = false, free_bytes = 4 * 1024 * 1024 * 1024 }))
  assert(plan.status == case[2], "plan(" .. tostring(case[1]) .. "): " .. tostring(plan.status))
end)

suite("status never implies a running backend", {
  { "off", { enabled = false }, "off", "unknown" },
  { "source build", { enabled = true, platform = "darwin", arch = "x86_64" }, "source_build_required", "unknown" },
  { "unsupported", { enabled = true, platform = "freebsd", arch = "x86_64" }, "unsupported", "unknown" },
  { "no artifact", { enabled = true, platform = "linux", arch = "x86_64" }, "runtime_pinned", "unknown" },
  {
    "verified",
    { enabled = true, platform = "darwin", arch = "arm64", artifact = entry,
      facts = { present = true, bytes = 1561318368, sha256 = good, path = "/m/x.gguf" } },
    "runtime_pinned", "artifact_verified",
  },
  {
    "corrupt",
    { enabled = true, platform = "darwin", arch = "arm64", artifact = entry,
      facts = { present = true, bytes = 1561318368, sha256 = string.rep("c", 64) } },
    "runtime_pinned", "corrupt",
  },
  {
    "incomplete artifact",
    { enabled = true, platform = "linux", arch = "x86_64", artifact = { id = "x" } },
    "runtime_pinned", "invalid",
  },
}, function(case)
  local status = assert(model.status(case[2]))
  assert(status.backend == case[3], case[1] .. " backend: " .. tostring(status.backend))
  assert(status.artifact == case[4], case[1] .. " artifact: " .. tostring(status.artifact))
  assert(status.enabled == (case[2].enabled == true), case[1] .. " enabled flag")
end)

suite("logged urls lose query, fragment and userinfo", {
  { "https://cdn.example/m.gguf?sig=secret&x=1", "https://cdn.example/m.gguf" },
  { "https://cdn.example/m.gguf#frag", "https://cdn.example/m.gguf" },
  { "https://cdn.example/m.gguf", "https://cdn.example/m.gguf" },
  { "https://user:secret@cdn.example/m.gguf?sig=s", false },
  { "ftp://cdn.example/m.gguf", false },
  { "", false },
}, function(case)
  local url, reason = model.redact_url(case[1])
  if case[2] == false then
    assert(url == nil and type(reason) == "string", "unsafe url is refused: " .. tostring(case[1]))
    return
  end
  assert(url == case[2], "redacted url: " .. tostring(url))
end)

local function run_suite(item)
  for index, case in ipairs(item.cases) do
    local ok, reason = pcall(item.check, case)
    assert(ok, ("%s case %d (%s): %s"):format(item.name, index, tostring(case[1]), tostring(reason)))
  end
end

if type(T) == "table" and type(T.test) == "function" then
  local total = 0
  for _, item in ipairs(suites) do total = total + #item.cases end
  T.test("local model policy table cases (" .. total .. " cases)", function()
    for _, item in ipairs(suites) do run_suite(item) end
    T.expect(true, nil, ("ok - %d local model cases across %d tables"):format(total, #suites))
  end)
else
  local total = 0
  for _, item in ipairs(suites) do run_suite(item); total = total + #item.cases end
  print(("ok - %d local model cases in %d tables"):format(total, #suites))
end
