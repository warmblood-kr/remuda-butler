# Relay startup, bridge and retained archive plan

## Caller and artifact paths

- `init.lua:531 start_matrix_relay` calls `matrix.relay.start` at :555 after
  the owner fence at :545.
- `matrix_relay.lua:3017 relay.start`; `:997 relay.new`;
  `:1004 state_path=config_path..".since"`, `ack_path=config_path..".acks"`;
  `:763 load_state`, `:982 save_state`, `:1628 reconcile_acks`, `:3058 stop`.
- Backup/drain: `config_path..".since.bak"`, `config_path..".acks.drain"`.
- `relay_store_migrate.run` loops and is NOT the startup step; `M.step` performs
  exactly one store action via import_prepare/import_source/import_acks/
  ingest_step/import_batch/verify_import/activate/proof.
- `relay_receipts.lua:417 import_all`, `:487 record`, `:497 authority_state`.
- `approval.lua:116 attach(state,persist,post,room,home[,record])`, `:188
  begin_delivery`, `:205 list`, `:226 reply`, `:306 request`, `:460 answer`,
  `:546 sweep`.
- `inbox_db.lua` is shadow only; the producer proof is injected.

## New modules

- `relay_authority.lua`: backend selection, durable job, store step, inbox
  gate.
- `relay_archive.lua`: per-file retained archive coordinator.
- `matrix_relay.relay.authority_gate` is the single gate in `relay.start` and
  `relay.new`, so `matrix_cli` setup/restart and the boot path share admission.
- Extend receipts/approval only through existing seams; never replace the FIFO.
  `approval_record_sql` mirrors one record through `store:put` under the writer.

## Driver interface

```
authority.start(cfg, deps) -> {job_id,phase,store,proof} | nil,'blocked: ...'
authority.advance(job_id,budget) -> one admission/ingest/import/verify/
                                    activate/proof action
authority.status(job_id), authority.proof(job_id),
authority.certificate(certificate_id), authority.inventories()
authority.assert_inbox_compatible(cfg, proof, deps)
archive.plan(input) -> per-file plan | nil,'proof_...'
archive.advance(job_id,budget), archive.status(job_id)
```

`deps`: `open_store(cfg,deps)`, `identity{root_id,account_id,device_id,relay_id}`,
`owner{acquire,check,describe,release}`, `marker{read,publish}`,
`anchors.inspect`, `json`, `digest.sha256`, `fs`, `migrate`, and `inbox_proof()`
returning the live producer object. Missing owner/inbox proof blocks before
poll; never fabricated and never read from inbox_db counts.

## Startup sequence

`init.lua` calls `authority.start` before `matrix.relay.start`; a blocked or
non-done job sets the restart barrier and returns. One advance performs exactly
one admission, ingest_step, import_batch page, verify page, activate or proof
call; no caller loop and no whole-source SHA. Stamps are source-set metadata.
SQL activates only after the relay certificate and inbox proof reread under the
current owner. Owner/marker/source bytes are rechecked; unknown COMMIT
quarantines; there is no FILE fallback.

The producer proof pins `contract=inbox-compatibility-v1`, `authority=sql`,
`protocol=sql-inbox-v1`, root/store/owner/epoch/generation/source_set_id/
revision/data_revision/tail_watermark/certificate_id/verification_id/
proof_hash, `state=active`, both capabilities, nested ready fields and the
exact NUL `butler-inbox-compat-v1` tuple. Every identity and the hash are
required; pending/blocked/missing refuses.

## Legacy bridge and approvals

Before the first delivery, exact account/room/event/destination/payload lookup
resolves the ORIGINAL mail id/read state; conflict/unbound blocks. The Inbox receipt `result.message_id` maps to the relay
receipt `mail_id`; no new id is allocated and no notification duplicates.
`complete_reply` needs an atomic HTTP result receipt; `complete_dispatch` needs
the route/subscription+delivered change in one transaction.

`approval.attach` keeps its five arguments plus an optional record adapter. Request fields, answer who/time, delivery and recovery notices persist. Expiry and prepared-delivery uncertainty recover only
after raw import proof. SQL down means unknown/refuse, never an empty list.

## Archive

Plan config_path since/since.bak/acks/acks.drain bound to both proofs to
`archive/<jobid>/<basename>`; states planned, copying, verifying,
copied_verified, retirement_pending, retired, complete. `remuda.fs` has
write_atomic/mkdir_new/realpath/is_symlink/lock but no generic read/fsync/
durable_rename: copy, publish-verified, rename-once and both-parent sync are
injected providers, never invented. Distinct `*.verified`/`*.original`
destinations; never overwrite a verified copy with an unsynced original.
Never unlink; cross-device keeps the original; collisions block. Empty ack/drain
is a valid 0-byte artifact; SQL/WAL/SHM, marker, config/token and live inbox are
excluded.

## Test order

RED first: ingest/verify crash stages, owner/marker gaps, inbox proof
missing/blocked/tampered, legacy unbound/read state, approval restart/one-shot,
copy/rename/manifest faults, collision, cross-device, SQL-down refusal. No
live archive/cutover/reload/send/delete.
