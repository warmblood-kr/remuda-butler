# Codex approval owner notice

Owner request (2026-11-15): the owner learns from Matrix that a Codex session
waits; step one is report-only and answering from Matrix is step two.

`packages/butler/dialog_owner_notice.lua` posts one plain notice to the owner's
home room from the periodic dialog tick, after `dialogs.lua`'s stability
captures and a 3 s debounce, for a Codex dialog whose response is `approval` and
for `codex_auto_review_refused`. The refusal is a classifier decision, not a
pending request (it is marked `approval`, so it still blocks); its notice says
no approval is pending and it is noticed even if a future row says `report`. It
never writes input; Claude and the leader report are unchanged.

## Delivery rules

- The notice names the session alias and state id only: no node, request
  content, command, path or file. A remote reader cannot judge or approve from
  it; the pane on that host is still required.
- Receipt key = session + instance + state id + choice block. One notice per
  pending dialog and per session per 30 s; receipts last an hour (max 50). A
  replaced instance is a new key, so it notifies.
- Only a Matrix event id is delivery; an offline or failed post retries every
  30 s. A resolution bumps the session generation, so a callback still in flight
  cannot write a receipt for, or clear the retry of, the next same-screen request.
- A receipt is cleared when `dialogs.lua` audits the resolution. If the daemon
  dies after a post but before its callback or the durable receipt, the next
  start posts once more; a retry whose original later succeeds is one duplicate
  message and one receipt. An accepted notice cannot be retracted.
