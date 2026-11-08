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
- `relay_authority`: phase/owner/epoch/source_stamp/import_verified.

`verify_import` compares every imported row to the staged source in 64-row
pages (raw token, kind, map key/array ordinal, parent) before activation. A
same-count payload tamper therefore fails. Empty containers are represented
only in `relay_source_fields`; arrays preserve order and duplicates; unknown
nested members stay inside `payload_json`.

## Known limits / deferred

- Full `matrix_relay`/`matrix_read`/`doctor` reader-writer replacement and the
  inbox `accept_external` bridge are the next slice; cross-DB exactly-once is
  not implemented here.
- A 110k-value import takes many bounded turns; each `import_batch` is one
  commit. Cumulative harness instruction budget is separate from product
  per-call budget. QA's persistent-turn driver is the acceptance path.
- `populate_queue`/`relay_import_queue` is staging scaffolding; the live path
  pages directly from staged source. Do not treat queue state as authority.
- No live daemon, Matrix HTTP, reload, or uncertain replay was performed.
