-- Revert to the stage-2 child shapes (empty: a narrower key cannot be derived
-- from root-scoped rows without guessing a writer).
DROP INDEX IF EXISTS progress_deliveries_order;
DROP TABLE IF EXISTS progress_deliveries;
CREATE TABLE progress_deliveries (
  recipient   TEXT NOT NULL,
  generation  TEXT NOT NULL,
  message_id  TEXT NOT NULL,
  seq         INTEGER NOT NULL,
  resent_json TEXT,
  PRIMARY KEY (recipient, generation, message_id)
);
CREATE UNIQUE INDEX progress_deliveries_order
  ON progress_deliveries (recipient, generation, seq);

DROP TABLE IF EXISTS progress_reads;
CREATE TABLE progress_reads (
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY (recipient, generation, message_id)
);

DROP TABLE IF EXISTS progress_metadata;
CREATE TABLE progress_metadata (
  recipient    TEXT NOT NULL,
  generation   TEXT NOT NULL,
  message_id   TEXT NOT NULL,
  envelope_ref TEXT NOT NULL,
  object_ref   TEXT NOT NULL,
  metadata     TEXT NOT NULL,
  PRIMARY KEY (recipient, generation, message_id)
);

DROP TABLE IF EXISTS progress_dependencies;
CREATE TABLE progress_dependencies (
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  owner      TEXT NOT NULL,
  role       TEXT NOT NULL,
  path       TEXT NOT NULL,
  PRIMARY KEY (recipient, generation, owner, role)
);

DROP TABLE IF EXISTS progress_fileproofs;
CREATE TABLE progress_fileproofs (
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  pass       INTEGER NOT NULL,
  path       TEXT NOT NULL,
  present    INTEGER NOT NULL,
  bytes      INTEGER NOT NULL,
  sha256     TEXT NOT NULL,
  PRIMARY KEY (recipient, generation, pass, path)
);

DROP TABLE IF EXISTS progress_chunkproofs;
CREATE TABLE progress_chunkproofs (
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  pass       INTEGER NOT NULL,
  path       TEXT NOT NULL,
  offset     INTEGER NOT NULL,
  bytes      INTEGER NOT NULL,
  sha256     TEXT NOT NULL,
  eof        INTEGER NOT NULL,
  PRIMARY KEY (recipient, generation, pass, path, offset)
);
