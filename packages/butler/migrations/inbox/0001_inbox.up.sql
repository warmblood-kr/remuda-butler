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
  PRIMARY KEY (recipient, kind)
);
