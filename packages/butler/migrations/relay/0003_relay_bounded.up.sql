-- Bounded relay work state: schema only.
--
-- Phase 1 remains a shadow. JSON relay state stays authoritative for dedupe,
-- cursors, retention and sends; these tables are not read or written by the
-- relay yet, and no TTL/cap value is seeded here. `authority=shadow` is the
-- only default.
--
-- The columns `recipient`, `expected_body` and `handed_envelope` make the
-- handoff identity durable once a later PR starts using this schema. They are
-- additive here so the identity does not have to be reconstructed from files.
CREATE TABLE relay_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT OR REPLACE INTO relay_meta (key, value) VALUES ('authority', 'shadow');

CREATE TABLE relay_inbound (
  event_id        TEXT PRIMARY KEY,
  room_id         TEXT NOT NULL,
  received_at     INTEGER NOT NULL,
  payload_json    TEXT NOT NULL,
  state           TEXT NOT NULL CHECK (state IN
    ('unhanded','handoff_pending','handed','duplicate','rejected')),
  mail_id         TEXT UNIQUE,
  recipient       TEXT,
  expected_body   TEXT,
  attempts        INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER,
  last_error      TEXT,
  handed_at       INTEGER,
  handed_envelope TEXT,
  completed_at    INTEGER,
  expires_at      INTEGER
);

CREATE INDEX relay_inbound_work ON relay_inbound(state, next_attempt_at);
CREATE INDEX relay_inbound_expiry ON relay_inbound(expires_at);

CREATE TABLE relay_outbox (
  reply_id        TEXT PRIMARY KEY,
  txn_id          TEXT NOT NULL UNIQUE,
  source_mail_id  TEXT NOT NULL,
  room_id         TEXT NOT NULL,
  event_id        TEXT NOT NULL,
  thread_root     TEXT,
  payload_json    TEXT NOT NULL,
  state           TEXT NOT NULL CHECK (state IN
    ('pending','in_flight','uncertain','sent','failed_no_effect')),
  attempts        INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER,
  last_error      TEXT,
  created_at      INTEGER NOT NULL,
  completed_at    INTEGER,
  expires_at      INTEGER
);

CREATE INDEX relay_outbox_work ON relay_outbox(state, next_attempt_at);
CREATE INDEX relay_outbox_expiry ON relay_outbox(expires_at);

CREATE TABLE relay_dedupe (
  kind           TEXT NOT NULL,
  key            TEXT NOT NULL,
  first_seen     INTEGER NOT NULL,
  state          TEXT NOT NULL CHECK (state IN ('open','resolved')),
  identity       TEXT,
  result_summary TEXT,
  expires_at     INTEGER,
  PRIMARY KEY (kind, key)
);

CREATE INDEX relay_dedupe_expiry ON relay_dedupe(expires_at);

CREATE TABLE relay_cursor (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  since      TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  generation TEXT NOT NULL
);
