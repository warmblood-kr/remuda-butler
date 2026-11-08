# Relay store first slice (2026-11-08)

`packages/butler/relay_store.lua` is the product store behind the abstract
contract. It receives DB/marker/anchors/owner/json/digest/faults providers
through `open(opts)`; it does not read legacy files or register globals. This
slice is standalone: relay JSON reader/writer wiring is NOT done and is not
claimed complete.

Implemented: marker/anchor gate before the create-capable DB open; strict
line marker (`butler-relay-marker-v1`); deterministic store identity from
root/account/device/relay; owner capability/epoch CAS; bounded
`import_source`/`import_batch(<=64)`/`import_acks`; per-record/per-path verify;
activation gate; cursor/event/record/reply-intent/operation APIs for the
contract tests. Imported outbox rows are `uncertain` and never dispatch.
Primary source raw bytes are retired after activation; backup evidence is
retained. The root JSON is never decoded into Lua.

## Inspection schema for QA

- `relay_source_fields(source_id,path,parent_key,kind,count)`: root (`$`),
  every root collection (including empty `{}`/`[]`), nested room containers.
- `relay_records(namespace,parent_key,record_key,ordinal,json_kind,payload_json)`:
  one row per map entry/array element; `payload_json` is the original token.
  Arrays use 0-based `ordinal`; nested room collections use `parent_key`.
  Unknown root fields are namespace `unknown:<name>`, one raw record.
- `relay_cursors(scope,present,cursor_json,value)`: `cursor_json` is the raw
  token (`"x"` or `null`), `value` is unquoted (empty for null).
- `relay_events`: imported pending/delivered events; `source_key` includes
  account/room/event/destination and excludes store/epoch/process/device.
- `relay_processed`: ordered source dedupe IDs, duplicates preserved by
  `(source_id,ordinal)`.
- `relay_reply_intents`: imported outbox is `state='uncertain', imported=1`.
- `relay_manifest` roles primary/backup_evidence; `relay_import_source` keeps
  stamp/digest/bytes/status, primary raw NULL after activation.
- `relay_import_units`: expected/done/last_key, for bounded progress.
- `relay_authority`: phase/owner/epoch/source_stamp/import_verified/data_revision.
- `relay_verify_progress`: one durable checkpoint per
  `verification_id=verify:<store>:<source>` with revision/data_revision,
  unit_id, opaque cursor, state backlog|ready, and processed rows/bytes/nodes.
- `relay_verify_certificates`: final immutable proof bound to
  verification/source/data_revision/owner/epoch.

`verify_import(options)` is bounded per call: `max_rows<=64`,
`max_bytes<=262144`, `max_nodes<=8192` (defaults are the ceilings), at most 64
units, and each record's bytes/nodes count against the call budget. It returns
`verified=false,state='backlog'` with durable `verification_id,revision,
data_revision,phase,unit_id,cursor,processed_rows,bytes,nodes` until complete,
then `verified=true,state='ready',certificate_id`. A next record that cannot
fit even a fresh budget returns `budget_too_small` with no advance. Callers
must loop until `verified==true`; activation refuses a backlog.

It compares every imported row to the staged source (raw token, kind, map
key/array ordinal, parent). A same-count payload tamper therefore fails:
`data_revision` advances on every importing-time proof-input mutation
(records/processed/events/intents/source_fields/cursors) and activation
requires the certificate, checkpoint and authority data_revision to match by
indexed equality. Verify progress/certificate/status bookkeeping, authority
owner/epoch, and post-activation raw retirement/normal mutations are excluded.
Activation performs no scan, full count or bulk queue delete.

An ambiguous verify COMMIT returns `nil,'unknown_commit',{verification_id,
expected_revision,next_revision,data_revision}` and disposes the connection.
Reopen/reacquire rereads the durable checkpoint or certificate; a recovered
owner resumes the same data_revision prefix via owner/epoch CAS and rebinds the
final certificate to that owner. No guessed activation.

## Known limits / deferred

- Full `matrix_relay`/`matrix_read`/`doctor` reader-writer replacement and the
  inbox `accept_external` bridge are the next slice; cross-DB exactly-once is
  not implemented here.
- A 110k-value import/verify takes many bounded turns; each `import_batch` and
  each `verify_import` call is one commit/certificate page (<=64 rows). The
  cumulative harness instruction budget is separate from the product per-call
  budget. QA's persistent-turn driver is the acceptance path and must loop
  `verify_import` until `verified==true`.
- `populate_queue`/`relay_import_queue` is staging scaffolding; the live path
  pages directly from staged source. Do not treat queue state as authority.
- No live daemon, Matrix HTTP, reload, or uncertain replay was performed.
