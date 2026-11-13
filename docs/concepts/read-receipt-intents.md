# Durable read-receipt intents

Owner-facing outcome: the original sender receives an automatic read receipt
when a member fetches their message. This note covers only the first slice:
durable intent storage. Delivery is not implemented yet.

## Where it lives

`packages/butler/migrations/inbox/0002_read_receipt_intents` adds
`read_receipt_intents` to the same SQLite database as `simple_inbox`. That is
the authoritative inbox when `remuda.db` is available. The file inbox remains
the fallback.

Columns: `recipient`, `message_id`, `read_at`, `status` (`pending` by default).
`(recipient, message_id)` is the primary key. A pending index supports the
later delivery scan.

## Atomic rule

`inbox_sqlite_simple.mark_read` writes both statements; `mail.inbox` already
opens one `BEGIN IMMEDIATE` for a batch and commits once.

1. `INSERT OR IGNORE INTO read_receipt_intents ... SELECT ... WHERE is_read = 0`
2. `UPDATE simple_inbox SET is_read = 1 ... WHERE is_read = 0`

The insert runs first, while the row is still unread. Both commit or neither.
If the intent insert, read update or commit fails, `mail.inbox` rolls back and
returns `mail read-state was not saved`; the message stays unread and no intent
survives.

## Caller provenance

Only the mailbox owner reading their own inbox creates an intent. The read
entry points pass the caller's resolved identity:

- `remuda butler inbox` / named inbox: `commands.lua` passes
  `caller_identity` from the daemon caller snapshot; an operator has none.
- MCP `butler_inbox`: passes the resolved member principal.
- `remuda._butler_inbox(name, reader)` resolves `reader` to an id and passes
  `reader_id` to `mail.inbox`.
- `remuda butler inbox <message-id>` (`_butler_inbox_message`) resolves the
  caller and reads only that message with `mail.inbox(owner, { reader_id =
  owner, only = id })`; an unread message creates the intent, an already-read
  one does not.

The legacy Rust CLI shim (`cli/butler_cli.rs`) intentionally passes no reader:
it has no daemon caller-session identity, and the environment is not a receipt
trust basis. A read through that shim saves read state but creates no intent;
the single-message form also requires a caller identity, so the shim cannot
claim one.
The Lua command path can claim an agent read.

`mail.inbox(name, { reader_id = ... })` sets `receipt = true` only when
`reader_id == name`. An operator read (`reader_id = nil`) or a different
member's read still saves `is_read = 1`, but writes no intent. A direct
`mail.inbox(name)` with no opts keeps the historical "owner is reading"
default for the storage tests.

## Guarantees

- **No backfill:** legacy import writes `simple_inbox.is_read = 1` directly. The
  intent table starts empty, and the conditional insert only sees unread rows.
- **No duplicate:** a second read finds no unread row; the primary key is a
  second guard.
- **Agent-only:** operator and cross-member reads leave no intent row, so an
  existing pending row means the owner read it.
- **No false receipt on a failed read:** same transaction.
- **Durability:** after a crash following commit, the intent remains pending.
- **Fallback:** file-only installs keep the existing read log and create no
  intents. There is no atomic SQLite transaction to join there.

## Deliberately not in this slice

This note covers intent storage only. Delivery is now described in
`read-receipt-delivery.md`: the local SQLite slice drains eligible intents,
suppresses receipt/schedule/system/self/unaddressable mail, and leaves Matrix
intents pending. The current row carries no sender copy, so delivery joins
`simple_inbox.envelope` rather than migrating sender data.

The single-message `inbox <message-id>` path still only re-displays a message
and deliberately does not change read state, so it creates no intent. Making it
mark read is a separate behavior decision.

## Evidence

- `tests/butler_read_receipt_intents.lua` drives the real `mail.inbox` and
  `mark_read` path through a SQLite-shaped fake: new read, duplicate read,
  restart, failed commit, failed intent insert, no backfill, agent own read,
  operator read and cross-member read.
- `tests/lua/butler_inbox_caller_identity_test.lua` exercises the real agent
  command path and asserts the operator's read of another member's inbox
  leaves no intent. It also covers the single-message re-display (no read, no
  intent) and the legacy one-argument API (read saved, no intent claimed).
- `tests/read_receipt_upgrade.sh` creates a real v2 inbox with existing data,
  steps it back to v1 with the stored down SQL, restarts Butler, and verifies
  the real 0001→0002 upgrade, preserved read state, no backfill, agent-only
  intents and a second restart.
- `tests/butler_simple_inbox_acceptance.lua` uses the isolated private daemon
  and asserts the real table across two process restarts.
- Manual `sqlite3` check of the migration and both statements confirmed one
  intent for a new read, none for an old/rolled-back read.
