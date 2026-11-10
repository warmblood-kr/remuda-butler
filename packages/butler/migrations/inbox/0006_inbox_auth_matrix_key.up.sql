-- A Matrix event identity is scoped by the full external key tuple, not by the
-- recipient/room/event triple alone: two accounts may observe the same room and
-- event id. Keep every accepted triple->message mapping and make the lookup
-- refuse an ambiguous triple instead of silently picking one row.
CREATE TABLE auth_matrix_next (
  recipient  TEXT NOT NULL,
  room       TEXT NOT NULL,
  event      TEXT NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY (recipient, room, event, message_id)
);
INSERT OR IGNORE INTO auth_matrix_next (recipient, room, event, message_id)
  SELECT recipient, room, event, message_id FROM auth_matrix;
DROP TABLE auth_matrix;
ALTER TABLE auth_matrix_next RENAME TO auth_matrix;
