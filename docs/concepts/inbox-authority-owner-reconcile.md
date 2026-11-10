# Strong owner and phase-specific reconciliation

v1.3 integration clarification, overrides generic missing-receipt shortcuts.
No product change implied by these contract requirements.

## Actual-root owner capability

Cross-process kernel guard is necessary but insufficient: fs.lock may admit a
second owner in SAME process. Maintain process-local exclusive Store registry
keyed by canonical actual root (resolve aliases/symlinks before registration).
M.open atomically acquires registry entry plus cross-process guard and issues
opaque nonforgeable owner capability. Second M.open for same actual root fails
writer_conflict even when injected guard boolean says owner=true. Registry is
shared by ALL Store instances, not one per module reload; daemon-owned lifetime
registry survives reload, invalidates old capability on controlled replacement.
No caller-provided owner=true or root string is a mutation permission.

Every Store mutation/import/tail/admission/marker change validates current owner
capability+root+generation immediately before commit/publish. A paused old
Store resumed after release/replacement returns writer_conflict, never writes
using cached marker/epoch. Owner release removes entry only if it still holds
that exact token; stale release cannot evict new owner. Borrowed DB lifecycle
remains actual585 owner responsibility. Reentrant mutation returns busy or
writer_conflict before BEGIN, not a nested transaction on borrowed connection.

Native write_atomic gives durable replacement, NOT compare-and-swap. Marker
prepare/finalize compare expected protocol/root/epoch/transition id AND validate
current owner inside SAME serialized nonyielding owner turn as publish. Read
then yield then unconditional rename is forbidden. Cross-process guard and
process registry exclude competing supported publishers. After rename error
reread exact published identity under same owner; unknown remains unknown.
An async callback must reacquire/validate token on resumption, not inherit a
stale authorization. If atomic helper yields, serializer remains held across
it and completion must revalidate owner before any subsequent finalization.
Unsupported old writers bypassing all protocols remain outside support claim.

## reconcile(operation_id) depends on durable phase

FILE_TRACKED: journal intent records original mail id/opid/hash, source file,
before offset, expected exact appended bytes length/hash and expected complete
line identities (bounded records). Missing SQL receipt is NOT not_committed:
legacy append may already be authoritative. Recover same actual root owner,
load journal and inspect exact surviving source range at recorded offset.
- Complete expected range+identities matches: stage/adopt existing source facts,
  finish receipt for ORIGINAL id/opid; no second append, no second ULID.
- Proven no bytes appended, no later range occupying reserved offset, journal
  still pending: not_committed only after resolved exclusive recovery.
- Torn range, conflicting bytes, unknown later append, unreadable source or
  missing journal despite evidence of tracked attempt: unknown/recovery_required,
  never empty or automatic resend/retry. Partial append cannot be called absent.
Same-opid retry first reconciles FILE outcome; changed payload conflicts.
Existing external request uncertainty is separate and never causes transport
replay. Original id must be allocated/persisted in intent BEFORE file append.

SQL_REQUIRED/SQL_ACTIVE: no file append permitted. Query atomic SQL receipt and
matching epoch/opid after completed SQLite recovery under valid exclusive owner.
Committed receipt returns original result. Proven absent only after no unresolved
transaction/journal/pending admission for same opid may return not_committed.
Unavailable DB or unknown marker => unknown. A caller retry cannot manufacture
new id/source key to bypass unresolved operation. Marker transition reconciliation
also checks prepared transition opid/epoch; no FILE fallback on missing receipt.

QA: actual same-process second open of same canonical root rejected; alias root
also rejected. Pause old owner's finalize, replace/release owner then resume:
writer_conflict and unchanged marker. Inject guard fake owner=true must NOT
bypass registry. write_atomic spy proves expected compare+token validation under
serializer. Tracked crash after full append/before SQL receipt recovers SAME id,
no duplicate line; torn append remains unknown. SQL-mode missing receipt test
cannot be reused to assert FILE not_committed. Pair all errors with successful
valid-owner/complete-range positive cases using actual source files/nativeSQL.
