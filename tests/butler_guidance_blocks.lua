-- Unit tests for packages/butler/guidance_blocks.lua. Run from the repository root:
--   luajit tests/butler_guidance_blocks.lua
remuda = {}
local gb = dofile("packages/butler/guidance_blocks.lua")
local count = 0
local function eq(name, got, want)
  count = count + 1
  if got ~= want then
    error(("case %d: %s\n want: %q\n  got: %q"):format(count, name, tostring(want), tostring(got)), 2)
  end
end
local B = "<!-- BEGIN remuda-butler:managed id=butler -->\n"
local E = "<!-- END remuda-butler:managed id=butler -->\n"
local function block(body) return B .. body .. E end
local function outcome(report, i) return report[i or 1].outcome end
local blocks = { { id = "butler", body = "# Butler\nhi\n" } }

-- first write, then a second merge writes nothing
local first, report = gb.merge(nil, blocks)
eq("first write", first, block("# Butler\nhi\n"))
eq("first write report", outcome(report), "written")
local again, report2 = gb.merge(first, blocks)
eq("second merge writes nothing", again, nil)
eq("second merge report", outcome(report2), "unchanged")

-- user text above, below and replace only between the markers
local mixed = "above\n\n" .. block("old\n") .. "\nbelow\n"
local new, r = gb.merge(mixed, blocks)
eq("replace between markers only", new, "above\n\n" .. block("# Butler\nhi\n") .. "\nbelow\n")
eq("replace report", outcome(r), "written")
-- user text between two blocks
local two = { { id = "butler", body = "a\n" }, { id = "layout", body = "b\n" } }
local both = gb.merge(nil, two)
local L = "<!-- BEGIN remuda-butler:managed id=layout -->\nb\n<!-- END remuda-butler:managed id=layout -->\n"
eq("two blocks", both, block("a\n") .. "\n" .. L)
local middle = block("a\n") .. "my table\n" .. L
eq("text between blocks kept, nothing to write", (gb.merge(middle, two)), nil)
eq("text between blocks kept on change", (gb.merge(middle, { { id = "butler", body = "z\n" }, two[2] })),
  block("z\n") .. "my table\n" .. L)

-- no pair yet: append after a blank line
local appended, ra = gb.merge("my notes\n", blocks)
eq("append with zero pairs", appended, "my notes\n\n" .. block("# Butler\nhi\n"))
eq("append report", outcome(ra), "appended")
eq("append when no final newline", (gb.merge("my notes", blocks)), "my notes\n\n" .. block("# Butler\nhi\n"))

