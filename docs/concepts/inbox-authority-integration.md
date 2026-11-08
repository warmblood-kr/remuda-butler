# Full Store SQL integration contract v1.2

Additive to existing v1: no method removal or return-type replacement. Product
inbox_authority.lua; only abstract contract amended here. Existing actual inbox
SQLite handle, versioned585-extended schema and Progress stages are reused.

New `Store:accept_external(key,payload)`:
key `{account=stableMatrixAccount,room=roomId,event=eventId,
destination=recipientHex}`; exact length-framed tuple, canonical strings,
never relay epoch/store/process/device. payload `{content=exactBytes,
metadata=canonicalJSON,payload_hash=64hex}`. Metadata contains original sender,
recipient, subject/date/thread/refs/Matrix facts; allocated mail id/epoch is
excluded from input hash. Verify payload_hash via configured SHA256 over framed
content+metadata. Immutable mismatch or same key/different verified hash =>
operation_conflict, no mutation. Key uniqueness is SQL constraint, independent
of operation receipt and process cache. Local store guarantees only, no claim
of distributed exactly-once. No external transport dispatch here.

First accept allocates stable mail id, publishes immutable content, then ONE
SQL transaction inserts key/hash/mail id, authoritative metadata, membership
and order/read default plus receipt. Same key+payload returns ORIGINAL receipt
and mail id even after read/restart/relay-store rebuild. A concurrent conflict
returns existing receipt after verifying hash; orphan unpublished content is
not membership. Standard outcome `{state,operation_id,result}`; result is
`{message_id,recipients={destination},receipt_id=operation_id}`. operation_id
is deterministic from protocol+key, distinct from a new mail ULID. Unknown
COMMIT retains that id and key; reconcile SAME id, no replay/new-id decision.

M.open uses existing config plus bound actual DB/Progress, actual root writer,
marker, immutable content publication, SHA256 and canonical JSON adapters.
Read marker BEFORE backend selection. Supported upgraded binary refuses any
unknown marker format/protocol BEFORE source/import/mutation. SQL-required
missing/unavailable/corrupt/schema-too-new => explicit refusal. Status reports
SQL-required even if unavailable, never FILE. Migration FILE-first writes require persistent FILE_TRACKED protocol/epoch
gate and live journal. DBdown refuses, never untracked FILE restart fallback.
Authority selection is centralized and mandatory for ALL mail entrypoints.

`page(recipient,{limit,unread_only},cursor)` returns existing rows/snapshot/
next_cursor/unread shape. SQL rows now include authoritative metadata, refs,
resent and read flags; envelope archive JSON is NOT consulted. snapshot
`{root,recipient,epoch,generation,upper_seq}` fences ack/pagination. First page
captures upper_seq; subsequent pages never include later arrivals. Read status
changes need not invalidate delivered-order snapshot; ack limited to rendered
ids <=upper_seq and known SQL membership in captured epoch. Error => no page,
no ack; partial rendering acknowledges ONLY successful ids via mark_read.
`hydrate(id)` under SQL joins SQL metadata with immutable body/note objects;
never reads legacy envelope JSON to repair metadata. Missing object refuses
render, preserves unread. `lookup_matrix` SQL exact key; unknown!=absent.

`deliver(intent)` and `mark_read(intent,ids,snapshot)` retain v1 shapes and
atomic receipt+allchanges semantics. Deliver fanout shares original id with
independent recipient read sets. Last PRESENT resent only; forwarding stores
note refs/addresses in SQL. Idempotent opid/hash returns original result, altered
hash conflicts. SQL-only delivery/read never appends legacy logs. SQL metadata
owns delivered authorization, membership/order, unread, refs and dedup.

`transition(expected,"SQL_ACTIVE",proof)` expected `{state="FILE_TRACKED",epoch}`;
proof `{generation,certificate_id,certificate_revision,tail_watermark,
epoch,operation_id,payload_hash}` (persisted certificate, not giant row array).
Internal backend rereads proofs; caller booleans cannot promote. Pre-prepare
failure is proven not_committed; after durable prepared marker failure is
unknown/sql_required, reconcile transition id. Prepared record and SQL epoch+
receipt finalization use one stable opid and next epoch. Marker finalization
never changes authority back to FILE on error. Status reflects recovery.

`reconcile(opid)` is phase-specific; see inbox-authority-owner-reconcile.md. Recovered
exclusive connection with completed SQLite recovery may prove not_committed;
missing receipt under unresolved recovery is unknown. Native661 atomic file
publication syncs file, rename and Unix parent (fs_atomic.rs103/117). An error
AFTER rename is unknown_publish: reread exact marker/content identity and
reconcile, never fallback. No unsupported-old-binary exclusion claim; support
set is upgraded protocol-aware writers with actual-root lock, no downgrade.
