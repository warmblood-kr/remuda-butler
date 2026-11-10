# Actual SQLite progress backend factory v1.1

Product target packages/butler/inbox_progress.lua. Abstract factory only in
inbox_progress_contract.lua. Additive to source-staging record API, unchanged.

`M.open({db=nativeInboxHandle,root=canonicalRoot,
json={encode=fn,decode=fn}}) -> Progress | nil,error`.
Returned Progress has bound DOT load/commit/scan/get signatures and exact
records from inbox-source-staging.md. No global remuda required by this module.
JSON encodes ONLY bounded cursor/individual canonical record fields; deliveries,
reads/dependencies/proofs are native SQL rows, never whole-mailbox JSON.
Canonical metadata is opaque already-canonical string, not decoded/reencoded.
json functions dot-call and return value or nil,error; catch thrown failures.
No physical table names prescribed, but use versioned inbox schema migration,
not ad hoc create/drop from factory. M.open validates schema/capabilities/root
binding, performs no import, data replay, authority promotion or file writes.
Too-new schema => schema_too_new, absent required schema => schema_unavailable.
A malformed config returns invalid_snapshot, never a fake in-memory backend.

Native db supports borrowed colon `exec(sql,params)`, `query(sql,params)` and
normal Remuda failure convention nil,reason (throws also caught). Existing #585
owns database lifecycle; proposed integration helper inbox_db.borrow_handle()
returns SAME already-opened actual inbox handle or nil,error, never a second
private DB. Expose only inside daemon integration, not caller CLI capability.
It must refuse when importer transaction is active. Caller serializes importer
and Progress operations on daemon Lua loop; no reentrant tx. Product may use
an equivalent explicit injected handle owner, but cannot substitute fake SQL.
Progress must NEVER close borrowed handle or commit/rollback somebody else's
transaction. Direct backend test owns handle and may close/reopen between calls.
Factory may capture handle but db failure doesn't silently open another root.

CAS/atomic rules: commit starts BEGIN IMMEDIATE, reads root+recipient generation
revision in that transaction, compares expected_revision then applies ALL delta
and cursor before COMMIT. Existing revision+1 success; nonexistent initial
revision0 creates exactly one generation. Stale revision => stale_generation,
ROLLBACK with no mutations; differing generation cannot overwrite existing
state. Root mismatch => invalid_snapshot. Zero SQL rows from failed query is
NOT absent. load/get/scan errors => unavailable/corrupt/schema classification;
no empty fallback. Mutation shape checked before BEGIN. A body/statement failure
with successful ROLLBACK returns not_committed and preserves old cursor/rows;
failed rollback/disposed connection returns unknown_commit. BEGIN failure that
proves no transaction began => unavailable, no mutation. Native SQL failure
string is mapped to error.code, diagnostic detail may be retained sans bodies.

COMMIT throw/nil/timeout => unknown_commit even when a subsequent ROLLBACK
succeeds: a successful rollback after ambiguity cannot prove prior COMMIT lost.
Attach `{generation,expected_revision,next_revision}` to unknown error. Caller
stops using this handle for write decisions; owner recovers/reopens connection.
No blind delta replay. Native recovery must finish before inspecting revision.
Reopened M.open on same actual inbox DB, then load(root,recipient):
- same generation/revision next_revision: batch committed (rows+cursor atomic).
- same generation/revision expected_revision: not committed, safe to resubmit
  SAME delta only after completed DB recovery/exclusive writer ownership.
- another generation/revision: stale_generation, no replay from saved guess.
- unavailable DB: unknown stays unknown, never absent/new initial generation.
Only one outstanding commit permitted per recipient; owner serializes same-root
writers. Keep next_revision receipt/journal until ambiguity resolved. Conflicting
same-key fileproof/chunkproof => stale_generation and full atomic rollback.
No sqlite INSERT OR REPLACE that drops prior generation/read facts implicitly.

Actual SQL RED tests must use a DB-capable core (661+ or verified equivalent),
real on-disk inbox database and shipped versioned migrations. ae9 lacks this
capability; classify unavailable rather than call Lua fake proof of SQL. Test
initial load absent, create/load/reopen, bounded multirow scan, CAS conflict,
statement failure rollback, lost COMMIT return despite persisted transaction,
reopen reconciliation, two recipients, source mutation invalidation, partial
never ready, and no data from another root. Inject DB wrapper failure AFTER
forwarding real COMMIT to model lost return; use real rows for assertions.
Do not inject made-up SQL result sets to count actual-native transaction PASS.
