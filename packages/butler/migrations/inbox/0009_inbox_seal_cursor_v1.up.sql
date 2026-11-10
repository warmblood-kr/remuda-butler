-- The focused seal contract needs captured presence/size and a cursor version.
-- 0008 shipped offset-only rows. Those rows cannot be resumed against the
-- current EOF without guessing the original capture, so this migration rebuilds
-- the cursor table and discards them: an explicit invalidate/reseal transition.
-- The source files are untouched; the next seal captures fresh sizes.
DROP TABLE IF EXISTS migration_seal_cursor;
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
CREATE TABLE IF NOT EXISTS migration_seal_rotation (
  root       TEXT NOT NULL,
  generation TEXT NOT NULL,
  next_key   TEXT NOT NULL,
  PRIMARY KEY (root, generation)
);
