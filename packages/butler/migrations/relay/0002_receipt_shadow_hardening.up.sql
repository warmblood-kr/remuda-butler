-- Shadow-hardening columns and conflict log for reply receipts.
--
-- Phase 1 remains a shadow: the JSON relay state is authoritative. This
-- migration only makes the shadow able to say whether two receipts are really
-- equal, where a txn id came from, and why a write was rejected. It adds no
-- read authority and no send-path behavior.
ALTER TABLE reply_receipts ADD COLUMN txn_origin TEXT NOT NULL DEFAULT 'legacy';
ALTER TABLE reply_receipts ADD COLUMN receipt_canonical TEXT;

-- Derivable backfill; never rewrite a txn id. A completed receipt alone does
-- not prove which attempt produced it, so a derived id is historical here.
-- Only a live `record` call can claim `live`.
UPDATE reply_receipts SET txn_origin = 'legacy'
 WHERE txn_id LIKE 'legacy\_%' ESCAPE '\'
   AND substr(txn_id, 8) = reply_id;
UPDATE reply_receipts SET txn_origin = 'historical'
 WHERE txn_origin = 'legacy'
   AND txn_id <> ''
   AND txn_id <> 'legacy_' || reply_id;
UPDATE reply_receipts SET txn_origin = 'unclassified'
 WHERE txn_id IS NULL OR trim(txn_id) = '' OR txn_id GLOB '*[^ -~]*';

-- Append-only: two detections of the same class are two facts, not one row to
-- overwrite. A later repair must not erase the earlier evidence.
CREATE TABLE receipt_conflicts (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  reply_id       TEXT NOT NULL,
  other_reply_id TEXT,
  txn_id         TEXT,
  class          TEXT NOT NULL,
  detail         TEXT,
  detected_at    TEXT NOT NULL
);

CREATE INDEX receipt_conflicts_reply ON receipt_conflicts(reply_id, class);