-- legacy unmarked file
local old = gb.known_old[#gb.known_old]
local migrated, rm = gb.merge(old, blocks)
eq("legacy old constant migrated", migrated, block("# Butler\nhi\n"))
eq("legacy report", outcome(rm), "migrated")
eq("legacy older text migrated", (gb.merge(gb.known_old[1], blocks)), block("# Butler\nhi\n"))
eq("whole file equal to the current body migrated", (gb.merge("# Butler\nhi\n", blocks)), block("# Butler\nhi\n"))
local edited, re = gb.merge(old .. "my table\n", blocks)
eq("legacy user-edited kept and block appended", edited, old .. "my table\n\n" .. block("# Butler\nhi\n"))
eq("legacy edited report", outcome(re), "appended")

-- damaged and duplicated markers write nothing
local function damaged(name, text, want)
  local out, rep = gb.merge(text, blocks)
  eq(name .. " writes nothing", out, nil)
  eq(name .. " report", outcome(rep), want or "damaged")
end
damaged("BEGIN without END", "x\n" .. B .. "y\n")
damaged("END without BEGIN", "x\n" .. E .. "y\n")
damaged("END before BEGIN", E .. "y\n" .. B)
damaged("two BEGIN, no END", B .. "y\n" .. B)
damaged("nested BEGIN", B .. B .. "y\n" .. E)
damaged("duplicated pairs", block("a\n") .. "x\n" .. block("b\n"), "duplicated")
damaged("a pair holding another id's marker", B .. L .. E)
local partial = gb.merge(B .. "x\n" .. "\n" .. L, { blocks[1], { id = "layout", body = "c\n" } })
eq("a damaged id does not stop the others", partial, B .. "x\n" .. "\n" .. L:gsub("b\n", "c\n"))

-- empty file
eq("empty string is written", (gb.merge("", blocks)), block("# Butler\nhi\n"))
eq("blank file is written", (gb.merge("\n\n", blocks)), block("# Butler\nhi\n"))
eq("nothing to write for no blocks", (gb.merge("text", {})), nil)

-- CRLF keeps its line endings
local crlf = (block("old\n")):gsub("\n", "\r\n")
local crlf_new = gb.merge("top\r\n" .. crlf, blocks)
eq("CRLF replace", crlf_new, "top\r\n" .. block("# Butler\nhi\n"):gsub("\n", "\r\n"))
eq("CRLF unchanged", (gb.merge(crlf_new, blocks)), nil)
eq("CRLF append", (gb.merge("top\r\n", blocks)), "top\r\n\r\n" .. block("# Butler\nhi\n"):gsub("\n", "\r\n"))
local _, rx = gb.merge("a\r\nb\n", blocks)
eq("mixed endings refused", outcome(rx), "mixed-eol")
eq("mixed endings write nothing", (gb.merge("a\r\nb\n", blocks)), nil)

-- dropped blocks
local big, rb = gb.merge(nil, { { id = "butler", body = ("x"):rep(8193) } })
eq("oversize body dropped", big, nil)
eq("oversize report", outcome(rb), "dropped")
eq("body of exactly 8 KiB kept", (gb.merge(nil, { { id = "butler", body = ("x"):rep(8192) } })) ~= nil, true)
local bad, rbad = gb.merge(nil, { { id = "Bad_Id", body = "x\n" }, { id = "ok-1", body = "y\n" } })
eq("invalid id dropped", outcome(rbad, 1), "dropped")
eq("valid id beside it kept", outcome(rbad, 2), "written")
eq("only the valid block rendered", bad,
  "<!-- BEGIN remuda-butler:managed id=ok-1 -->\ny\n<!-- END remuda-butler:managed id=ok-1 -->\n")
eq("body with a marker line dropped", outcome(select(2, gb.merge(nil, { { id = "butler", body = B } }))), "dropped")
eq("body without final newline gets one", (gb.merge(nil, { { id = "butler", body = "x" } })), block("x\n"))

-- sync: the file side, through injected fs seams
local function fake(files, links)
  local fs, writes = { writes = 0 }, 0
  fs.read = function(path) return files[path] end
  fs.is_symlink = function(path) return links[path] or false end
  fs.write = function(path, text) fs.writes = fs.writes + 1; files[path] = text; return true end
  return fs
end
local files = { ["/r/AGENTS.md"] = "my table\n" }
local fs = fake(files, {})
local wrote, rs = gb.sync("/r/AGENTS.md", blocks, fs)
eq("sync writes the block after the user text", files["/r/AGENTS.md"], "my table\n\n" .. block("# Butler\nhi\n"))
eq("sync reports a write", wrote, true)
wrote = gb.sync("/r/AGENTS.md", blocks, fs)
eq("a second sync does not write", fs.writes, 1)
eq("a second sync reports no write", wrote, false)
files["/r/AGENTS.md"] = "top\n" .. files["/r/AGENTS.md"]
gb.sync("/r/AGENTS.md", blocks, fs)
eq("text added outside the block survives a later sync", files["/r/AGENTS.md"]:sub(1, 4), "top\n")
eq("and is not rewritten", fs.writes, 1)
local linked = fake({ ["/r/AGENTS.md"] = "x\n" }, { ["/r/AGENTS.md"] = true })
local lw, lr = gb.sync("/r/AGENTS.md", blocks, linked)
eq("a symlink is refused", outcome(lr), "symlink")
eq("a symlink is not written", linked.writes, 0)
local unsure = fake({}, { ["/r/AGENTS.md"] = false })
unsure.is_symlink = function() return nil end
eq("an unknown link state is refused", outcome(select(2, gb.sync("/r/AGENTS.md", blocks, unsure))), "symlink")
local failing = fake({}, {})
failing.write = function() return nil, "disk full" end
local fw, _, why = gb.sync("/r/AGENTS.md", blocks, failing)
eq("a failed write is reported", why, "disk full")

-- a malformed managed marker makes the whole file damaged: nothing is written
for _, bad in ipairs({
  "<!-- BEGIN remuda-butler:managed id=butler_1 -->", "<!-- END remuda-butler:managed id=butler_1 -->",
  "<!-- BEGIN remuda-butler:managed id= -->", "<!-- BEGIN remuda-butler:managed id=Butler -->",
  "<!-- BEGIN remuda-butler:managed id=butler --> junk", "<!-- BEGIN remuda-butler:managed",
}) do
  damaged("malformed marker " .. bad, "my notes\n" .. bad .. "\nedited\n")
  damaged("malformed marker beside a good block " .. bad, block("a\n") .. bad .. "\n")
end
eq("a lowercase begin is plain text", outcome(select(2, gb.merge("<!-- begin remuda-butler:managed id=x -->\n", blocks))), "appended")

-- legacy match is exact except for one trailing newline
eq("legacy with one extra trailing newline not migrated", outcome(select(2, gb.merge(old .. "\n\n", blocks))), "appended")
eq("legacy with trailing spaces not migrated", outcome(select(2, gb.merge(old .. "  ", blocks))), "appended")
eq("legacy without its final newline migrated", outcome(select(2, gb.merge((old:gsub("\n$", "")), blocks))), "migrated")

print(("butler_guidance_blocks: %d cases passed"):format(count))
