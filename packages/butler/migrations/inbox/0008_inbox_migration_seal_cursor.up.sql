-- Resumable sealed-prefix scan state. A bounded call may not reach the last
-- complete newline; persist the next lower byte bound so a later turn resumes
-- the same recipient/generation instead of rescanning the tail forever.
CREATE TABLE migration_seal_cursor (
  root         TEXT NOT NULL,
  generation   TEXT NOT NULL,
  recipient    TEXT NOT NULL,
  inbox_offset INTEGER NOT NULL,
  read_offset  INTEGER NOT NULL,
  inbox_done   INTEGER NOT NULL,
  inbox_end    INTEGER,
  inbox_torn   INTEGER,
  read_done    INTEGER NOT NULL,
  read_end     INTEGER,
  read_torn    INTEGER,
  PRIMARY KEY (root, generation, recipient)
);
