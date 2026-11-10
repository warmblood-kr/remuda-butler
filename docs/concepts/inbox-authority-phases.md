# Practical SQL authority delivery phases

Supported production set: upgraded marker-aware writers/readers using the actual
root guard; downgrade and unmanaged old writers are explicitly unsupported after
promotion. Existing files retained. This enables real SQL metadata authority,
not indefinite file-authoritative optimization. No further owner approval gate
is introduced. Product and QA work proceed against contract v1.

1. Pure parity + metadata lookup: implement certifier, canonical source/SQL
adapters and recipient/room/event index. QA positive exact parity and paired
same-count wrong ID/order/read/refs/metadata mutations. Preserve last PRESENT
resent: A(resent R),A(plain) => R; A(R),A(R2) => R2. Matrix new event opens zero
historical bodies; exact hit hydrates only hit; corrupt metadata refuses. Normal
page rendering may hydrate each selected row.

2. Restartable migration: extend #585 importer, versioned SQL migrations,
staged rows+cursor in one transaction, full source generation proof and exact
certification. Enumerate inbox AND read-only recipients; retain orphan reads,
malformed/unreadable records explicitly, never silently skip. Source mutation
invalidates generation, not whole original file. Resume bounded work through
lifecycle pump. No ready from partial/torn/skipped input. Failpoint test each
statement/commit and restart, compare exact original IDs/read/refs/order.

3. Store integration: centralize open/marker decision before DB opening. FILE
supports proven file path while migration runs; after prepare SQL is required.
Migrate all metadata callers: delivered authorization, unread/is_unread,
page/read acknowledgements, forwarding/resent and Matrix dedup. Tri-state
unknown survives every caller, never zero or permission. Existing immutable
body/envelope hydration remains permitted. Test SQL failure under each marker,
with stale files containing deceptively valid old rows.

4. Promotion: hold actual-root writer capability; catch up tail; exact certify
all recipients inside stable boundary. transition(expected,target,proof) takes
expected `{state,epoch}` and target `"SQL_ACTIVE"`; proof contains current full
certificates and generation. Before intent publication validate all proof and
schema, then atomically persist CUTOVER_PREPARED with stable transition id and
next epoch. In one SQL transaction record authority epoch/generation and its
operation receipt. Finalize external SQL_ACTIVE marker. Prepared boot uses SQL
recovery only, checks receipt/epoch then finalizes marker. Unknown publication
or COMMIT reconciles same id, never file fallback or a second migration intent.
Test cooperating second writer lock refusal; unsupported legacy bypass remains
outside the support claim. No live rollout is implied by isolated tests.

5. SQL writes: publish immutable content before transaction visibility; one SQL
transaction commits all recipients, first distinct dense order, last present
resent, Matrix dedup key and operation receipt. Read ack transaction records
only rendered witnessed ids. Duplicate operation id returns original result;
changed hash refuses. COMMIT exception returns unknown, reconcile via recovered
connection before classifying. No automatic external send/resend. Test restart
and fanout atomicity, lost return after COMMIT, DB unavailable after promotion,
post-promotion file append ignored/refused rather than adopted.

6. Export/reverse: transition expected SQL_ACTIVE to target FILE is a REVERSE
operation, not marker deletion. Hold writer; resolve all uncertain operations;
export EVERY SQL-only delivery/read/resent/ref fact to a separate staged legacy
layout preserving ids and order; exact certify exported view against SQL. Keep
original source and SQL untouched until publication. Persistent reverse intent
remains sql_required through export/publication crashes. Atomically publish
complete export layout using supported root publication primitive, then commit
new FILE epoch marker only after exact parity. If atomic layout publication is
unavailable, reverse returns not_committed with proof/reason and leaves SQL
active; forward production still works. No automatic rollback on SQL error.
Tests cover SQL-only mail/read export and each interrupted reverse step.

Schema contract is semantic, not frozen physical names: retain585 tables and
importer; version additions for staged generations, resent/metadata/dedup,
authority epoch and operation receipts. Every receipt lives in same SQLite
transaction as its changes. File witness/count is not authority after promotion.
