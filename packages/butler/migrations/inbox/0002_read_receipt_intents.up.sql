-- Durable intent to acknowledge a message that this read made read. The read
-- update and this row are written by one caller transaction; a failed read
-- leaves neither. Only a real unread -> read transition inserts a row, so
-- imported/backfilled read state is never replayed as a receipt.
CREATE TABLE read_receipt_intents (
  recipient TEXT NOT NULL,
  message_id TEXT NOT NULL,
  read_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  PRIMARY KEY (recipient, message_id)
);

-- Delivery scans pending intents without touching the read-state table.
CREATE INDEX read_receipt_intents_pending
  ON read_receipt_intents (status, recipient, message_id);
