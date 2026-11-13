# Local read-receipt delivery

Outcome: a member fetches a message and the sender gets one automatic
acknowledgment in its own mailbox.

This is the local SQLite slice (A2); Matrix delivery is A3.

## Identity and durability

- A1 records one `pending` row per real unread→read transition, in the read
  transaction.
- `inbox/0003` adds `receipt_id` and `receipt_body`. The id is a Butler ULID
  committed with the intent, so the receipt is ordinary mail; the partial
  unique index and fixed body make a retry one identity.
- A direct caller without an id stores **NULL**, not `''`; a pre-0003 row is
  claimed once by the first drain.
- `intent.read_at` fixes `created_at`, so a retry produces the same bytes.
- The receipt names the canonical reader, not the envelope `to` alias, so a
  forwarded copy names the actual reader.

## Eligibility

The scan joins `simple_inbox` on `(recipient, message_id)`; `recipient` is the
hex reader id.

- **eligible:** local envelope with a `from.id`, sender != reader, no
  structured `receipt_of`.
- **skipped:** `receipt_of` present, reserved `schedule`/system sender,
  self-mail, no sender ULID, non-local non-Matrix sender.
- **deferred:** Matrix sender or route metadata. `deferred_at` sorts it after
  local work; it stays `pending` for A3. No Matrix I/O here.
- An unreadable/missing envelope stays pending, never reported as delivered.

The recursion guard is the structured `receipt_of` in the stored envelope,
parsed by `load_message` and kept across restart. Content text is never the
guard.

## Crash-safe delivery

`mail.queue` grew `queue_receipt`. An existing message at the fixed ULID is
reused only when `receipt_of`, sender/recipient ULIDs, subject, time and body
match; display aliases are not identity. An unrelated message is a collision.

1. body only: identical content is reused; different content is a collision,
   then the envelope is written.
2. body + envelope without a row: verified envelope reused, row inserted.
3. row present: `already=true`; no rewrite, no new notice.
4. content conflict: error, terminally failed, no false success.

Only after the row is durable does the drain set `status='delivered'`. A crash
between acceptance and that mark is a verified retry, not a duplicate.

## Failure fairness

A permanent collision/conflict becomes `failed`; a retryable error stays
`pending` with `deferred_at`, behind newer work. Permanent failures do not
consume the batch. `0004` adds `attempt_seq` and a single-writer sequence: each
pending attempt takes the next number (NULL first), so a Matrix/transient page
rotates at equal timestamps, restart or 100+ rows; a failed sequence write is
diagnosed but delivery continues. Non-deferred arrivals always sort first, so
an unbounded stream of them can delay deferred work. SQLite owns intents and
`simple_inbox`; files store bodies; a file-only install has no intents.

## Single-message view

`remuda butler inbox <message-id>` for the authenticated owner marks only that
message read and creates the same intent in one SQLite transaction, then drains
the receipt immediately. Re-viewing an already-read message renders it without
another intent or receipt; another member's id is refused and creates none.
The legacy Rust shim has no caller identity and stays fail-closed; a file-only
install marks read in the file log but has no intent or receipt.

## Notification

After every durable acceptance, including an accepted-but-unmarked retry, the
module asks `notify_mail_delivery` to type "read receipt for <original id>".
The sender is resolved by ULID: a rename follows, a reused alias fails closed
and cannot clear another member's `--done`. The journal reserves
`(recipient, message_id)`, so a retry recovers or refuses a duplicate. Unread
mail reseeds after restart; a read receipt is skipped.

## Evidence

- `tests/butler_read_receipt_delivery.lua` (fast, isolated): receipt/notice;
  batch; restart; crash before status/notice (retry completes and re-asks);
  fixed body; collision; 50 failures then normal; 50 deferred then recovered;
  120 deferred over three ticks; forwarded reader; Matrix pending; file-only
  no-op.
- `tests/lua/butler_inbox_caller_identity_test.lua`: real notice path with a
  renamed then reused alias (correct target, no wrong `--done`), and a real
  forwarded mail whose receipt names the actual reader.
- `tests/read_receipt_upgrade.sh`: real SQLite v3 upgrade/downgrade, real drain,
  ULID/body correlation, NULL ids, second restart stable.
- `tests/butler_simple_inbox_acceptance.sh`: real SQLite inbox across restarts.

## Not in this slice

Matrix reply/outbox delivery, uncertain-send retry policy, receipt status
display, and re-acknowledgment of already-skipped intents.
