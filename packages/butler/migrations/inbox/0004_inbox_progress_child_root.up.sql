-- Full root isolation: every staging child row carries the source root, so a
-- second root on the same borrowed handle can never read or overwrite another
-- root's staged rows for the same recipient/generation. Staging rows are
-- rebuildable; the #585 authority tables are untouched.
DROP TABLE IF EXISTS progress_deliveries;
CREATE TABLE progress_deliveries (
  root        TEXT NOT NULL,
  recipient   TEXT NOT NULL,
  generation  TEXT NOT NULL,
  message_id  TEXT NOT NULL,
  seq         INTEGER NOT NULL,
  resent_json TEXT,
  PRIMARY KEY (root, recipient, generation, message_id)
);
CREATE UNIQUE INDEX progress_deliveries_order
  ON progress_deliveries (root, recipient, generation, seq);

DROP TABLE IF EXISTS progress_reads;
CREATE TABLE progress_reads (
  root       TEXT NOT NULL,
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY (root, recipient, generation, message_id)
);

DROP TABLE IF EXISTS progress_metadata;
CREATE TABLE progress_metadata (
  root         TEXT NOT NULL,
  recipient    TEXT NOT NULL,
  generation   TEXT NOT NULL,
  message_id   TEXT NOT NULL,
  envelope_ref TEXT NOT NULL,
  object_ref   TEXT NOT NULL,
  metadata     TEXT NOT NULL,
  PRIMARY KEY (root, recipient, generation, message_id)
);

DROP TABLE IF EXISTS progress_dependencies;
CREATE TABLE progress_dependencies (
  root       TEXT NOT NULL,
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  owner      TEXT NOT NULL,
  role       TEXT NOT NULL,
  path       TEXT NOT NULL,
  PRIMARY KEY (root, recipient, generation, owner, role)
);

DROP TABLE IF EXISTS progress_fileproofs;
CREATE TABLE progress_fileproofs (
  root       TEXT NOT NULL,
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  pass       INTEGER NOT NULL,
  path       TEXT NOT NULL,
  present    INTEGER NOT NULL,
  bytes      INTEGER NOT NULL,
  sha256     TEXT NOT NULL,
  PRIMARY KEY (root, recipient, generation, pass, path)
);

DROP TABLE IF EXISTS progress_chunkproofs;
CREATE TABLE progress_chunkproofs (
  root       TEXT NOT NULL,
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  pass       INTEGER NOT NULL,
  path       TEXT NOT NULL,
  offset     INTEGER NOT NULL,
  bytes      INTEGER NOT NULL,
  sha256     TEXT NOT NULL,
  eof        INTEGER NOT NULL,
  PRIMARY KEY (root, recipient, generation, pass, path, offset)
);
