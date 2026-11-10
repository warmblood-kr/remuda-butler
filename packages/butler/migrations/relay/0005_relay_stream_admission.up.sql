-- Bounded streaming admission. Chunks are staged one <=64KiB call at a time
-- and assembled into the immutable relay_source_capture by SQL, so no whole
-- source enters Lua or a bound SQL parameter.
CREATE TABLE IF NOT EXISTS relay_source_stage (
  ingest_id TEXT PRIMARY KEY,
  store_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('source','sidecar')),
  role TEXT NOT NULL,
  stamp TEXT NOT NULL DEFAULT '',
  expected_bytes INTEGER NOT NULL,
  written_bytes INTEGER NOT NULL DEFAULT 0,
  parts INTEGER NOT NULL DEFAULT 0,
  state TEXT NOT NULL CHECK(state IN ('staging','ready')),
  created_at TEXT NOT NULL,
  UNIQUE(store_id, source_id, kind)
);
CREATE TABLE IF NOT EXISTS relay_source_chunk (
  ingest_id TEXT NOT NULL,
  part INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  digest TEXT NOT NULL,
  chunk TEXT NOT NULL,
  PRIMARY KEY(ingest_id,part)
);
DROP TRIGGER IF EXISTS relay_stage_no_duplicate;
CREATE TRIGGER IF NOT EXISTS relay_stage_no_duplicate BEFORE INSERT ON relay_source_stage
WHEN EXISTS(SELECT 1 FROM relay_source_stage s WHERE s.ingest_id=NEW.ingest_id
  OR (s.store_id=NEW.store_id AND s.source_id=NEW.source_id AND s.kind=NEW.kind))
BEGIN SELECT RAISE(ABORT,'stage_immutable'); END;
