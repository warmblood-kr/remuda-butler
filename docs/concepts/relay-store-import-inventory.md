# Relay JSON source inventory (read-only, 2026-11-08)

Read-only snapshot of the live legacy relay plus 661 capability. No live relay
start/stop/reload, no config/DB write, no Matrix or network call. The live owner
was still rewriting `.since` during inspection (mtime moved 15:40Z to 15:50Z),
so these are moving-snapshot numbers, not an immutable import source.

## Live files

`~/.config/remuda/butler/config.since`: 1,987,492 B, mode 0600, mtime
2026-11-08T15:50:34Z, sha256 starts `50de4b4a`. 14 root keys, max depth 4,
0 duplicate decoded keys, 48,009 JSON nodes. `since` is a 6-char opaque string;
`messages_since` is absent. No `.since.bak`, `.acks`, or `.acks.drain`.

Counts: `processed_event_ids` 5000 (all unique/nonempty; at MAX_PROCESSED
5000); `matrix_mail_routes` 2749; `matrix_reply_results` 1296;
`matrix_own_events` 975 in 2 rooms (500/475; per-room cap 500); `quarantine` 200
(at MAX_QUARANTINE_ITEMS); `matrix_thread_subscriptions` 396 in 2 rooms;
`approvals` 2; `pending_events`, `matrix_reply_outbox`, `invite_dedupe`,
`auto_join_timestamps`, `typed_line_timestamps`, `matrix_unfollowed_threads`
empty.

Legacy filters would currently drop none: 0 invalid/expired quarantine, 0
retention-pruned approvals, 0 routes/results missing required fields, 0 invalid
own events/subscriptions. The source is nonetheless at the processed and
quarantine caps, and a legacy load/save roundtrip can rewrite `.since`; the
`matrix.quarantine_list` CLI path can also save it while a relay is running.

## Mapping to the schema sketch

Splitting each map entry/array element into a row gives about 9,251 rows.
Largest one-level row: `matrix_own_events` room array 60,501 B/1,501 nodes
(leaf split <=120 B); subscriptions room map 22,514 B/542 nodes (leaf <=76 B);
`matrix_mail_routes` 1,005,505 B as one collection (2,749 rows, max 497 B/12);
results 489,363 B (1,296 rows, max 359 B/9); quarantine 92,651 B (200 rows, max
1,322 B/11); processed 235,001 B (5,000 rows, max 46 B/1). Every leaf record is
below 256 KiB/8,192 nodes. Collection rows are not: the source root is a
1.99 MB/48k-node JSON blob, so per-record splitting is mandatory.

## 661 native capability

`native/Cargo.toml` pins rusqlite 0.40.2 `bundled`; Cargo.lock resolves
libsqlite3-sys 0.38.2. The actual probe reports SQLite 3.53.2. `remuda.db.open`
defaults 64 MiB/1 s/10k rows; ceiling 1 GiB/10 s/100k; `max_bytes` is set via
`max_page_count`, timeout is per statement, and a query over `max_rows` fails.
The file is WAL + synchronous FULL, busy_timeout 5 s, 0600 in a 0700 directory;
the authorizer denies ATTACH/DETACH and most PRAGMA.

Probe evidence: a 9,437,194-byte raw parameter is valid; a 110,003-node source
is valid/countable in SQL while `remuda.json.decode` fails at the 100k value
limit; `json_valid`/`json_each`/`json_tree` exist; the MATERIALIZED page import
contract passes in about 0.17 s. `raw -> fullkey` keeps scalar token text;
`CAST(value AS TEXT)` loses precision.

Bounded SQL row import is therefore feasible. But the 32 MiB source cap does
not bound row count: live needs about 9k rows and a 110k-value source is about
1.7k pages of 64, while 32 MiB of tiny elements could be millions of rows. Add
an explicit source row/value cap and/or a page-time bound. For large sources,
raise `max_bytes` above the 64 MiB default: the store duplicates payload plus
indexes and cannot use the source file size as its DB budget.

## Shadow boundary

`relay.db`: `reply_receipts` 1,296 (sent 1,295/error 1), `receipt_conflicts` 0,
`receipt_meta` `import_committed=1296` and `receipt_authority=shadow`,
`txn_origin` legacy 1,296. Every result_json is semantically equal to its JSON
result; all 1,296 JSON results lack `txn_id` and the shadow derives
`legacy_<reply_id>`. Equal counts do not prove authority or completeness.

`inbox.db`: deliveries 14,601, reads 14,519, import_state 416; only
deliveries/reads/import_state exist. There is no `accept_external`/`source_key`
API; the inbox stays file-authoritative and outside this relay scope.
