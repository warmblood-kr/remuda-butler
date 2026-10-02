-- Unit tests for permissions.fs_helpers: the realpath and is_symlink helpers
-- Butler hands its file checks, on a core with remuda.fs.realpath and on an
-- older one. Run from the repository root:
--   luajit tests/butler_fs_seam.lua
remuda = {}
local permissions = dofile("packages/butler/permissions.lua")
local count, failed = 0, {}
local function eq(name, got, want)
  count = count + 1
  if got ~= want then
    failed[#failed + 1] = ("case %d: %s\n   want: %s\n    got: %s"):format(count, name, tostring(want), tostring(got))
  end
end

-- A stand-in for core's remuda.fs: `answers[path]` is { value, reason } or a function that raises.
local function fake_fs(real, links)
  local function answer(from)
    return function(path)
      local found = from[path]
      if type(found) == "function" then return found() end
      if found == nil then return nil, "not_found" end
      return found[1], found[2]
    end
  end
  return { realpath = answer(real), is_symlink = answer(links) }
end
local shell_calls = {}
local function shell(result)
  return function(argv)
    shell_calls[#shell_calls + 1] = table.concat(argv, " ")
    if type(result) == "function" then return result(argv) end
    return result
  end
end
local function raises() error("core raised", 0) end

local core = fake_fs(
  { ["/w/in.txt"] = { "/real/w/in.txt" }, ["/w/locked"] = { nil, "denied: Permission denied (os error 13)" },
    ["/w/odd"] = { nil, "unavailable: the resolved path is not UTF-8" }, ["/w/raise"] = raises,
    ["/w/empty"] = { "" }, ["/w/number"] = { 7 } },
  { ["/w/link"] = { true }, ["/w/file"] = { false }, ["/w/locked"] = { nil, "denied: Permission denied (os error 13)" },
    ["/w/odd"] = { nil, "unavailable: x" }, ["/w/raise"] = raises, ["/w/no-reason"] = function() return nil end,
    ["/w/text"] = { "true" } })
for _, platform in ipairs({ "posix", "windows" }) do
  shell_calls = {}
  local realpath, is_symlink = permissions.fs_helpers(core, shell({ code = 0, stdout = "/shell/answer\n" }), platform)
  local on = platform .. ", new core: "
  eq(on .. "realpath is the core's answer", realpath("/w/in.txt"), "/real/w/in.txt")
  eq(on .. "realpath of a missing path is nil", realpath("/w/missing"), nil)
  eq(on .. "realpath denied is nil", realpath("/w/locked"), nil)
  eq(on .. "realpath unavailable is nil", realpath("/w/odd"), nil)
  eq(on .. "realpath that raises is nil", realpath("/w/raise"), nil)
  eq(on .. "an empty realpath answer is nil", realpath("/w/empty"), nil)
  eq(on .. "a realpath answer that is not a string is nil", realpath("/w/number"), nil)
  eq(on .. "a link is a link", is_symlink("/w/link"), true)
  eq(on .. "a plain file is not a link", is_symlink("/w/file"), false)
  -- Nothing there means no link there: a new file may be written.
  eq(on .. "a missing path is not a link", is_symlink("/w/missing"), false)
  eq(on .. "is_symlink denied cannot tell", is_symlink("/w/locked"), nil)
  eq(on .. "is_symlink unavailable cannot tell", is_symlink("/w/odd"), nil)
  eq(on .. "is_symlink that raises cannot tell", is_symlink("/w/raise"), nil)
  eq(on .. "nil with no reason cannot tell", is_symlink("/w/no-reason"), nil)
  eq(on .. "an answer that is not a boolean cannot tell", is_symlink("/w/text"), nil)
  eq(on .. "no shell command is run", #shell_calls, 0)
end

-- An older core: the shell helpers on posix, nothing on Windows.
for name, old in pairs({ ["no remuda.fs"] = false, ["remuda.fs without the words"] = { lock = function() end },
  ["only realpath"] = { realpath = core.realpath }, ["only is_symlink"] = { is_symlink = core.is_symlink } }) do
  shell_calls = {}
  local realpath, is_symlink = permissions.fs_helpers(old or nil, shell(function(argv)
    if argv[1] == "realpath" then return { code = 0, stdout = "/shell/real\n" } end
    return { code = argv[3] == "/w/link" and 0 or 1 }
  end), "posix")
  local on = "posix, old core (" .. name .. "): "
  eq(on .. "realpath asks the shell helper", realpath("/w/in.txt"), "/shell/real")
  eq(on .. "a link, by test -L", is_symlink("/w/link"), true)
  eq(on .. "not a link, by test -L", is_symlink("/w/file"), false)
  eq(on .. "the commands are argument vectors", table.concat(shell_calls, " | "),
    "realpath /w/in.txt | test -L /w/link | test -L /w/file")
  shell_calls = {}
  realpath, is_symlink = permissions.fs_helpers(old or nil, shell({ code = 0, stdout = "/shell/real\n" }), "windows")
  on = "windows, old core (" .. name .. "): "
  eq(on .. "realpath is nil", realpath([[C:\proj\in.txt]]), nil)
  eq(on .. "is_symlink cannot tell", is_symlink([[C:\proj\in.txt]]), nil)
  eq(on .. "no shell command is run", #shell_calls, 0)
end
for name, result in pairs({ ["a failing helper"] = { code = 3, stdout = "/x\n" }, ["a timed-out helper"] = { code = 0, timed_out = true, stdout = "/x\n" },
  ["a helper that raises"] = raises, ["no result"] = function() return nil end,
  ["test -L exit 2"] = { code = 2 } }) do
  local realpath, is_symlink = permissions.fs_helpers(nil, shell(result), "posix")
  eq("posix, old core, " .. name .. ": realpath is nil", realpath("/w/in.txt"), nil)
  eq("posix, old core, " .. name .. ": is_symlink cannot tell", is_symlink("/w/in.txt"), nil)
end

eq("posix, old core, an empty realpath answer is nil",
  (permissions.fs_helpers(nil, shell({ code = 0, stdout = "\n" }), "posix"))("/w/in.txt"), nil)

-- End to end with the confinement rule: a download into the working directory.
local function download(path, real, links, platform, cwd)
  local realpath, is_symlink = permissions.fs_helpers(fake_fs(real, links), shell({ code = 1 }), platform)
  return permissions.output_for_caller(path, "matrix-MEDIA", { kind = "session", session = "s" },
    function() return cwd end, realpath, is_symlink, platform)
end
local real = { ["/w"] = { "/real/w" } }
eq("a new file in the working directory may be written", download("/w/new.bin", real, {}, "posix", "/w"), "/real/w/new.bin")
eq("an existing plain file may be overwritten",
  download("/w/old.bin", real, { ["/real/w/old.bin"] = { false } }, "posix", "/w"), "/real/w/old.bin")
eq("a dangling link at the target is refused",
  select(2, download("/w/dangling", real, { ["/real/w/dangling"] = { true } }, "posix", "/w")),
  "refused: -o /w/dangling is a symlink\nNext: pass -o with a path inside /w")
eq("a target that cannot be checked is refused",
  select(2, download("/w/locked", real, { ["/real/w/locked"] = { nil, "denied: x" } }, "posix", "/w")),
  "refused: -o /w/locked cannot be checked for a symlink\nNext: pass -o with a path inside /w")
eq("a parent the core cannot resolve is refused",
  select(2, download("/gone/new.bin", real, {}, "posix", "/w")),
  "refused: -o /gone/new.bin cannot be resolved (a missing directory, or realpath is unavailable)\nNext: pass -o with a path inside /w")
-- Core answers in the verbatim form on Windows; the working directory is recorded in the plain form.
local wreal = { [ [[C:\Proj]] ] = { [[\\?\C:\Proj]] }, [ [[c:/proj/Sub]] ] = { [[\\?\C:\Proj\Sub]] } }
eq("windows: a verbatim answer is inside a plainly recorded working directory",
  download("c:/proj/Sub/new.bin", wreal, {}, "windows", [[C:\Proj]]), [[\\?\C:\Proj\Sub\new.bin]])
local unc = { [ [[\\srv\share\proj]] ] = { [[\\?\UNC\srv\share\proj]] } }
eq("windows: a verbatim UNC answer is inside a UNC working directory",
  download([[\\srv\share\proj\new.bin]], unc, {}, "windows", [[\\srv\share\proj]]), [[\\?\UNC\srv\share\proj\new.bin]])

if #failed > 0 then error(#failed .. " of " .. count .. " cases failed:\n" .. table.concat(failed, "\n"), 0) end
print(("butler_fs_seam ok: %d cases"):format(count))
