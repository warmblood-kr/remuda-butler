# Managed input screen policy

Owner decision (2026-10-15): unrecognized/unparseable screens allow input.
The screen gate is independent of caller authorization, session identity,
instance fencing, workflow ownership, approval policy, and required write audits.
Those restrictions continue to apply.

Owner-approved prepared text uses its own admission policy rather than the
unsolicited mail-notice requirement for a recognized empty composer. Unknown
or unavailable rendering allows approved text; a positively parsed draft,
current known modal, recent attached human input, conflicting task workflow,
unavailable session or changed instance still refuses. On legacy cores without
human_idle, the independent attached-human stable-pause guard remains. Refusals
report these reasons instead of labeling every case pane_busy. Neither recent
output nor an active agent turn establishes that the composer cannot accept
input. Existing submission semantics are unchanged; no extra Return is sent.
The durable one-shot marker is followed by another identity/admission check;
refusal after that marker is terminal and cannot replay approved bytes.

`packages/butler/dialogs.lua` gates key/type_text/send. It captures again after
its before-write audit. Missing/replaced sessions block; failed/malformed
captures and classifier errors are unknown screens. A previous screen blocker
clears, with an audit, once no current exception is identified. Unknown
composers, including a task awaiting a retry of Return, do not require an empty
or ready parser result.

Exceptional screens: complete Codex model/effort pickers; current known
model/effort/approval headings with choice or modal geometry; Claude's limit
menu title plus its exact stop/wait option; established trust/update/Teach
startup parsers with validated options. Workflow-owned startup/compaction
exceptions retain their existing identity/phase/option checks. Owner picker
recovery still requires its complete parser, exact instance, audit and bounded
ESC-only transition checks.

Numbered options or a box alone do not identify an exceptional state. A known
heading must precede the current choice, or be inside its box. Supported
approval metadata and command rows may intervene, bounded to 32 lines; an
unrelated heading ends the search. A later composer or fenced transcript
quote makes old choices historical. Only the current contiguous choice block
is classified.
Historical titles separated by a new heading do not confer meaning on the
current menu. Existing broader compaction/startup matching helpers are not
changed; they do not grant generic write authority.

## Source evidence

Read-only local installed binaries, inspected 2026-10-15; no real pane input:

- Codex 0.162.1 (`/opt/homebrew/Caskroom/codex/0.162.1/bin/codex`): TUI strings
  “Would you like to run the following command?”, “Would you like to make the
  following edits?”, “Would you like to grant these permissions?”, and
  “Would you like to send input to the existing terminal?”. Existing picker
  fixtures in tests/fixtures cover model and effort layouts.
- Claude Code 2.1.296 (`~/.local/share/claude/versions/2.1.296`): embedded JS
  renders `_e` with title `What do you want to do?`; its options include
  `Stop and wait for limit to reset`. Model confirmation selects the titles
  `Switch model?` / `Change effort level?`. Permission components render
  `Do you want to proceed?` and
  `Do you want to allow Claude to fetch this content?` before their selectors.
- Codex's guardian reporting string is
  `Automatic approval review rejected too many approval requests for this turn (`
  followed by counters and ` reviews); interrupting the turn.`
  This event text alone is NOT evidence of a currently open modal. Only a
  current choice immediately under that exact message blocks. The test choice
  layout is synthetic, not a captured upstream UI. No standalone historical
  refusal marker blocks input. A future different human-confirmation UI needs
  its own observed signature; broad refusal-word heuristics are intentionally
  absent.

Tests use synthetic screens, including limits/refusal confirmations, unknown
menus/boxes/composers, stale titles, failed captures/parsers, instance changes,
audits and known picker recovery. They do not manufacture owner approval or
select a real permission option.

## Approval header layout evidence

OpenAI Codex upstream `codex-rs/tui/src/bottom_pane/approval_overlay.rs`
(build_options/build_header), read 2026-10-15:
https://github.com/openai/codex/blob/main/codex-rs/tui/src/bottom_pane/approval_overlay.rs
build_options places the title before the request header and selector; header
metadata/reason and command rows can separate title from choices. File-change
headers use description/destination fields:
https://github.com/openai/codex/blob/main/codex-rs/tui/src/bottom_pane/apply_patch_header.rs
The command/edit fixtures are synthetic representative renderings of those
source layouts using harmless sample values, not captures of real panes.
