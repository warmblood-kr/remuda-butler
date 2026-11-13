-- Durable audition order for pending receipts. A monotonic attempt sequence
-- rotates deferred rows without relying on wall-clock resolution: NULL means
-- not tried yet and sorts first, then the oldest attempt.
ALTER TABLE read_receipt_intents ADD COLUMN attempt_seq INTEGER;
CREATE INDEX read_receipt_intents_rotation
  ON read_receipt_intents (status, attempt_seq);

-- Single-writer sequence. One daemon owns the inbox while draining; a crash
-- between the bump and the row update only skips a value.
CREATE TABLE receipt_attempt_seq (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  value INTEGER NOT NULL
);
INSERT OR IGNORE INTO receipt_attempt_seq (id, value) VALUES (1, 0);
