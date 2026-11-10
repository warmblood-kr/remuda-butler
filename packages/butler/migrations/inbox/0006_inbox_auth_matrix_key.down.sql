CREATE TABLE auth_matrix_previous (
  recipient  TEXT NOT NULL,
  room       TEXT NOT NULL,
  event      TEXT NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY (recipient, room, event)
);
INSERT OR IGNORE INTO auth_matrix_previous (recipient, room, event, message_id)
  SELECT recipient, room, event, message_id FROM auth_matrix;
DROP TABLE auth_matrix;
ALTER TABLE auth_matrix_previous RENAME TO auth_matrix;
