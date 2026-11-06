-- seq is index insertion order, not canonical file delivery order while a
-- backlog remains. Do not use it for mailbox ordering before cutover.
CREATE TABLE deliveries (
  recipient TEXT NOT NULL,
  message_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  PRIMARY KEY (recipient, message_id)
);

CREATE UNIQUE INDEX deliveries_order ON deliveries (recipient, seq);

CREATE TABLE reads (
  recipient TEXT NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY (recipient, message_id)
);

CREATE TABLE import_state (
  recipient TEXT NOT NULL,
  kind TEXT NOT NULL,
  offset INTEGER NOT NULL,
  head INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (recipient, kind)
);
