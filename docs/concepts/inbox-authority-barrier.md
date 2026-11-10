# Sealed protocol, tracked gate and bounded promotion

v1.3 clarifications; no silent change to basic source API/progress-v2 resume.
NEW domain `migration-sealed-v1:sha256:<hex>`; seed
sha256(frame("migration-sealed-v1",root,recipient,generation,inbox_end,read_end)).
Use source-progress-v2 deterministic chunk/file framing AFTER that distinct seed
and clamp log reads/EOF to recorded sealed ends. Durable cursor carries
`protocol="migration-sealed-v1"` and exact generation/ends. Existing v2 cursors
must not be reinterpreted: explicit new sealed generation, retained old stage,
no source deletion. Changing generation/sealed ends changes proof, never resume
same cursor against new ends. Tail has separate mutation sequence+range hashes.

## Persistent FILE_TRACKED gate

Add marker state FILE_TRACKED `{format_version,protocol="tracked-file-v1",
root,epoch,generation}`. Membership/read source remains FILE, but ALL admitted
mutation paths and restart require working tracking journal+supported epoch.
Initialize journal schema/generation, then atomically publish FILE_TRACKED
before admitting any tracked mutation. Persisted marker inspected before
backend selection; DB-down/missing/schema mismatch => explicit refusal, no plain
FILE fallback, no source append/import/read permission guessed from old files.
Legacy alias/read/forward/Matrix/send/internal hooks obey same gate. Publisher
failure after rename => unknown_publish, reread exact marker identity, reconcile.
A crash after gate/before local hook install restarts in tracked mode or refuses;
never resumes old untracked path. Unsupported binary set remains excluded by
operational support policy, not magically fenced by a marker it ignores.
Transition expected FILE_TRACKED epoch -> SQL_REQUIRED/SQL_ACTIVE; FILE may be
an input only before initializing migration tracking, not final barrier bypass.

## Precomputed certificate and final CAS

Outside barrier: bounded prefix comparison computes exact original identity/
order/read/resent/metadata equality against staged actual SQL rows. Persist
certificate row `{certificate_id,root,epoch,generation,prefix_revision,
stage_revision,verified_through,aggregate_revision,complete}` with per-recipient
proof rows, NOT whole-state JSON. Each live-tail transaction updates only its
bounded affected rows/proofs and aggregate revision atomically; unsupported
mutation or missing proof marks dirty. Immutable prefix proof remains valid.
An aggregate is maintained by verified transactional construction, not just
COUNT/MAX or caller-supplied true. Exact equality was computed outside barrier;
concurrent dirty/stage generation change invalidates reuse.

Internal migration.barrier budget includes max_tail_records and max_statements.
Hold supported writer admission turn; capture T; compare epoch, generation,
certificate_id/revision and persisted aggregate completeness. If certificate
missing/dirty or tail distance > bound => backlog BEFORE prepared, resume pump.
Apply and verify <=max_tail_records actual remaining source/journal deltas
through T, bounded statement work. Final transaction CAS checks captured epoch,
aggregate/certificate revisions, all mutation sequences<=T resolved and staged
revision; publishes transition-ready proof. Fail CAS => backlog, no marker.
Only then persist prepared marker with T/certificate/opid, commit SQL epoch+
receipt, finalize SQL_ACTIVE. No full mailbox walk, full prefix hash, global
body reads or certifier rerun in final turn. Native calls/one record costs retain
existing honest limits; bounded statements is not a hard wall-clock promise.

## Admission ownership during transition

No assertion that existing agent/daemon in-memory queues survive crash. Before
acknowledging deferred mutation, persist pending intent+stable opid/hash and
immutable content refs durably in same inbox DB, or return explicit retryable
not_accepted while caller retains same opid/source key. Caller must demonstrate
that ownership across restart; if unavailable, refuse admission before ack,
never create a new opid/new mail to recover. Pending intent is not committed
mail and does not authorize external resend. SQL_REQUIRED restart reconciles
pending opid/receipt, then executes at most its existing transaction identity.
No global human-input pause; individual unresolved storage/admission failures
are explicit. Crash fixture after deferred intent ack/before mailbox commit
must recover same receipt/id; not_accepted fixture retries SAME id/key.

QA spies assert final barrier invokes zero prefix-scan/body-hash/full-certifier
calls and <=configured tail records/statements. Arrivals between every pump
call/restart do not reset sealed cursor; dirty proof/over-budget returns backlog
without prepared marker. FILE_TRACKED DB-down restart exercises every mutation
entrypoint and verifies zero file writes. Existing source-progress-v2 cursor
reopen retains v2 domain; sealed migration rejects accidental cursor reuse.
