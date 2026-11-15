# One-time Codex command approval from Matrix

Owner decision (2026-11-15): approve the selected `Yes, proceed` for a captured
Codex prompt from the owner Matrix room, with no standing grant.

## Exact conditions

- The current choice segment is the captured three options in order: `1. Yes,
  proceed (y)`, `2. Yes, and don't ask again … (p)` (never selected) and `3. No,
  and tell Codex what to do differently (esc)`, cursor on option 1; only
  indented continuations may appear, and the state entry is `once` at version 1.
- The heading directly above is `Would you like to run the following command?`
  with exactly one `$ command` line; any other line is not actionable.
- The command is ≤200 bytes, has no control characters, and passes a
  conservative exposure screen for token/password/secret/credential/private-key
  assignments and options, bearer headers, URL credentials, basic-auth options
  and known token prefixes. The screen is heuristic.
- A room is configured, the rendered request is ≤2048 bytes, and the Matrix
  config carries `dialog_approval=on`; otherwise it fails closed. The prompt
  footer must follow the choices directly with no composer below.

## Actions and safety

- Approve: one Return on the selected `Yes, proceed (y)`; Butler never moves the
  cursor. Any other answer closes the request and sends nothing; no Escape.
- Only a live owner Matrix event answers; the terminal never writes, one input
  per request. Changed screen, command, option, version, instance, launch marker,
  attachment, expiry, restart or audit failure refuses input.
- Consumption is persisted before the key, sent once, then verified; the outcome
  is audited `verified` or `uncertain` and never retried. An actionable request
  suppresses the plain notice, so one dialog yields one Matrix message.

## Capture and limits

The fixture is a sanitized codex-cli 0.167.2 capture (macOS, 2026-11-15,
`-s workspace-write -a on-request`). The parser is exact; a markup difference
stays report-only. Screen text is untrusted data, never executed, and is
labelled as such in the request. The credential screen is heuristic, so the
approval room must stay owner-controlled: the command is posted and kept in
Matrix history. Auto-review refusals are never actionable or retried.
