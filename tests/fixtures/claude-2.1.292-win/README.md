Raw `remuda.capture` bytes of an idle, freshly launched Claude Code 2.1.292 (Windows 11, ConPTY, remuda 9ac6f19), 2026-10-07; written byte-exact via hex, no newline or encoding changes.
Files: claude-2.1.292-{120,100,140}x30.txt, one session captured at 120 cols then resized to 100 and 140 (30 rows each).
Each starts with "\n" (empty row 1); launch diagnostics show row 1 only and print "<empty first row>" instead of treating the screen as blank.
The full-width composer border and the prompt come out as one row ("────…─❯ Try …", no "\n" between them), as do the bottom border and the footer.
Readiness: the launch readiness match (init.lua) accepts these captures (a rule run, "❯", then empty or a dim `Try "` hint); startup readiness (agents/claudecode.lua) accepts only an empty suffix, so they are launch-ready but not startup-ready. Launch readiness is not permission to type: the unchanged composer gate decides, and `_butler_prompt_is_empty` still reports UNPARSEABLE for them.
Row 4 is a generic home-relative Butler path (`~\.local\share\remuda\butler\sessions\butler\work\win-blank`): no user name or credential; the bytes are intentionally unmodified.
