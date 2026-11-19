-- Pure unit tests for the effective-name resolution and its durable record.
-- Run from the repository root: luajit tests/effective_name.lua
local path = "packages/butler/effective_name.lua"
local chunk = assert(loadfile(path))
local M = chunk()

local passed = 0
local function ok(condition, message)
  if not condition then error("FAIL: " .. message, 2) end
  passed = passed + 1
end
local function eq(actual, expected, message)
  if actual ~= expected then
    error("FAIL: " .. message .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
  passed = passed + 1
end

-- Validation: conservative session/control name.
ok(M.valid("butler"), "default name is valid")
ok(M.valid("butler-alt_2.x"), "dots, dashes and underscores are valid")
ok(not M.valid(""), "empty is invalid")
ok(not M.valid(" butler"), "leading space is invalid")
ok(not M.valid("-butler"), "leading dash is invalid")
ok(not M.valid("butler/alt"), "slash is invalid")
ok(not M.valid("butler\talt"), "control character is invalid")
ok(not M.valid(string.rep("b", 65)), "longer than 64 is invalid")
ok(not M.valid(nil), "nil is invalid")
ok(not M.valid(7), "non-string is invalid")

-- Resolution order: explicit override, then env, then our record, then default.
eq(M.resolve(nil, nil, nil), "butler", "no input uses the stable default")
local name, source = M.resolve(nil, nil, nil)
eq(source, "default", "no input reports default")
name, source = M.resolve("butler-alt", nil, "butler-old")
eq(name, "butler-alt", "override wins over the record")
eq(source, "override", "override source")
name, source = M.resolve("butler-alt", "butler-env", nil)
eq(name, "butler-alt", "override wins over env")
eq(source, "override", "override source over env")
name, source = M.resolve(nil, "butler-env", "butler-old")
eq(name, "butler-env", "env wins over the record")
eq(source, "env", "env source")
name, source = M.resolve(nil, nil, "butler-old")
eq(name, "butler-old", "the record survives a restart without explicit config")
eq(source, "recorded", "recorded source")

-- An invalid EXPLICIT value must fail closed, never silently fall back.
name, source = M.resolve("bad name", nil, "butler-old")
eq(name, nil, "invalid override returns no name")
eq(source, "invalid", "invalid override source")
name, source = M.resolve(nil, "bad/name", "butler-old")
eq(name, nil, "invalid env returns no name")
eq(source, "invalid", "invalid env source")
-- Our own cache is different: corrupt it and the default still starts.
name, source = M.resolve(nil, nil, "bad name")
eq(name, "butler", "a corrupt record falls back to the default")
eq(source, "default", "corrupt record reports default")

-- Durable record format.
local text = M.format_binding("butler-alt", "01ABCDEF")
ok(text:match("^version=1\n") ~= nil, "record carries version=1")
ok(text:find("\nlogical=butler\n", 1, true) ~= nil, "record carries the logical name")
eq(M.recorded_name(text), "butler-alt", "record round-trips the physical name")
eq(M.recorded_name(M.format_binding("butler-alt")), "butler-alt", "instance is optional")
eq(M.recorded_name(""), nil, "empty record")
eq(M.recorded_name(nil), nil, "nil record")
eq(M.recorded_name("name=butler-alt\n"), nil, "record without a version is foreign")
eq(M.recorded_name("version=2\nlogical=butler\nname=butler-alt\n"), nil, "future version is ignored")
eq(M.recorded_name("version=1\nlogical=other\nname=butler-alt\n"), nil, "other logical name is ignored")
eq(M.recorded_name("version=1\nlogical=butler\nname=bad name\n"), nil, "invalid recorded name is ignored")
eq(M.recorded_name("not a record at all"), nil, "junk is ignored")

-- Restart/adoption predicate: only a matching, alive row counts.
local rows = {
  { name = "butler", alive = false },
  { name = "butler-alt", alive = true },
}
ok(M.session_alive(rows, "butler-alt"), "alive matching row counts")
ok(not M.session_alive(rows, "butler"), "a dead row does not count")
ok(not M.session_alive(rows, "other"), "a different name does not count")
ok(not M.session_alive({ { name = "butler-alt" } }, "butler-alt"), "a row without alive does not count")
ok(not M.session_alive(nil, "butler-alt"), "no rows is not alive")

-- Routing: a physical session name resolves to exactly one logical alias.
local roster = {
  { alias = "butler", session_name = "butler-alt" },
  { alias = "worker", session_name = "worker-1" },
}
eq(M.logical_for(roster, "butler-alt"), "butler", "physical root resolves to the logical root")
eq(M.logical_for(roster, "worker-1"), "worker", "a member resolves to its alias")
eq(M.logical_for(roster, "unknown"), nil, "unknown physical name does not resolve")
eq(M.logical_for(roster, ""), nil, "empty physical name does not resolve")
eq(M.logical_for(nil, "butler-alt"), nil, "no roster rows does not resolve")
local ambiguous = {
  { alias = "a", session_name = "same" },
  { alias = "b", session_name = "same" },
}
eq(M.logical_for(ambiguous, "same"), nil, "an ambiguous mapping does not resolve")
local duplicate = {
  { alias = "a", session_name = "same" },
  { alias = "a", session_name = "same" },
}
eq(M.logical_for(duplicate, "same"), "a", "a duplicated identical mapping is not ambiguous")

print("PASS tests/effective_name.lua (" .. passed .. " assertions)")
