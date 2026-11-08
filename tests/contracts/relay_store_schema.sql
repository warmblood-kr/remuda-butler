-- Contract schema sketch, NOT a production migration. Existing receipt shadow
-- tables must remain intact until identity/value reconciliation completes.
CREATE TABLE relay_authority (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 schema_version INTEGER NOT NULL CHECK(schema_version=1),
 store_id TEXT NOT NULL UNIQUE,
 phase TEXT NOT NULL CHECK(phase IN ('importing','active','blocked')),
 owner_id TEXT NOT NULL,
 epoch INTEGER NOT NULL CHECK(epoch>0),
 source_stamp TEXT NOT NULL,
 import_verified INTEGER NOT NULL DEFAULT 0 CHECK(import_verified IN(0,1))
);
CREATE TABLE relay_cursors (
 scope TEXT PRIMARY KEY CHECK(scope IN ('sync','messages')),
 cursor TEXT
);
-- Collection names are persisted names, not Lua alias names. Each map entry
-- or array element is a row. Nested room maps/arrays use parent_key.
CREATE TABLE relay_records (
 namespace TEXT NOT NULL,
 parent_key TEXT NOT NULL DEFAULT '',
 record_key TEXT NOT NULL,
 ordinal INTEGER,
 json_kind TEXT NOT NULL,
 payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
 PRIMARY KEY(namespace,parent_key,record_key),
 CHECK(length(CAST(payload_json AS BLOB))<=262144)
);
CREATE INDEX relay_record_order ON relay_records(namespace,parent_key,ordinal,record_key);
CREATE TABLE relay_events (
 event_id TEXT PRIMARY KEY,
 room_id TEXT NOT NULL,
 source_key TEXT NOT NULL UNIQUE,
 payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
 state TEXT NOT NULL CHECK(state IN ('pending','delivered','filtered','quarantined')),
 inbox_mail_id TEXT,
 CHECK(length(CAST(payload_json AS BLOB))<=262144)
);
CREATE INDEX relay_pending ON relay_events(state,event_id);
CREATE TABLE relay_operations (
 operation_id TEXT PRIMARY KEY,
 operation_kind TEXT NOT NULL,
 input_witness TEXT NOT NULL,
 result_json TEXT NOT NULL CHECK(json_valid(result_json)),
 owner_id TEXT NOT NULL,
 epoch INTEGER NOT NULL
);
CREATE TABLE relay_reply_intents (
 reply_id TEXT PRIMARY KEY,
 txn_id TEXT NOT NULL UNIQUE,
 state TEXT NOT NULL CHECK(state IN('prepared','in_flight','sent','failed','uncertain')),
 attempts INTEGER,
 payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
 owner_id TEXT,
 epoch INTEGER,
 CHECK(length(CAST(payload_json AS BLOB))<=262144)
);
CREATE TABLE relay_import_progress (
 source_id TEXT PRIMARY KEY,
 source_stamp TEXT NOT NULL,
 next_path TEXT,
 staged_count INTEGER NOT NULL DEFAULT 0,
 verified_count INTEGER NOT NULL DEFAULT 0,
 conflict_count INTEGER NOT NULL DEFAULT 0,
 status TEXT NOT NULL CHECK(status IN('staging','validating','importing','verified','blocked'))
);
-- Every mutation transaction starts BEGIN IMMEDIATE and performs this exact
-- logical CAS BEFORE edits. rows_affected==1 is mandatory; lease time is not
-- a substitute. store_id/owner_id/epoch all come from immutable capability.
-- UPDATE relay_authority SET epoch=epoch WHERE singleton=1
--   AND store_id=? AND owner_id=? AND epoch=? AND phase='active';
-- Then operation-id conflict check + edits + operation result + COMMIT.
-- Never network/FS or external inbox call inside the SQLite transaction.
