# Relay startup, bridge and retained archive plan

Wiring plan for the frozen startup/archive contract.

## Existing caller and artifact paths

- `packages/butler/init.lua:531 start_matrix_relay` is the only boot entry; it
  calls `matrix.relay.start(host._butler_matrix_config)` at :555 after the
  owner-unverified fence at :545.
- `packages/butler/matrix_relay.lua:3017 relay.start`; `:997 relay.new`;
  `:1004 state_path=config_path..".since"`, `ack_path=config_path..".acks"`;
  `:763 load_state`, `:982 save_state`, `:1628 reconcile_acks`,
  `:3058 relay.stop`.
- Backup/drain candidates are `config_path..".since.bak"` and
  `config_path..".acks.drain"`.
- `packages/butler/relay_store_migrate.lua:50 M.run` loops and is not the
  startup step; add `M.step` (exactly one store action). `relay_store.lua`
  exposes import_source/import_batch/ingest_step/import_acks/verify_import/
  activate/proof.
- `packages/butler/relay_receipts.lua:417 import_all`, `:487 record`,
  `:497 authority_state` are the legacy receipt bridge surface.
- `packages/butler/approval.lua:116 attach`, `:188 begin_delivery`, `:205 list`,
  `:226 reply`, `:306 request`, `:460 answer`, `:546 sweep`.
- `packages/butler/inbox_db.lua` is the current shadow index, not the inbox
  authority; the inbox proof is injected, never inferred from its counts.

## New modules

- `packages/butler/relay_authority.lua`: backend selection, durable startup
  job, store adapter, migration/verify/activation, inbox compatibility gate.
- `packages/butler/relay_archive.lua`: per-file retained archive coordinator.
- Extend `relay_receipts.lua` and `approval.lua` only through their existing
  public seams; do not replace the approve FIFO adapter.

## Driver interface

```
authority.start(cfg, deps) -> {backend,store,writer,job_id,phase,proof} |
                             nil, 'blocked: reason'
authority.advance(job_id, budget) -> {phase,done,blocked,reason,revision,...}
authority.status(job_id) -> refs/counts only, never mailbox content
authority.assert_inbox_compatible(cfg, inbox_proof) -> true | nil, reason
archive.plan(job_id) -> durable per-file plan
archive.advance(job_id, budget) -> {phase,done,copied,retired,blocked}
archive.status(job_id) -> manifest refs
```

`deps` is explicit: `open_store(opts)`, `db={acquire}`, `owner={acquire,check,
describe,release}`, `marker={read,publish}` (path
`cfg.config_path..".relay-authority"`), `anchors={inspect}`, `json=remuda.json`,
`digest={sha256}`, `fs=remuda.fs`, and `inbox_proof()` from the real inbox
producer (inbox_db is shadow only). Missing owner/inbox proof blocks before
poll; never fabricated.

## Startup sequence

`init.lua` calls `authority.start` before `matrix.relay.start`. The job is keyed
by mail root + relay identity + source generation + protocol and persists
`INVENTORY -> RELAY_INGEST -> RELAY_VERIFY -> RELAY_SQL_ACTIVE ->
BOTH_SQL_ACTIVE -> ARCHIVE_PLANNED -> ARCHIVING -> COMPLETE`. Each call advances
exactly one admission, one ingest_step, one import_batch page or one verify page;
no caller loop or whole SHA. SQL activates only after relay certificate and inbox
proof reread under the current owner. On failure the job blocks, originals
stay, and the relay never falls back to fresh FILE. Owner/marker/source bytes
are rechecked; unknown COMMIT quarantines.

## Legacy bridge and approvals

Before first delivery, exact account/room/event/destination/payload lookup
resolves the ORIGINAL mail id/read state. Unbound, conflicting or failed lookup blocks; no new id is
allocated and no notification is duplicated. The bridge stores handoff intent
and an idempotent receipt link; it never grants consent.

`approval.attach` receives the relay SQL writer. Request ids, kinds, status,
nonce, data, session binding, event/room refs, answer who/time,
delivery_started, recovery notices and unknown fields are persisted. Expiry and
prepared-delivery uncertainty remain explicit recovery transactions after raw
import proof. Guard/dialog approvals never enter the owner-input FIFO. SQL down
means unknown/refuse, not an empty approval list.

## Archive

Plan relay artifacts bound to both proofs. Destination is `archive/<jobid>/<relative path>`. States are planned,
copying, copied_verified, retirement_pending, retired, complete. Copy bounded
chunks with durable publish, fsync bytes/manifest, verify exact digest, then
atomically rename the source to the retained destination. Never unlink as
cleanup; cross-device keeps the original; collisions block unless the exact
destination is reusable. SQL/WAL/SHM, config, tokens and live inbox objects are
excluded. Empty or unsupported copy is `blocked/oversize`, not complete.

## Test order

RED first: ingest/verify crash stages, owner/marker gaps, inbox proof
missing/conflicting, legacy unbound/read state, approval restart/one-shot,
copy/rename/manifest faults, collision, cross-device, SQL-down refusal. No
live archive, cutover, reload, network send or source deletion.
