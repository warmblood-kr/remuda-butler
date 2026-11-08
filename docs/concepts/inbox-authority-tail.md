# Migration: sealed prefix plus tracked tail

v1.2, same585 DB/importer/Source/Progress.
Do NOT run two full passes over a moving EOF and restart whenever mail arrives.
Legacy logs and immutable content remain retained.

1. Under actual-root supported-writer guard, install migration live hooks on
EVERY delivery/read/forward/legacy-alias path BEFORE recording base manifest.
Persist FILE_TRACKED protocol+epoch gate BEFORE hook-admitted mutation.
DB-down restart/mutation refuses; no ordinary FILE fallback. Brief writer turn
captures per-recipient inbox/read byte offsets as sealed prefix; manifest rows
are bounded SQL records. Enumeration is resumable; hooks add newly seen
recipients. Per-mailbox sealed ends, no giant manifest JSON.
Source pass1/pass2 read exact [0,sealed_end), not live EOF; new suffix arrivals
never invalidate completed prefix. Full-prefix byte rewrite still invalidates.
A nonnewline sealed boundary excludes torn tail; torn bytes tracked explicitly,
never skipped or declared ready. Existing immutable dependencies permit delayed
content verification. NEW migration-sealed-v1 domain includes generation and
sealed ends; existing source-progress-v2 resume is unchanged. See barrier doc.

2. Introduce internal backend `migration.seal(recipient)` ->
`{generation,recipient,inbox_end,read_end,revision}`;
`migration.advance(recipient,budget)` -> `{state,cursor,complete,tail_watermark}`;
`migration.barrier(budget)` -> `{state="ready"|"backlog",watermark,proof}`.
These are backend helpers, not new public Store API. Store:advance schedules
bounded prefix/tail tasks fairly using persisted round-robin cursor. Extend
Source with fixed-length log read views; existing basic snapshot API unchanged.
Each prefix generation retains both passes/cursors, not a fresh scan per call.

3. Hooks append durable bounded intent to SAME inbox DB BEFORE touching legacy
files: `{generation,mutation_id,recipient,kind="delivery"|"read"|"resent",
path,before_offset,bytes_hash,expected_length,operation_id}` plus immutable
metadata refs and ORIGINAL mail id, no payload serialization. This is tracking intent, NEVER delivery
or read authority. FILE remains commit authority: then actual legacy append;
then record actual surviving complete lines and resulting offset transactionally
in tail stage. Normal hooks run existing585 file-first shadow updates too.
Before/after source IDs/read/resent canonical rules unchanged. File failure
reconciles surviving complete prefix; partial tail is unresolved, not synthetic.
Crash after intent/before append => no mail invented. Crash after append/before
tail stage => resumed bounded source scan from recorded offset adopts actual
complete rows. Ambiguous append never repeats external request/new ULID.

Migration-mode journal unavailable refuses that mutation explicitly; no false
successful delivery or quiet-window wait. This is normal storage failure,
not a global human-input pause. Reopen resolves intents against actual file
bytes, then resumes. Journal must be enabled for ALL admitted supported paths;
untracked old protocol refuses rather than mutating behind captured offsets.
No claim that an old unmanaged binary ignoring markers is physically excluded.

4. Tail stage uses original delivery ids, first occurrence rank and last PRESENT
resent; later read rows update exact read membership, including orphans. Base
publish + ordered tail delta application are atomic staged generation changes.
Receipt/tail cursor transactions make replay idempotent by mutation_id+source
byte range/hash, not counts. Bounded scan catches up pending intents while
new hooks keep appending. Prefix restart occurs only for actual sealed-prefix
mutation/corruption, not new mail or read marks. Resolved watermark is a durable
monotonic journal sequence, including per-file witnessed offsets.

5. Promotion uses a bounded FINAL writer turn, detailed in
inbox-authority-barrier.md. Exact prefix certificate is precomputed and persisted
OUTSIDE barrier, tied to generation/revisions/watermark. Final only bounded tail
<=T and aggregate certificate/revision/epoch CAS; excess or dirty proof returns
backlog BEFORE prepared. No full recertification/source scan inside barrier.
Prepared requires SQL, then SQL epoch+receipt and final marker converge same
opid. Admission requires durable pending intent or explicit SAME-opid caller
retry ownership, never presumed durable existing queue.
No eventual-promotion promise under load exceeding catch-up capacity
or unresolved damaged records. With adequate processing capacity, ongoing
append does not reset backfill: every call advances persisted prefix or tail.
QA must demonstrate arrivals throughout many calls/restarts then bounded final
barrier, original IDs/order/read/resent preserved. This is not a silent FILE-
authority substitute: SQL_REQUIRED then SQL_ACTIVE are actual promotion states.
