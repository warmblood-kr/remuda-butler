# SQLite authority transition obligations

Contract v1, 2026-11-08. Companion: inbox-authority-api.md.
No product/schema implementation, daemon reload, send, resend, kill, migration,
or live operation is performed by the abstract contract.

Persistent authority marker outside SQLite must distinguish FILE,
CUTOVER_PREPARED, SQL_ACTIVE and RECOVERY_REQUIRED, with format version, root
identity, epoch, transition operation id and SQL generation. Marker unreadable
or ambiguous is recovery-required. DB presence/absence cannot infer authority.
CUTOVER_PREPARED already means sql_required: DB failure cannot revive files.
FILE may use files only while no transition intent exists. After preparation,
all read/membership/read-status/authorization/dedup and order decisions require
SQL or explicit refusal, never stale-file fallback or automatic rebuild.

Migration reuses #585 importer with resumable staged augmentation. Preserve
immutable envelope/object files and every id, recipient identity, read fact,
reference, first distinct order and last present resent annotation. Inventory malformed,
unreadable, missing-content records explicitly; never silently discard them or
mark them read. No ready state from skipped or incomplete import. Certify full
source identity streams against actual SQL snapshot, not counts. Catch up tail
under writer exclusion and recertify whole data/read/metadata coverage before
promoting the epoch. Delivery fanout, operation receipt, ordered membership,
metadata/dedup and read state are transactional in SQLite. Content files must
be durably published before SQL references become visible, or content must be
in the same transaction. Lua close alone supplies no power-loss guarantee.

Crash tests must cover: rows before cursor; cursor transaction before commit;
marker preparation; SQL promotion commit; final marker write; body publication;
operation receipt commit; ambiguous COMMIT; restart during each. A prepared
marker survives DB unavailability and demands reconciliation of the same
transition epoch/id. SQL-only delivery/read facts cannot be exported by simply
starting an old binary. Reverse transition needs exclusive export of all facts,
exact identity/read/order/metadata parity, reconciled uncertainty and a durable
format transition before old writers are admitted. No deleting source files,
chmod fencing or automatic downgrade.

## Honest legacy exclusion boundary

Existing advisory guard can exclude cooperating binaries that claim the SAME
actual mailroot locks. A new marker alone cannot exclude old binaries that
ignore it, and an upgraded code check does not change old installed binaries.
The production support set is upgraded writers that honor marker+guard on the
actual root. Deployment explicitly forbids downgrade or unmanaged legacy
writers while SQL authority is active. Under that stated support boundary,
claim the existing actual-root guard, test a second cooperating writer refuses
before mutation, and proceed with cutover. No universal legacy exclusion is
claimed. Preserve original files; never use chmod/deletion as enforcement.

A core/launcher format-version gate is required only if product support promises
that OLD binaries themselves refuse to launch against a promoted root. Such a
gate must run before shared-state code, cover every claimed launch path, and
check format independently of SQL availability. It is not a prerequisite for
the explicitly upgraded-writer-only release. No new native primitive is needed
for process-crash scoped upgraded-writer operation; power-loss-safe cross-file
marker/content publication additionally needs fsync(file)+atomic rename+
fsync(parent directory), or equivalent supported durable publication primitive.
Until available, describe process-crash durability only.

Error taxonomy: unavailable, denied, corrupt, schema_too_new, partial,
stale_generation, writer_conflict, source_unreadable, invalid_snapshot,
parity_mismatch, operation_conflict, legacy_fence_unsupported, unknown_commit.
Nil/false never doubles as empty/unread-zero/proven absence or authorization.
External Matrix transport uncertainty is independent: reconcile metadata only;
never repeat external delivery to settle local migration state.
