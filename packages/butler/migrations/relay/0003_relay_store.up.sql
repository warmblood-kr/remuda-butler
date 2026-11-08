CREATE TABLE IF NOT EXISTS relay_authority (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  schema_version INTEGER NOT NULL,
  store_id TEXT NOT NULL UNIQUE,
  phase TEXT NOT NULL CHECK(phase IN ('importing','active','blocked')),
  owner_id TEXT NOT NULL,
  epoch INTEGER NOT NULL CHECK(epoch>0),
  source_stamp TEXT NOT NULL,
  import_verified INTEGER NOT NULL DEFAULT 0 CHECK(import_verified IN(0,1)),
  data_revision INTEGER NOT NULL DEFAULT 0,
  blocked_reason TEXT
);
CREATE TABLE IF NOT EXISTS relay_verify_progress (
  verification_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0,
  data_revision INTEGER NOT NULL,
  unit_id INTEGER,
  cursor TEXT,
  state TEXT NOT NULL CHECK(state IN ('backlog','ready')),
  processed_rows INTEGER NOT NULL DEFAULT 0,
  bytes INTEGER NOT NULL DEFAULT 0,
  nodes INTEGER NOT NULL DEFAULT 0,
  certificate_id TEXT,
  owner_id TEXT,
  epoch INTEGER
);
CREATE TABLE IF NOT EXISTS relay_verify_certificates (
  certificate_id TEXT PRIMARY KEY,
  verification_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  data_revision INTEGER NOT NULL,
  processed_rows INTEGER NOT NULL,
  bytes INTEGER NOT NULL,
  nodes INTEGER NOT NULL,
  owner_id TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS relay_manifest (
  source_id TEXT PRIMARY KEY,
  role TEXT NOT NULL CHECK(role IN ('primary','backup_evidence','acks','drain')),
  stamp TEXT,
  marker_durability TEXT,
  db_durability TEXT
);
CREATE TABLE IF NOT EXISTS relay_import_source (
  source_id TEXT PRIMARY KEY,
  role TEXT NOT NULL,
  stamp TEXT,
  raw TEXT,
  raw_sha256 TEXT NOT NULL,
  bytes INTEGER NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('importing','staged','verified','evidence','blocked')),
  staged_count INTEGER NOT NULL DEFAULT 0,
  verified_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS relay_import_source_status ON relay_import_source(status);
CREATE TABLE IF NOT EXISTS relay_source_fields (
  source_id TEXT NOT NULL,
  path TEXT NOT NULL,
  parent_key TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY(source_id,path)
);
CREATE TABLE IF NOT EXISTS relay_import_units (
  unit_id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_id TEXT NOT NULL,
  root_field TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('object','array','raw')),
  parent_key TEXT NOT NULL DEFAULT '',
  nested INTEGER NOT NULL DEFAULT 0,
  expected INTEGER NOT NULL DEFAULT 0,
  done INTEGER NOT NULL DEFAULT 0,
  last_key TEXT,
  last_seq INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS relay_import_units_pending ON relay_import_units(source_id,done,unit_id);
CREATE TABLE IF NOT EXISTS relay_import_queue (
  source_id TEXT NOT NULL,
  unit_id INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  key TEXT NOT NULL,
  kind TEXT NOT NULL,
  parent_key TEXT NOT NULL DEFAULT '',
  ordinal INTEGER,
  payload_json TEXT NOT NULL,
  PRIMARY KEY(source_id,unit_id,seq)
);
CREATE TABLE IF NOT EXISTS relay_cursors (
  scope TEXT PRIMARY KEY CHECK(scope IN ('sync','messages')),
  present INTEGER NOT NULL CHECK(present IN(0,1)),
  cursor_json TEXT,
  value TEXT
);
CREATE TABLE IF NOT EXISTS relay_records (
  namespace TEXT NOT NULL,
  parent_key TEXT NOT NULL DEFAULT '',
  record_key TEXT NOT NULL,
  ordinal INTEGER,
  json_kind TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  PRIMARY KEY(namespace,parent_key,record_key)
);
CREATE INDEX IF NOT EXISTS relay_records_order ON relay_records(namespace,parent_key,ordinal,record_key);
CREATE TABLE IF NOT EXISTS relay_processed (
  source_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  event_id TEXT NOT NULL,
  PRIMARY KEY(source_id,ordinal)
);
CREATE INDEX IF NOT EXISTS relay_processed_event ON relay_processed(event_id);
CREATE TABLE IF NOT EXISTS relay_events (
  event_id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL DEFAULT '',
  source_key TEXT NOT NULL UNIQUE,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  state TEXT NOT NULL CHECK(state IN ('pending','delivered','filtered','quarantined')),
  inbox_mail_id TEXT
);
CREATE INDEX IF NOT EXISTS relay_events_pending ON relay_events(state,event_id);
CREATE TABLE IF NOT EXISTS relay_reply_intents (
  reply_id TEXT PRIMARY KEY,
  txn_id TEXT UNIQUE,
  state TEXT NOT NULL CHECK(state IN ('prepared','in_flight','sent','failed','uncertain')),
  attempts INTEGER,
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
  owner_id TEXT,
  epoch INTEGER,
  imported INTEGER NOT NULL DEFAULT 0 CHECK(imported IN(0,1))
);
CREATE INDEX IF NOT EXISTS relay_reply_intents_state ON relay_reply_intents(state,imported);
CREATE TABLE IF NOT EXISTS relay_operations (
  operation_id TEXT PRIMARY KEY,
  operation_kind TEXT NOT NULL,
  input_witness TEXT NOT NULL,
  result_json TEXT NOT NULL CHECK(json_valid(result_json)),
  owner_id TEXT NOT NULL,
  epoch INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS relay_sidecar (
  source_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  raw TEXT NOT NULL,
  raw_sha256 TEXT NOT NULL,
  stamp TEXT,
  PRIMARY KEY(source_id,kind)
);

-- Every verification-input mutation while importing advances data_revision.
-- Verify progress/certificate/status bookkeeping is excluded; after ACTIVE the
-- triggers are inert, so normal runtime mutations do not invalidate the cert.
CREATE TRIGGER IF NOT EXISTS relay_rev_records_ins AFTER INSERT ON relay_records
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_records_upd AFTER UPDATE ON relay_records
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_records_del AFTER DELETE ON relay_records
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_processed_ins AFTER INSERT ON relay_processed
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_events_ins AFTER INSERT ON relay_events
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_events_upd AFTER UPDATE ON relay_events
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_intents_ins AFTER INSERT ON relay_reply_intents
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_intents_upd AFTER UPDATE ON relay_reply_intents
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_fields_ins AFTER INSERT ON relay_source_fields
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_cursors_ins AFTER INSERT ON relay_cursors
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_cursors_upd AFTER UPDATE ON relay_cursors
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_source_ins AFTER INSERT ON relay_import_source
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_source_upd AFTER UPDATE ON relay_import_source
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
 AND (OLD.raw IS NOT NEW.raw OR OLD.raw_sha256 IS NOT NEW.raw_sha256
   OR OLD.stamp IS NOT NEW.stamp OR OLD.bytes IS NOT NEW.bytes
   OR OLD.staged_count IS NOT NEW.staged_count
   OR OLD.role IS NOT NEW.role OR OLD.source_id IS NOT NEW.source_id)
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_source_del AFTER DELETE ON relay_import_source
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_units_ins AFTER INSERT ON relay_import_units
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_units_upd AFTER UPDATE ON relay_import_units
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_units_del AFTER DELETE ON relay_import_units
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_manifest_ins AFTER INSERT ON relay_manifest
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_manifest_upd AFTER UPDATE ON relay_manifest
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_manifest_del AFTER DELETE ON relay_manifest
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_fields_upd AFTER UPDATE ON relay_source_fields
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_fields_del AFTER DELETE ON relay_source_fields
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_cursors_del AFTER DELETE ON relay_cursors
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_processed_upd AFTER UPDATE ON relay_processed
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_processed_del AFTER DELETE ON relay_processed
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_events_del AFTER DELETE ON relay_events
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_intents_del AFTER DELETE ON relay_reply_intents
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_sidecar_ins AFTER INSERT ON relay_sidecar
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_sidecar_upd AFTER UPDATE ON relay_sidecar
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
CREATE TRIGGER IF NOT EXISTS relay_rev_sidecar_del AFTER DELETE ON relay_sidecar
WHEN (SELECT phase FROM relay_authority WHERE singleton=1)='importing'
BEGIN UPDATE relay_authority SET data_revision=data_revision+1 WHERE singleton=1; END;
