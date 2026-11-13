-- Rebuild the 0002 shape. A plain DROP COLUMN is not portable to the SQLite
-- versions older installs may carry, and the table is small.
DROP INDEX IF EXISTS read_receipt_intents_receipt;
CREATE TABLE read_receipt_intents_0002 (
  recipient TEXT NOT NULL,
  message_id TEXT NOT NULL,
  read_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  PRIMARY KEY (recipient, message_id)
);
INSERT INTO read_receipt_intents_0002 (recipient, message_id, read_at, status)
  SELECT recipient, message_id, read_at, status FROM read_receipt_intents;
DROP TABLE read_receipt_intents;
ALTER TABLE read_receipt_intents_0002 RENAME TO read_receipt_intents;
CREATE INDEX read_receipt_intents_pending
  ON read_receipt_intents (status, recipient, message_id);
