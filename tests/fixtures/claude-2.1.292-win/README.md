Raw `remuda.capture` bytes of an idle, freshly launched Claude Code 2.1.292 (Windows 11, ConPTY, remuda 9ac6f19), 2026-10-07; written byte-exact via hex, no newline or encoding changes.
Files: claude-2.1.292-{120,100,140}x30.txt, one session captured at 120 cols then resized to 100 and 140 (30 rows each).
Each starts with "\n" (empty row 1), so agents_launch.lua one_line() == "" and misreports "screen was blank at readiness timeout".
The full-width composer border and the prompt come out as one row ("────…─❯ Try …", no "\n" between them), as do the bottom border and the footer.
Today: claudecode ready ("─\n❯") == false and _butler_prompt_is_empty("claude", s) == "UNPARSEABLE"; expected ready == true. Note the composer holds Claude's dim "Try …" suggestion, which has no claude placeholder entry today.
