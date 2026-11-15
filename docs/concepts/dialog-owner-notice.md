# Codex approval owner notice

Owner request (2026-11-15): learn from Matrix that a managed Codex session is
waiting for an approval decision, without depending on the member or its leader
noticing the leader inbox. Step one is report-only; answering the pending
request from Matrix is a later step and is not implemented.

`packages/butler/dialog_owner_notice.lua` posts one plain Matrix notice to the
owner's home room for a recognised Codex dialog whose `dialog_states`
response is `approval` (the four permission headings, `codex_proceed_confirm`
and `codex_auto_review_refused`). It runs only from the once-a-second dialog
tick, after `dialogs.lua`'s two-capture stability and its own 3-second debounce.

## Delivery rules

- It never sends a key, text, approval, denial or option. The pane still needs
  the owner. The existing leader report is unchanged, and Claude dialogs are
  never posted to the owner room.
- The notice names the session alias and the recognised state id only. It
  carries no screen text, command line, path or file content.
- One notice per pending dialog (session, instance, state id, choice block). A
  session gets at most one notice per 30-second window, so a repaint that
  changes the choice block cannot flood the room.
- An offline relay or a failed post retries every 30 seconds. Only a Matrix
  event id is recorded as delivery; an error or silence is not.
- Delivered receipts persist in `<butler data dir>/dialog-owner-notice`. A
  receipt is cleared when `dialogs.lua` audits the dialog's resolution, so a
  restart does not repeat a notice for a still-pending dialog, while a later
  identical approval is a new request and does notify. Receipts older than an
  hour cannot suppress a notice.
- If the daemon dies after a post but before its callback, the next start posts
  once more. For a notice, a duplicate is better than silence, and a receipt is
  never guessed from an uncertain result.

## Why not `approval.request`

`approval.request` opens an actionable request with reactions and a handler.
That is the later native-answer step. This slice is deliberately
`approval.notify`, which posts a plain owner-room message and can never write
input, so it cannot approve, deny or bypass the existing refusal.
