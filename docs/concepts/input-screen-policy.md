# Managed input screen policy

Owner decision (2026-10-15): unrecognized/unparseable screens allow input.
The screen gate is independent of caller authorization, session identity,
instance fencing, workflow ownership, approval policy, and required write
audits; those restrictions still apply.

Owner-approved prepared text has its own admission policy. Unknown or
unavailable rendering allows approved text; a positively parsed draft, current
known modal, recent attached human input, conflicting task workflow, unavailable
session or changed instance still refuses. On legacy cores without
`human_idle`, the attached-human stable-pause guard remains. Refusals name the
reason instead of labeling every case `pane_busy`. Recent output and an active
turn never prove the composer cannot accept input. Submission semantics are
unchanged; no extra Return is sent. For approved text, generic menu geometry in
the last prompt region is uncertain unless a current composer boundary or a
recognized footer establishes a draft; a numbered prefix alone never grants
input, and quoted menus cannot erase a later draft. Borderless menu-shaped text
is allowed under the explicit unknown=allow decision; a bounded numbered draft
blocks. The durable one-shot marker is followed by another identity/admission
check; a refusal after it is terminal and cannot replay approved bytes.

Automatic mail notices no longer use this screen policy at all (owner decision
2026-11-03; see `idle-notice-policy.md`). Owner lines, first tasks and approved
text still do.

`packages/butler/dialogs.lua` gates `key`, `type_text` and `send`. It captures
again after its before-write audit. Missing or replaced sessions block; failed
or malformed captures and classifier errors are unknown screens. A previous
screen blocker clears, with an audit, once no current exception is identified.
Unknown composers, including a task awaiting a Return retry, need no empty or
ready parser result.

## Exceptional screens

Complete Codex model/effort pickers; current known model/effort/approval
headings with choice or modal geometry; Claude's limit-menu title plus its exact
stop/wait option; established trust/update/Teach startup parsers with validated
options. Workflow-owned startup/compaction exceptions keep their existing
identity/phase/option checks. Owner picker recovery requires its complete
parser, exact instance, audit and bounded ESC-only transition checks.

Numbered options or a box alone do not identify an exceptional state. A known
heading must precede the current choice or sit inside its box. Supported
approval metadata and command rows may intervene, bounded to 32 lines; an
unrelated heading ends the search. A later composer or fenced transcript quote
makes old choices historical. Only the current contiguous choice block is
classified. Historical titles separated by a new heading confer no meaning.
Existing compaction/startup matchers are unchanged and grant no generic write
authority.

## Source evidence

Read-only installed binaries, inspected 2026-10-15; no real pane input:

- Codex 0.162.1: TUI strings "Would you like to run the following command?",
  "... make the following edits?", "... grant these permissions?" and
  "... send input to the existing terminal?". Fixtures cover model/effort.
- Claude Code 2.1.296: embedded JS renders `_e` with title
  `What do you want to do?`; options include `Stop and wait for limit to reset`.
  Model confirmation titles are `Switch model?` / `Change effort level?`.
  Permission components render `Do you want to proceed?` and
  `Do you want to allow Claude to fetch this content?` before their selectors.
- Codex's guardian string
  `Automatic approval review rejected too many approval requests for this turn (`
  followed by counters and ` reviews); interrupting the turn.` is not by itself
  evidence of a current modal. Only a choice immediately under that exact
  message blocks. Broad refusal-word heuristics are intentionally absent.

Tests use synthetic screens (limits/refusal confirmations, unknown
menus/boxes/composers, stale titles, failed captures/parsers, instance changes,
audits, picker recovery); they never manufacture approval or pick a real option.
Codex's `approval_overlay.rs` (build_options/build_header) puts the title before
the header and selector, so metadata/command rows may separate them; the
command/edit fixtures are synthetic renderings of that layout, not captures.

## Named states and responses (#499)

Each exceptional screen has a named state with a response (`approval`, `report`
or `auto`), listed per agent under "Recognised dialog states" in docs/butler.md
and in `dialog_states` in the agent files. Reports name the state instead of
`kind=unknown`. The only `auto` state is Claude's Teach auto mode page 1,
answered `Not now` by its text (owner, #453). An unrecognised current numbered
choice still allows input; it is reported once to the leader after 60 unchanged
seconds.
