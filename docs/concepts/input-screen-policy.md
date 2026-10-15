# Managed input screen policy

Owner decision (2026-10-15): unrecognized/unparseable screens allow input.
The screen gate is independent of caller authorization, session identity,
instance fencing, workflow ownership, approval policy, and required write audits.
Those restrictions continue to apply.

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
heading must immediately precede the current choice, or be inside its box.
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
