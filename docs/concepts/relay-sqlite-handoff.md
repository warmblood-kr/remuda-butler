# Relay SQLite authority handoff

Head `5daa950` on `feat/relay-sqlite-authority`, on the QA scoped-clear
`37604d5` line. Working tree clean; no live daemon, Matrix, reload, archive or
cutover was performed. A Reload/rollout ends this in-process session; all work
is committed.

## Implemented

- `relay_store_migrate.step`: exactly one store action per call. Streaming
  admission (`import_stream_begin/chunk/finish`) moves one <=64KiB chunk per
  call and SQL assembles the immutable capture; then one ingest_step,
  import_batch page, verify page, activate or proof. Source-set metadata stamps
  only; no whole-source Lua read/SHA and no caller loop.
- `relay_store`: new `relay_source_stage`/`relay_source_chunk` tables
  (migration 0005), trigger guard, chunkwise digest root, exact chunk retry,
  changed/order/oversize refusal, capture assembled with
  `COALESCE(group_concat(...))` so empty sidecars are valid.
- `relay_authority`: start refuses before store open/poll without the real
  inbox producer function and real owner providers; consumes producer `9cb44ef`
  flat identities plus the exact NUL compatibility tuple, recomputes ready/
  payload, refuses pending/blocked/tampered; one-action advance; durable
  content-free job (restart resumes); proof/certificate certrefs (version 5);
  inventories. `authority.adapter(providers)` is the joint coordinator seam.
- Central gate in `matrix_relay.relay.start` and `relay.new` (covers
  matrix_cli setup/restart) plus `init.lua:start_matrix_relay`; no authority
  module means legacy behavior unchanged.
- `relay_archive`: proof-gated plan/advance/status; durable per-job `plan.json`
  (chunk/verify/retire cursors), both proofs and current owner before every
  advance, <=64KiB `.part.NNNN` copy/verify, digest manifest, source rename,
  both-parent write_atomic fences, unknown-rename inspection, retire_conflict
  for live source + identical retained copy, no unlink/overwrite.
- `approval_record_sql`: exact idempotent `store:put` per approval record,
  bounded page/get, writer-missing refusal; optional record adapter on the
  existing 5-arg `approval.attach`; JSON persist is the explicit pre-cutover
  path. `complete_reply`/`complete_dispatch` atomic receipt/route changes are
  NOT wired yet.

## Evidence

- `luajit tests/red/relay_startup_red.lua` clears (was 4 RED).
- `luajit tests/butler_lifecycle_reload.lua` PASS; dialog approval PASS.
- `/private/tmp/relay-sqlite-qa/startup-step-native.lua` -> 71 bounded advances
  (max 1 store action each), changed stamp -> manifest_conflict, producer shape
  accepted, tampered/blocked/owner/proof drift refused, restart resumes,
  adapter binding, archive 4 files + 200KB/4 parts, mid-flight reload keeps
  offset 65536, retire_conflict keeps the source.
- `/private/tmp/relay-sqlite-qa/stream_admit_native.lua`: 200,080B -> 4
  chunks, verify+activate, no source decode; retry/order/changed edges pass.
- `/private/tmp/relay-sqlite-qa/ingest_edges.lua` still exits 0.
- Logs: `startup-step-native.log`, `stream-admit.log`,
  `ingest-edges-after-stream.log`.

## Blocks / not claimed

- Live poll/archive/cutover/reload/delete and full E2E are not authorized or
  done; archive advance needs caller copy/owner/current-proof providers.
- Legacy bridge original id/read state, `complete_reply` HTTP receipt and
  `complete_dispatch` route/subscription transaction are still pending.
- Joint Inbox `fb2cce8` driver positive fixture with the real producer proof and
  real owner capability remains.
- Proof accounting: revision proof 37 executed + 3 queue SKIP; case_turns 26 +
  case17 SKIP. 376 store ingest scoped clear is unchanged, not archive.

## Recovery

Run `luajit tests/red/relay_startup_red.lua`; then in
`/private/tmp/relay-sqlite-qa`:
`python3 bounded_turns_runner.py stream_admit_native.lua
/private/tmp/butler-relay-sqlite/packages/butler/relay_store.lua` and the same
with `startup_step_native.lua`. Both use a disposable private daemon under
`runs/`; they never touch live state.
