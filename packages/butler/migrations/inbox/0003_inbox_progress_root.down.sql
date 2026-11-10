-- Return to the stage-2 state shape (empty: the wider key cannot be narrowed
-- without guessing a root).
DROP TABLE IF EXISTS progress_state;
CREATE TABLE progress_state (
  recipient   TEXT NOT NULL,
  generation  TEXT NOT NULL,
  revision    INTEGER NOT NULL,
  cursor_json TEXT NOT NULL,
  PRIMARY KEY (recipient)
);
