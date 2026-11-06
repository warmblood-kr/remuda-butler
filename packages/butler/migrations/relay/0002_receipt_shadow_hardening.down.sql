-- Rebuild the phase-1 table so the added columns are removed cleanly. A plain
-- DROP COLUMN is not available on every SQLite build the mod supports.
--
-- Guarantee: the phase-1 receipt columns (id, txn, source, event, status,
-- completed_at, result) are preserved. The added provenance/canonical witness
-- and the derived conflict log are intentionally discarded; downgrade is not a
-- promise to keep phase-2-only evidence.
DROP TABLE IF EXISTS receipt_conflicts;

CREATE TABLE reply_receipts_down (
  reply_id TEXT PRIMARY KEY,
  txn_id TEXT NOT NULL UNIQUE,
  source_mail_id TEXT NOT NULL,
  event_id TEXT,
  status TEXT NOT NULL,
  completed_at TEXT NOT NULL,
  result_json TEXT
);

INSERT INTO reply_receipts_down
  (reply_id, txn_id, source_mail_id, event_id, status, completed_at, result_json)
SELECT reply_id, txn_id, source_mail_id, event_id, status, completed_at, result_json
  FROM reply_receipts;

DROP TABLE reply_receipts;
ALTER TABLE reply_receipts_down RENAME TO reply_receipts;
