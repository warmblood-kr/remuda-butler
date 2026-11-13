# Read-receipt delivery

Outcome: a fetch sends the sender one automatic acknowledgment, locally or as
a threaded Matrix reply.

## Identity and durability

- A1 records one `pending` row per unread→read transition.
- `inbox/0003` adds `receipt_id`/`receipt_body`; the ULID + partial unique index
  + fixed body make a retry one identity. A caller without an id stores **NULL**.
- `intent.read_at` fixes `created_at`; a retry is byte-identical.
- The reader is the canonical id, not the envelope `to` alias, so a forward
  names the actual reader.
- `inbox/0004` adds `attempt_seq` and a single-writer sequence for rotation.
- `inbox/0005` adds the relay projection (state/txn/event/updated/error).

## Eligibility

The scan joins `simple_inbox` on `(recipient, message_id)`; `recipient` is the
hex reader id.

- **local eligible:** non-empty `from.id`, sender != reader, no `receipt_of`.
- **skipped:** `receipt_of`, schedule/system sender, self-mail, no sender ULID,
  non-local non-Matrix sender.
- **Matrix:** a route from an allowlisted human; durable envelope flags
  (`from_agent=false`, `allowlisted_human=true`) are the trimmed-route
  fallback, else fail closed.
- An unreadable envelope stays pending.

The guard is structured `receipt_of`, never content text.

## Local crash-safe delivery

`queue_receipt` reuses a message at the fixed ULID only when `receipt_of`,
sender/recipient ULIDs, subject, time and body match.

Identical bytes are reused; a differing body is a collision. An existing row
is `already=true` with no rewrite or notice; only after the row is durable does
the drain set `delivered`.

## Failure fairness

A permanent collision/conflict becomes `failed`; a retryable error stays
`pending` with `deferred_at`. `0004` adds `attempt_seq` and a single-writer
sequence: each attempt takes the next number (NULL first), so a page rotates at
equal timestamps, restart or 100+ rows. A failed sequence write is diagnosed
but delivery continues. Non-deferred arrivals sort first, so an unbounded
stream can delay deferred work.

## Single-message view

`remuda butler inbox <id>` for the owner marks only that message read and
creates the same intent in one transaction, then drains immediately. A re-view
renders it without another intent or receipt; another member's id is refused.
The Rust shim has no caller identity; a file-only install marks read but
creates no intent.

## Notification

After every durable acceptance, including an accepted-but-unmarked retry, the
module asks `notify_mail_delivery` to type "read receipt for <original id>".
The sender resolves by ULID: a rename follows, a reused alias fails closed. The
journal reserves `(recipient, message_id)` to recover or refuse a duplicate.
Unread mail reseeds; a read receipt is skipped.

## Matrix delivery

A deferred Matrix intent drains on the same 30 s tick after the local pass
through the relay outbox.

- `reply_id`/`reply_mail_id` are the receipt ULID; `txn_id` is
  `butler_<receipt_id>`, so a retry reuses the homeserver idempotency.
- `io.butler.receipt_of`/`io.butler.receipt` are structured fields persisted in
  the outbox. Only agent/Butler senders may mark an inbound event as a receipt
  echo; it never becomes mail. Body text is not the guard, so a person writing
  "Read receipt:" still gets mail.
- Machine receipts skip the b2b slot and own-turn accounting; the mail writer
  copies the durable envelope flags and the reload parses them.
- The local drain uses a matrix-free query; the Matrix drain reads the full
  projection, so durable evidence is never missed.
- Durable state wins over missing relay evidence: `delivered` marks delivered
  without a send; `queued` whose evidence is gone becomes `uncertain` and is
  never resent; status/projection failures never send; identity reuse is
  refused.
- Downgrading 5→4 drops the Matrix projection: unresolved `queued`/`uncertain`
  evidence is lost. Do not downgrade while Matrix receipts are unresolved; A2
  shape/rotation survive.

## Evidence

- `butler_read_receipt_delivery.lua` (fast): receipt/notice; batch; restart;
  crash before status/notice; fixed body; collision; 50 failures then normal;
  50 deferred then recovered; 120 deferred over three ticks; forwarded reader;
  Matrix pending; file-only no-op.
- `butler_matrix_read_receipts.lua` (L3): threaded reply/guard, re-drain, real
  save/reload after route trim, lost evidence, write/status failures,
  post-acceptance throw, collisions, echo filter.
- `butler_inbox_caller_identity_test.lua`: notice rename/reuse/forward;
  single-message read/re-view, cross-member refusal, SQLite failure retry,
  deferred Matrix intent.
- `read_receipt_upgrade.sh`: SQLite v5 5→4 (populated drain), 4→5, and a real
  queued/uncertain Matrix intent that must not resend.
- `butler_simple_inbox_acceptance.sh`: real SQLite inbox across restarts.

## Not in this slice

Receipt status display, operator retry of `failed`/`uncertain`, and
re-acknowledging skipped intents.
