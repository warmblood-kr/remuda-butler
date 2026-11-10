-- Stage 2 never shipped; the progress state must be bound to the source root
-- so one borrowed handle cannot expose another root's cursor. Only staging
-- state is recreated here; the #585 deliveries/reads authority is untouched.
DROP TABLE IF EXISTS progress_state;
CREATE TABLE progress_state (
  root        TEXT NOT NULL,
  recipient   TEXT NOT NULL,
  generation  TEXT NOT NULL,
  revision    INTEGER NOT NULL,
  cursor_json TEXT NOT NULL,
  PRIMARY KEY (root, recipient)
);
