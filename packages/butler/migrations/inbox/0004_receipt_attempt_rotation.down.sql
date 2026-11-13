DROP INDEX IF EXISTS read_receipt_intents_rotation;
DROP TABLE IF EXISTS receipt_attempt_seq;
-- Rebuild the 0003 shape. A plain DROP COLUMN is not portable to the SQLite
-- versions older installs may carry, and the table is small.
DROP INDEX IF EXISTS read_receipt_intents_receipt;
CREATE TABLE read_receipt_intents_0003 (
  recipient TEXT NOT NULL,
  message_id TEXT NOT NULL,
  read_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  receipt_id TEXT,
  receipt_body TEXT,
  deferred_at TEXT,
  PRIMARY KEY (recipient, message_id)
);
INSERT INTO read_receipt_intents_0003
  (recipient, message_id, read_at, status, receipt_id, receipt_body, deferred_at)
  SELECT recipient, message_id, read_at, status, receipt_id, receipt_body, deferred_at
  FROM read_receipt_intents;
DROP TABLE read_receipt_intents;
ALTER TABLE read_receipt_intents_0003 RENAME TO read_receipt_intents;
CREATE UNIQUE INDEX read_receipt_intents_receipt
  ON read_receipt_intents (receipt_id) WHERE receipt_id IS NOT NULL;
CREATE INDEX read_receipt_intents_pending
  ON read_receipt_intents (status, recipient, message_id);
