-- Versioned sealed-prefix capture and fair recipient rotation.
--
-- Presence/size are captured once per generation BEFORE either log is read.
-- Offsets move monotonically down from the captured size; appends beyond it are
-- tail. A cursor without cursor_version/present/captured_size cannot be resumed
-- against a new EOF and must be invalidated/resealed by the writer.
CREATE TABLE migration_seal_cursor (
  root                TEXT NOT NULL,
  generation          TEXT NOT NULL,
  recipient           TEXT NOT NULL,
  cursor_version      INTEGER NOT NULL,
  inbox_present       INTEGER NOT NULL,
  inbox_captured_size INTEGER NOT NULL,
  inbox_offset        INTEGER NOT NULL,
  inbox_done          INTEGER NOT NULL,
  inbox_end           INTEGER,
  inbox_torn          INTEGER,
  read_present        INTEGER NOT NULL,
  read_captured_size  INTEGER NOT NULL,
  read_offset         INTEGER NOT NULL,
  read_done           INTEGER NOT NULL,
  read_end            INTEGER,
  read_torn           INTEGER,
  PRIMARY KEY (root, generation, recipient)
);

-- Rotate the first seal recipient after each bounded Store call so a long torn
-- suffix in one mailbox cannot starve the others.
CREATE TABLE migration_seal_rotation (
  root       TEXT NOT NULL,
  generation TEXT NOT NULL,
  next_key   TEXT NOT NULL,
  PRIMARY KEY (root, generation)
);
