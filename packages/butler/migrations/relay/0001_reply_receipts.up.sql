CREATE TABLE reply_receipts (
  reply_id TEXT PRIMARY KEY,
  txn_id TEXT NOT NULL UNIQUE,
  source_mail_id TEXT NOT NULL,
  event_id TEXT,
  status TEXT NOT NULL,
  completed_at TEXT NOT NULL,
  result_json TEXT
);

CREATE TABLE receipt_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR REPLACE INTO receipt_meta (key, value) VALUES ('receipt_authority', 'shadow');
