-- Pure, host-independent table tests for packages/butler/path.lua.
-- Run directly with `lua tests/lua/butler_path_test.lua`, or through
-- `tests/lua_tests.sh tests/lua/butler_path_test.lua` for the core harness.
local path = dofile("packages/butler/path.lua")

local suites = {}
local function suite(name, cases, check)
  suites[#suites + 1] = { name = name, cases = cases, check = check }
end

suite("absolute classification", {
  { "posix root", "/foo", "posix", true },
  { "posix double slash", "//srv/share", "posix", true },
  { "posix relative", "foo/bar", "posix", false },
  { "windows drive backslash", "C:\\foo", "windows", true },
  { "windows drive slash", "C:/foo", "windows", true },
  { "windows UNC", "\\\\srv\\share\\foo", "windows", true },
  { "windows verbatim drive", "\\\\?\\C:\\foo", "windows", true },
  { "windows verbatim UNC", "\\\\?\\UNC\\srv\\share\\foo", "windows", true },
  { "windows device namespace", "\\\\.\\PhysicalDrive0", "windows", true },
  { "drive relative is not absolute", "C:foo", "windows", false },
  { "rooted only is not absolute", "\\foo", "windows", false },
  { "single slash is rooted only", "/foo", "windows", false },
}, function(case)
  assert(path.is_absolute(case[2], case[3]) == case[4], case[1])
end)

suite("parse fields", {
  { "posix path", "/alpha/beta/", "posix", "/", true, { "alpha", "beta" }, true },
  { "posix relative", "alpha//beta", "posix", "", false, { "alpha", "beta" }, false },
  { "drive root", "C:\\alpha", "windows", "C:", true, { "alpha" }, false },
  { "drive relative", "C:alpha", "windows", "C:", false, { "alpha" }, false },
  { "rooted only", "\\alpha", "windows", "", true, { "alpha" }, false },
  { "UNC volume", "\\\\srv\\share\\alpha\\", "windows", "\\\\srv\\share", true, { "alpha" }, true },
  { "verbatim drive volume", "\\\\?\\C:\\alpha", "windows", "\\\\?\\C:", true, { "alpha" }, false },
  { "verbatim UNC volume", "\\\\?\\UNC\\srv\\share\\alpha", "windows", "\\\\?\\UNC\\srv\\share", true, { "alpha" }, false },
  { "verbatim UNC prefix case", "\\\\?\\unc\\srv\\share\\alpha", "windows", "\\\\?\\UNC\\srv\\share", true, { "alpha" }, false },
  { "device namespace", "\\\\.\\PhysicalDrive0", "windows", "\\\\.\\", true, { "PhysicalDrive0" }, false },
}, function(case)
  local parsed = path.parse(case[2], case[3])
  assert(parsed.prefix == case[4], case[1] .. " prefix: " .. parsed.prefix)
  assert(parsed.rooted == case[5], case[1] .. " rooted flag")
  assert(parsed.trailing_sep == case[7], case[1] .. " trailing separator")
  assert(#parsed.segments == #case[6], case[1] .. " segment count")
  for index, segment in ipairs(case[6]) do
    assert(parsed.segments[index] == segment, case[1] .. " segment " .. index)
  end
end)

suite("lexical normalize", {
  { "posix dot and parent", "/a/./b/../c", "posix", "/a/c" },
  { "posix rooted parent clamp", "/../../a", "posix", "/a" },
  { "posix relative parents stay", "../../a/../b", "posix", "../../b" },
  { "posix trailing intent", "a/../b/", "posix", "b/" },
  { "windows mixed separators", "C:/a\\.\\b\\..\\c", "windows", "C:\\a\\c" },
  { "windows rooted parent clamp", "C:\\..\\a", "windows", "C:\\a" },
  { "drive relative parents", "C:..\\a\\..\\b", "windows", "C:..\\b" },
  { "rooted only normalization", "\\a\\..\\b", "windows", "\\b" },
}, function(case)
  assert(path.normalize(case[2], case[3]) == case[4], case[1] .. ": " .. path.normalize(case[2], case[3]))
end)

suite("join", {
  { "posix relative child", "/a", "b/../c", "posix", "/a/c" },
  { "absolute child replaces base", "/a", "/b", "posix", "/b" },
  { "windows relative child", "C:\\a", "b\\..\\c", "windows", "C:\\a\\c" },
  { "windows absolute child replaces base", "C:\\a", "D:\\b", "windows", nil, true },
  { "windows rooted child replaces base", "C:\\a", "\\b", "windows", "\\b" },
  { "same drive absolute child", "C:\\a", "C:\\b", "windows", "C:\\b" },
}, function(case)
  local joined, reason = path.join(case[2], case[3], case[4])
  if case[6] then assert(joined == nil and reason, case[1] .. " must fail across volumes")
  else assert(joined == case[5], case[1] .. ": " .. tostring(joined)) end
end)

suite("relative across and within volumes", {
  { "posix siblings", "/a/b", "/a/c/d", "posix", "../c/d" },
  { "posix same path", "/a/./b", "/a/b", "posix", "." },
  { "windows component case", "C:\\Users\\Me", "c:\\users\\me\\Docs", "windows", "Docs" },
  { "windows different drive", "C:\\a", "D:\\a", "windows", nil, true },
  { "UNC different share", "\\\\srv\\one\\a", "\\\\srv\\two\\a", "windows", nil, true },
  { "drive relative same volume", "C:alpha\\beta", "C:alpha\\gamma", "windows", "..\\gamma" },
}, function(case)
  local relative, reason = path.relative(case[2], case[3], case[4])
  if case[6] then assert(relative == nil and reason, case[1] .. " must fail across volumes")
  else assert(relative == case[5], case[1] .. ": " .. tostring(relative)) end
end)

suite("split into volume, directory, and basename", {
  { "posix file", "/a/b.txt", "posix", "/", "/a/", "b.txt" },
  { "posix root", "/", "posix", "/", "/", "" },
  { "posix trailing directory", "/a/b/", "posix", "/", "/a/b/", "" },
  { "relative file", "a/b.txt", "posix", "", "a/", "b.txt" },
  { "windows file", "C:\\a\\b.txt", "windows", "C:", "C:\\a\\", "b.txt" },
  { "windows trailing directory", "C:\\a\\b\\", "windows", "C:", "C:\\a\\b\\", "" },
  { "UNC file", "\\\\srv\\share\\a.txt", "windows", "\\\\srv\\share", "\\\\srv\\share\\", "a.txt" },
  { "bare name", "name", "windows", "", "", "name" },
}, function(case)
  local volume, directory, base = path.split(case[2], case[3])
  assert(volume == case[4], case[1] .. " volume: " .. volume)
  assert(directory == case[5], case[1] .. " directory: " .. directory)
  assert(base == case[6], case[1] .. " base: " .. base)
end)

suite("component equality and containment", {
  { "posix child contained", "/foo/bar", "/foo/bar/baz", "posix", true },
  { "posix root contains itself", "/foo/bar", "/foo/bar", "posix", true },
  { "posix prefix trap rejected", "/foo/bar", "/foo/barbaz", "posix", false },
  { "posix case differs", "/Foo", "/foo/bar", "posix", false },
  { "windows case ignored", "C:\\Foo\\Bar", "c:\\foo\\bar\\baz", "windows", true },
  { "windows prefix trap rejected", "C:\\foo\\bar", "C:\\foo\\barbaz", "windows", false },
}, function(case)
  assert(path.contains(case[2], case[3], case[4]) == case[5], case[1])
end)

suite("same path", {
  { "posix lexical equivalence", "/a/./b/../c", "/a/c", "posix", true },
  { "posix case-sensitive", "/A", "/a", "posix", false },
  { "windows case-insensitive", "C:\\A\\B", "c:/a/b", "windows", true },
  { "windows different volume", "C:\\a", "D:\\a", "windows", false },
}, function(case)
  assert(path.same(case[2], case[3], case[4]) == case[5], case[1])
end)

suite("flavour separators and verbatim display", {
  { "posix separator", "posix", "/" },
  { "windows separator", "windows", "\\" },
}, function(case)
  assert(path.separator(case[2]) == case[3], case[1])
end)

local native_cases = {
  { "windows slash conversion", "C:/a/b", "windows", "C:\\a\\b" },
  { "posix slash conversion", "C:\\a\\b", "posix", "C:/a/b" },
}
suite("native separators", native_cases, function(case)
  assert(path.to_native(case[2], case[3]) == case[4], case[1])
end)

suite("simplify verbatim display path", {
  { "verbatim drive", "\\\\?\\C:\\long\\path", "C:\\long\\path" },
  { "verbatim UNC", "\\\\?\\UNC\\srv\\share\\path", "\\\\srv\\share\\path" },
  { "device namespace kept", "\\\\.\\PhysicalDrive0", "\\\\.\\PhysicalDrive0" },
  { "ordinary path kept", "C:\\ordinary\\path", "C:\\ordinary\\path" },
}, function(case)
  assert(path.simplify_verbatim(case[2]) == case[3], case[1])
end)

local function run_suite(item)
  for index, case in ipairs(item.cases) do
    local ok, reason = pcall(item.check, case)
    assert(ok, ("%s case %d (%s): %s"):format(item.name, index, case[1], tostring(reason)))
  end
end

if type(T) == "table" and type(T.test) == "function" then
  local total = 0
  for _, item in ipairs(suites) do total = total + #item.cases end
  T.test("path helper table cases (" .. total .. " cases)", function()
    for _, item in ipairs(suites) do run_suite(item) end
    T.expect(true, nil, ("ok - %d path helper cases across %d tables"):format(total, #suites))
  end)
else
  local total = 0
  for _, item in ipairs(suites) do run_suite(item); total = total + #item.cases end
  print(("ok - %d path helper cases in %d tables"):format(total, #suites))
end
