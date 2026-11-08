-- Full Store Phase B: durable FILE_TRACKED admission, per-mailbox sealed
-- prefix offsets, bounded mutation journal/tail and the precomputed
-- certificate/ready rows consumed by C. Additive to 0001-0006.
CREATE TABLE migration_state (
  root       TEXT NOT NULL,
  generation TEXT NOT NULL,
  epoch      INTEGER NOT NULL,
  protocol   TEXT NOT NULL,
  revision   INTEGER NOT NULL,
  PRIMARY KEY (root)
);

-- A non-newline tail is excluded from the sealed end and recorded as torn; it
-- is never skipped silently or treated as ready.
CREATE TABLE migration_prefix (
  root        TEXT NOT NULL,
  generation  TEXT NOT NULL,
  recipient   TEXT NOT NULL,
  inbox_end   INTEGER NOT NULL,
  read_end    INTEGER NOT NULL,
  inbox_torn  INTEGER NOT NULL,
  read_torn   INTEGER NOT NULL,
  revision    INTEGER NOT NULL,
  cursor_json TEXT NOT NULL,
  complete    INTEGER NOT NULL,
  PRIMARY KEY (root, generation, recipient)
);

-- Durable admission intent written BEFORE the legacy append. Tracking intent is
-- never delivery/read authority.
CREATE TABLE migration_intents (
  root            TEXT NOT NULL,
  generation      TEXT NOT NULL,
  sequence        INTEGER NOT NULL,
  mutation_id     TEXT NOT NULL,
  recipient       TEXT NOT NULL,
  kind            TEXT NOT NULL,
  path            TEXT NOT NULL,
  before_offset   INTEGER NOT NULL,
  bytes_hash      TEXT NOT NULL,
  expected_length INTEGER NOT NULL,
  operation_id    TEXT NOT NULL,
  message_id      TEXT,
  payload_hash    TEXT,
  state           TEXT NOT NULL,
  PRIMARY KEY (root, generation, mutation_id)
);
CREATE UNIQUE INDEX migration_intents_sequence
  ON migration_intents (root, generation, sequence);

-- Applied ordered tail: original mutation identity plus the surviving range.
CREATE TABLE migration_tail (
  root             TEXT NOT NULL,
  generation       TEXT NOT NULL,
  sequence         INTEGER NOT NULL,
  mutation_id      TEXT NOT NULL,
  kind             TEXT NOT NULL,
  recipient        TEXT NOT NULL,
  message_id       TEXT,
  operation_id     TEXT,
  payload_hash     TEXT,
  path             TEXT NOT NULL,
  before_offset    INTEGER NOT NULL,
  bytes            INTEGER NOT NULL,
  bytes_hash       TEXT NOT NULL,
  applied_revision INTEGER NOT NULL,
  PRIMARY KEY (root, generation, mutation_id)
);
CREATE UNIQUE INDEX migration_tail_sequence
  ON migration_tail (root, generation, sequence);

CREATE TABLE migration_tail_state (
  root       TEXT NOT NULL,
  generation TEXT NOT NULL,
  watermark  INTEGER NOT NULL,
  tail_hash  TEXT NOT NULL,
  revision   INTEGER NOT NULL,
  PRIMARY KEY (root, generation)
);

CREATE TABLE migration_certificates (
  certificate_id     TEXT PRIMARY KEY,
  root               TEXT NOT NULL,
  generation         TEXT NOT NULL,
  epoch              INTEGER NOT NULL,
  prefix_revision    INTEGER NOT NULL,
  stage_revision     INTEGER NOT NULL,
  verified_through   INTEGER NOT NULL,
  aggregate_revision INTEGER NOT NULL,
  complete           INTEGER NOT NULL
);
CREATE TABLE migration_certificate_prefix (
  certificate_id  TEXT NOT NULL,
  recipient       TEXT NOT NULL,
  source_witness  TEXT NOT NULL,
  prefix_revision INTEGER NOT NULL,
  stage_revision  INTEGER NOT NULL,
  complete        INTEGER NOT NULL,
  cert_hash       TEXT NOT NULL,
  PRIMARY KEY (certificate_id, recipient)
);

CREATE TABLE migration_ready (
  id                   INTEGER PRIMARY KEY CHECK (id = 1),
  certificate_id       TEXT NOT NULL,
  certificate_revision INTEGER NOT NULL,
  proof_hash           TEXT NOT NULL,
  generation           TEXT NOT NULL,
  root                 TEXT NOT NULL,
  target_epoch         INTEGER NOT NULL,
  base_hash            TEXT NOT NULL,
  tail_hash            TEXT NOT NULL,
  tail_watermark       INTEGER NOT NULL,
  stage_revision       INTEGER NOT NULL,
  complete             INTEGER NOT NULL
);
