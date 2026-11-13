-- Stable receipt identity. A receipt message ID is a normal Butler ULID,
-- generated once and stored in the intent that already commits with the read.
-- The drain reuses it on every retry, so the mailbox and any notification see
-- one fixed message identity even across a crash.
ALTER TABLE read_receipt_intents ADD COLUMN receipt_id TEXT;
-- The exact receipt text is fixed once, so a retry after a body-only crash
-- cannot compute a different body from a changed alias or profile.
ALTER TABLE read_receipt_intents ADD COLUMN receipt_body TEXT;
-- A deferred Matrix intent stays `pending` for the relay slice but sorts after
-- undelivered local intents, so a Matrix backlog cannot starve local receipts.
ALTER TABLE read_receipt_intents ADD COLUMN deferred_at TEXT;

-- A receipt ULID may not be reused by another intent. Partial so pre-existing
-- rows (claimed lazily by the first drain) remain valid.
CREATE UNIQUE INDEX read_receipt_intents_receipt
  ON read_receipt_intents (receipt_id) WHERE receipt_id IS NOT NULL;
