# One-time Codex command approval from Matrix

Owner decision (2026-11-15): the owner can answer a recognised Codex
command-approval prompt from the owner Matrix room, with no standing grant and
no arbitrary remote text. The approval request offers two answers: confirm the
selected `Yes, proceed`, or send the prompt's own Escape cancel.

## Exact conditions (all must hold)

- The current choice segment is exactly the captured three options in order:
  `1. Yes, proceed (y)`, `2. Yes, and don't ask again … (p)` (a standing
  permission this action never selects) and `3. No, and tell Codex what to do
  differently (esc)`, with the cursor on option 1. A wrapped option label may
  continue on indented lines; any marker or other line is refused.
- The heading directly above is `Would you like to run the following command?`
  and exactly one displayed `$ command` line sits between them. Any other line
  (a wrapped command, another section) is not actionable.
- The command is 200 bytes or less with no control characters, so the request
  can show the execution content in full.
- The command passes the conservative exposure screen: token/password/secret/
  credential/private-key assignments and options, bearer headers, URL
  credentials, basic-auth options and known token prefixes make it
  non-actionable. This screening is heuristic; a miss leaves the prompt
  report-only and the owner answers in the pane.
- A room is configured (the approval room or owner home room), the rendered
  request stays within 2048 bytes, and the Matrix config carries
  `dialog_approval=on`. No room, no opt-in or an over-long request fails closed.
- The prompt's footer `Press enter to confirm or esc to cancel` directly
  follows the choices, and no composer appears below them: a historical prompt
  is not actionable.
- The recognised state entry carries `action_scope = once` and the descriptor
  is `codex_command_approval_once` version 1.

## Actions

- Approve: one Return, confirming the already-selected `Yes, proceed (y)`.
  Butler never moves the cursor.
- The other answer sends one Escape, which is option 3, `No, and tell Codex
  what to do differently (esc)`. In the measured 0.167.2 run this declined the
  request, interrupted the turn and executed nothing; other versions are not
  verified, so the UI calls it the prompt's Escape cancel rather than a
  generic "reject".
- Only a live owner Matrix reaction or reply answers. The terminal never
  writes. One input per answer.
- A changed screen, command, option, descriptor version, session instance or
  launch marker, a human attachment, expiry, restart or audit failure refuses
  the input or leaves the prompt untouched.
- Butler records consumption before the key, sends it once, captures the
  result, verifies the prompt is gone and the instance is unchanged, and
  audits `verified` or `uncertain`. An uncertain write is never retried.
- While an actionable request exists, the plain report-only owner notice is
  suppressed, so one dialog produces one Matrix message.

## Real capture and limits

The fixture is a sanitized capture from codex-cli 0.167.2 (macOS, 2026-11-15,
`-s workspace-write -a on-request`, writing outside the workspace). Pressing
Escape selected option 3: the screen showed the request canceled, the command
did not run (the target file was absent), `Conversation interrupted` appeared,
and the composer returned.

The parser is deliberately exact: a markup difference makes the prompt
non-actionable and leaves the report-only path in place. Screen text is treated
only as untrusted data for structural matching; it is never interpreted as an
instruction and never executed, and the request labels the displayed action as
untrusted screen text. The credential screen is heuristic, so a miss is
possible: the target room must stay owner-controlled because the command is
posted there and retained in Matrix history. Codex auto-review refusals are
never actionable and are not re-run or bypassed.
