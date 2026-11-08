-- Resumable source staging for the inbox authority (stage 2).
-- Rows are bounded records; no whole-mailbox JSON/blob state is stored here.
CREATE TABLE progress_state (
  recipient   TEXT NOT NULL,
  generation  TEXT NOT NULL,
  revision    INTEGER NOT NULL,
  cursor_json TEXT NOT NULL,
  PRIMARY KEY (recipient)
);

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

CREATE TABLE progress_reads (
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY (recipient, generation, message_id)
);

CREATE TABLE progress_metadata (
  recipient    TEXT NOT NULL,
  generation   TEXT NOT NULL,
  message_id   TEXT NOT NULL,
  envelope_ref TEXT NOT NULL,
  object_ref   TEXT NOT NULL,
  metadata     TEXT NOT NULL,
  PRIMARY KEY (recipient, generation, message_id)
);

CREATE TABLE progress_dependencies (
  recipient  TEXT NOT NULL,
  generation TEXT NOT NULL,
  owner      TEXT NOT NULL,
  role       TEXT NOT NULL,
  path       TEXT NOT NULL,
  PRIMARY KEY (recipient, generation, owner, role)
);

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
