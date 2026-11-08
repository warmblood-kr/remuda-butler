-- Durable bounded source/sidecar ingest: immutable capture, mutable progress,
-- and ack line ranges for restartable scans.
CREATE TABLE IF NOT EXISTS relay_source_capture (
  ingest_id TEXT PRIMARY KEY,
  store_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('source','sidecar')),
  role TEXT NOT NULL,
  stamp TEXT NOT NULL DEFAULT '',
  bytes INTEGER NOT NULL,
  chunk_size INTEGER NOT NULL,
  raw TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE(store_id, source_id, kind)
);
CREATE TABLE IF NOT EXISTS relay_ingest_progress (
  ingest_id TEXT PRIMARY KEY,
  store_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('source','sidecar')),
  phase TEXT NOT NULL,
  revision INTEGER NOT NULL,
  owner_id TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  byte_offset INTEGER NOT NULL DEFAULT 0,
  chunk_index INTEGER NOT NULL DEFAULT 0,
  digest_hex TEXT NOT NULL DEFAULT '',
  chunk_size INTEGER NOT NULL,
  cursor_field TEXT,
  cursor_key TEXT,
  cursor_started INTEGER NOT NULL DEFAULT 0,
  scan_offset INTEGER NOT NULL DEFAULT 0,
  line_start INTEGER NOT NULL DEFAULT 0,
  apply_offset INTEGER NOT NULL DEFAULT 0,
  applied_count INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL,
  block_reason TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS relay_ingest_progress_state
  ON relay_ingest_progress(store_id,state);
CREATE TABLE IF NOT EXISTS relay_source_ack_range (
  ingest_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  start_byte INTEGER NOT NULL,
  end_byte INTEGER NOT NULL,
  PRIMARY KEY(ingest_id,ordinal)
);
DROP TRIGGER IF EXISTS relay_capture_no_update;
CREATE TRIGGER IF NOT EXISTS relay_capture_no_update BEFORE UPDATE ON relay_source_capture
BEGIN SELECT RAISE(ABORT,'capture_immutable'); END;
DROP TRIGGER IF EXISTS relay_capture_no_delete;
CREATE TRIGGER IF NOT EXISTS relay_capture_no_delete BEFORE DELETE ON relay_source_capture
BEGIN SELECT RAISE(ABORT,'capture_immutable'); END;
DROP TRIGGER IF EXISTS relay_capture_no_duplicate;
CREATE TRIGGER IF NOT EXISTS relay_capture_no_duplicate BEFORE INSERT ON relay_source_capture
WHEN EXISTS(SELECT 1 FROM relay_source_capture c WHERE c.store_id=NEW.store_id
  AND c.source_id=NEW.source_id AND c.kind=NEW.kind)
BEGIN SELECT RAISE(ABORT,'capture_immutable'); END;
