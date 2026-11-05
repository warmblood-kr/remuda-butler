# Automatic delivery journal

Owner decision, 2026-11-05 (native same-session delivery plan, Butler side).
`packages/butler/delivery_journal.lua` is the authority for every automatic
PTY or native attempt. It is private, durable, bounded and fail-closed; the
in-memory notice maps are only a cache for the current image.

## Contract

- One entry per attempt: recipient identity id, message IDs (no count cap;
  bursts and reseeds may name hundreds), protocol `pty` or `native`, instance,
  `row.id`, nonce, generation, exact frozen body plus its SHA-256, reason,
  created/updated, and state `dispatching`, `uncertain` or `accepted_unread`.
  Endpoints, tokens and auth references are never written.
- The caller must persist `dispatching` before any bytes are written. A failed
  save, a full journal, a corrupt file or a replaced module generation returns
  no entry, so the transport write does not happen at all. There is no PTY
  fallback, no eviction of an uncertain entry and no silent reset.
- `dispatching` is a reservation: `begin` refuses a second attempt for any
  already-owned recipient/message ID (`already_reserved`). Two callbacks or a
  reload re-entering delivery cannot duplicate the same mail.
- The attempt generation is fenced. The caller captures the journal object,
  exact entry, notice module and agent, and checks them immediately before any
  raw transport, including after an audit yield. A reload during persist or a
  yield produces zero transport; the old generation cannot retire or mark
  through the replacement journal, which recovers the attempt as `uncertain`.
  A final mark/retire failure after transport raises an explicit
  `journal_resolve_failed` status and alert.
- Unknown or acknowledged-loss outcomes become `uncertain` and are reported
  once. Uncertainty is keyed by recipient identity and message ID, so a new
  instance, nonce or process does not release it. It is never cleared by the
  inbox read, a reminder, stuck-record closure, a compaction re-show, a reload
  or a full restart.
- PTY transport acceptance retires its entry, so the legacy unread reminders
  keep running. Native acceptance (future, bridge HOLD) becomes
  `accepted_unread` and is pruned only when the canonical inbox read reports
  the mail read.
- At load, every persisted `dispatching` entry becomes `uncertain`
  (`restart_before_ack`). That conversion is itself a write and must succeed
  before any unread seed or dispatch; if it cannot persist, the journal is
  globally blocked.

## Storage

- One 0600 file beside the Butler data lock, written through the core's
  atomic-private writer (`remuda.fs.write_atomic`, private). The writer must
  acknowledge an explicit `true`; nil/false means no durable write, so no
  dispatch. There is no plain-write fallback.
- Versioned JSON through the existing injected `remuda.json` codec; no custom
  format and no homemade hash: `guard_approval.sha256` covers the frozen body
  and a mismatch is corruption. The schema is strict: the root and every entry
  reject unknown keys, `entries` and every `message_ids` list must be a dense
  array (no hidden object keys, no holes), message IDs may not repeat across
  entries, and timestamps must be finite. The hash module
  (`guard_approval.sha256`) loads later than this journal in `main.lua`, so
  digest verification is deferred rather than calling a valid persisted journal
  corrupt: the entries load, suppression still works, and the first dispatch is
  blocked (`hash_unavailable`) until the real hash verifies every body. The
  byte cap is checked on the file before decoding. Missing codec or hash, any
  schema violation or a decoding error fails closed with an explicit reason;
  the corrupt file is never rewritten automatically.
- Bounded by serialized bytes (`cap_bytes`, default 512 KiB) plus a per-entry
  body cap; no arbitrary message-ID or entry-count cap (the 556 regression
  removed the old 16). A full journal is a GLOBAL fail-closed gate: it blocks
  every automatic dispatch, not only the one that did not fit, until entries
  are retired (PTY accepted) or pruned (native read) to free capacity.
## Status and recovery

- `remuda butler doctor` shows read-only counts, ages, IDs and reasons, never
  a body or secret. No mutating reconcile CLI; recovery is an operator action
  (inspect the target, then explicit Butler mail). An original ID is never
  released automatically.
- A full restart rereads disk and keeps uncertainty/reservations. Accepted PTY
  entries were already retired, so those notices keep the at-least-once
  reminder behavior.

## Tests

`tests/butler_delivery_journal.lua` injects clock, storage, codec and hash and
covers crash before/after acknowledgement, full restart, canonical read,
reshow, stuck closure, new instance/nonce, byte cap, save failure, corruption,
reservation, native accepted until read and PTY retirement. The notice suites
reuse `tests/notice_journal_stub.lua` and add a 128-ID positive control.
