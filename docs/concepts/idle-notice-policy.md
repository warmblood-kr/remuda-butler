# Automatic mail wakeups

Owner decision, 2026-11-03 (supersedes the 2026-10-16/10-19 admission rules):
an automatic mail wakeup no longer depends on predicting the recipient's
composer, idle state or dialogs. Butler sends one ordinary atomic write (text
plus Return) per coalesced notice, through the dialogs module's narrow
`automatic_notice_send` capability. That capability bypasses only the modal
*prediction* gate, and only for generated notice text (`Butler message ...` or
`N new Butler message(s) ...`) with the queued message IDs. Every general
`send`, `type_text` and `key` still passes `M.check`; startup, first-task and
owner-approved typing policies are unchanged.

## What remains

- A preflight before the write: the agent record exists, the session row is
  alive, and a bound `agent.instance_id` matches the row's instance (a missing
  row instance is refused, never assumed). Attachment, busy state and composer
  contents are not admission gates (owner decision 2026-11-05). The audit append
  can yield, so the same checks, the same agent object, the same captured
  instance, the dialogs module generation and identity (`butler.dialogs == M`,
  `_installed`) are rechecked immediately before the raw write. The capability
  is audited as `automatic-mail-wakeup` / `transport_only`, with a
  transport-only result.
- A pending delegated first task keeps mail queued until the task clears. A
  picker or any other dialog no longer holds an automatic notice.
- 2-second quiet / 10-second cap coalescing and the unread reminder.
- The bounded retry schedule (20s, 60s, 300s, 900s) for a refusal that wrote
  nothing, then one failure alert naming the message IDs.
- A durable, bounded journal (`docs/concepts/notice-delivery-journal.md`):
  every automatic PTY or native attempt is DISPATCHING on disk before any bytes
  are written, keyed by recipient identity id and message id. An outcome that
  may have written bytes is reported once with the IDs, opens the stuck record,
  and becomes UNCERTAIN. Uncertainty is never cleared by an inbox read, a
  reminder, stuck-record closure, a compaction re-show, a reload or a full
  restart, and a new session instance or nonce does not release it. New message
  IDs still notify. A full journal, failed save or corrupt file blocks every
  automatic write with an explicit reason and an alert; there is no eviction
  and no PTY bypass. DISPATCHING itself reserves the IDs, so re-entry cannot
  create a second attempt for the same mail. PTY transport acceptance retires
  its entry (legacy reminders continue); a native `accepted_unread` entry stays
  until the canonical inbox read.
- Durable mail: transport acceptance is not a read. Only an inbox read marks a
  message read. Journal-uncertain mail is never re-nudged, even by a restart;
  other still-unread mail may be re-seeded after a restart (at-least-once for
  accepted-but-unread, not exactly-once).

## Consequences accepted by the owner

- A detached human draft is concatenated with the notice and submitted, for
  OpenCode, Codex and Claude Code. Butler never clears, escapes or restores a
  composer. Low-value drafts may be lost; that was traded for delivery.
- A notice typed into a busy OpenCode or Codex turn can steer or queue into
  that turn: the recipient may treat the notice as mid-turn input. Real QA saw
  the text concatenate with a detached draft and submit; it did not fail.
- A known approval/model dialog no longer holds automatic mail. General
  owner/agent writes stay gated by the audited dialog dispatcher.
- A human attaching, or a session name being reused, between the preflight and
  the name-addressed core write is not excluded atomically. There is no
  expected-instance-bound send word on this core; the residual race is
  documented rather than claimed away. A core refusal naming attachment is an
  explicit transport limitation, retried like busy, not a policy gate.
- Journal uncertainty favors a missed reminder over a duplicate write. A
  corrupt or unwritable journal therefore stops automatic wakeups (explicit
  status and alert) until an operator inspects it.

## History

The old notice path required a recognized empty composer (a dim ghost
suggestion counted as empty), waited for attached humans to pause, predicted
known modals, probed, verified the composer, retried one Return, and failed an
attempt after 20 seconds. Two false positives (a ghost suggestion read as a
draft, and a quoted Teach title read as a modal) plus OpenCode's working-screen
tool panels read as a 9-10 KB draft held and then dropped notices. The parser,
first-task and owner-approved policies keep their own tests; only the
automatic-notice path changed.
