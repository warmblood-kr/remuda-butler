-- Rebuild the 0004 shape: drop only the Matrix projection columns while
-- preserving the A2 attempt-rotation column, its index and sequence table.
DROP INDEX IF EXISTS read_receipt_intents_receipt;
DROP INDEX IF EXISTS read_receipt_intents_rotation;
CREATE TABLE read_receipt_intents_0004 (
  recipient TEXT NOT NULL,
  message_id TEXT NOT NULL,
  read_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  receipt_id TEXT,
  receipt_body TEXT,
  deferred_at TEXT,
  attempt_seq INTEGER,
  PRIMARY KEY (recipient, message_id)
);
INSERT INTO read_receipt_intents_0004
  (recipient, message_id, read_at, status, receipt_id, receipt_body, deferred_at, attempt_seq)
  SELECT recipient, message_id, read_at, status, receipt_id, receipt_body, deferred_at, attempt_seq
  FROM read_receipt_intents;
DROP TABLE read_receipt_intents;
ALTER TABLE read_receipt_intents_0004 RENAME TO read_receipt_intents;
CREATE UNIQUE INDEX read_receipt_intents_receipt
  ON read_receipt_intents (receipt_id) WHERE receipt_id IS NOT NULL;
CREATE INDEX read_receipt_intents_pending
  ON read_receipt_intents (status, recipient, message_id);
CREATE INDEX read_receipt_intents_rotation
  ON read_receipt_intents (status, attempt_seq);
