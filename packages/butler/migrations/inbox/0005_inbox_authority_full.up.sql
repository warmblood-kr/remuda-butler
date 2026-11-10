-- Full Store Phase A foundation: authority epoch, external acceptance keys,
-- operation receipts and authoritative membership/matrix rows. Additive to the
-- #585 inbox tables and the progress staging tables.
CREATE TABLE auth_authority (
  id             INTEGER PRIMARY KEY CHECK (id = 1),
  format_version INTEGER NOT NULL,
  root           TEXT NOT NULL,
  epoch          INTEGER NOT NULL,
  generation     TEXT NOT NULL,
  operation_id   TEXT NOT NULL,
  proof_hash     TEXT NOT NULL,
  tail_watermark INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE auth_external (
  account      TEXT NOT NULL,
  room         TEXT NOT NULL,
  event        TEXT NOT NULL,
  destination  TEXT NOT NULL,
  key_hash     TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  message_id   TEXT NOT NULL,
  epoch        INTEGER NOT NULL,
  PRIMARY KEY (account, room, event, destination)
);
CREATE UNIQUE INDEX auth_external_opid ON auth_external (operation_id);

CREATE TABLE auth_operations (
  operation_id TEXT PRIMARY KEY,
  kind         TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  state        TEXT NOT NULL,
  message_id   TEXT,
  result_json  TEXT NOT NULL,
  epoch        INTEGER NOT NULL
);

CREATE TABLE auth_membership (
  recipient    TEXT NOT NULL,
  message_id   TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  resent_json  TEXT,
  metadata     TEXT NOT NULL,
  envelope_ref TEXT NOT NULL,
  object_ref   TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  epoch        INTEGER NOT NULL,
  PRIMARY KEY (recipient, message_id)
);
CREATE UNIQUE INDEX auth_membership_order ON auth_membership (recipient, seq);

CREATE TABLE auth_matrix (
  recipient  TEXT NOT NULL,
  room       TEXT NOT NULL,
  event      TEXT NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY (recipient, room, event)
);
