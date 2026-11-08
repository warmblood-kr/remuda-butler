# Bounded source ingest evidence (2026-11-08)

RED before the fix: a single `import_source` turn on 9,557,025B / 19,000 legal
500B ids failed at 1.216s with the native Lua execution limit; the whole turn
aborted before any source row or hash offset existed. A 9,519,000B `.acks`
sidecar failed the same way in `import_acks`.

Implemented the root-approved contract: admission receipts, immutable
`relay_source_capture`, persisted phase progress, one <=64KiB hash chunk per
call, separate root hash, native JSON summaries, one field/room per call,
`ACK_SCAN` <=64KiB/64 ranges and `ACK_APPLY` <=64 ids/<=256KiB. `import_batch`
auto-drives JSON ingest then record pages. `verify_import`/`activate` refuse
pending or blocked artifacts. `PROOF_VERSION` is 5. Migration 0004 adds the
three staging tables.

Evidence on this candidate:

- 9,557,025B source, every step its own native turn with reopen checkpoints:
  admission returned hashing receipt; 146 hash chunks; JSON/discovery; 297
  record pages; 459 verify calls, max 0.612s, 19,000 processed rows, verified
  and activated.
- 9,519,000B `.acks` plus the 9.55MiB source: CRLF/blank/duplicate lines,
  19,004 ranges, 19,000 processed ids, 606 verify calls, max 1.15s, verified
  and activated. Sidecar and source ingest ids stayed distinct.
- Edge suite 9/9: capture UPDATE/DELETE/REPLACE abort; exact retry same receipt;
  changed equal-length bytes `source_changed`; tiny hash budget
  `budget_too_small` with no offset/revision advance; empty ack positive; CRLF/
  blank/duplicate preserved; torn EOF `ack_partial_eof`; >256KiB ack
  `ack_oversize`; 100,000B ack spans scan units and applies once.
- With drivers updated to drive ingestion and expect `ingest_pending`:
  revision 37 executed PASS + 3 queue SKIP; case_turns 26 executed PASS + case17 SKIP, domain_priority 15/15, sealed 14/14,
  projection 3/3, upgrade 8/8, long numeric 13/13, long attempts 8/8, scalar
  budget 2/2, plus verify/owner/recovery/domain/scope/migration/protocol.
- 110,001-row persistent proof: 1742 verify calls, max 0.141s, 0 mismatches,
  27 reopens, certificate and activation true.
- Ack scan ranges are keyed by original line start and INSERT OR IGNORE, so a
  lost COMMIT cannot duplicate a range; the first line at byte zero is ordinal
  one. Large ack E2E reran on this key: 606 verify calls, max 0.865s.
- COMMIT recovery 5/5: admission lost reply returns the same ingest id; hash
  lost reply resumes at revision/offset; pre-COMMIT abort leaves revision 1 and
  offset 0; ACK_SCAN lost reply keeps one range; ACK_APPLY lost reply keeps the
  delivered event and applies once.
- QA `ingest_edges.lua` 14/14 after HOLD fixes: the capture trigger now refuses
  a same-PK REPLACE with a different identity, source/sidecar admission
  unknown-COMMIT quarantines the lease, and a READY ingest_step returns numeric
  count/bytes/nodes.
- Discovery reads a key length before fetching it: a 100,000B key under a
  1024B call budget returns budget_too_small without advancing; 300,000B is
  field_oversize; the capture remains.
- Cursor projection: a 100,000B since value is inserted by SQL (`raw -> path`,
  `json_extract(raw -> path,'$')`) without returning token+value to Lua; the
  step reports and charges the 100,002B token. Cursor parity also compares in
  SQL. QA cursor budget 1/1.
- Near-32MiB source: 32,630,025B / 65,000 x 500B ids, every advance its own
  native turn with 23 reopen checkpoints; 1,530 verify calls, max 4.092s,
  total 2,318.6s, 65,000 processed, verified and activated. The max call is
  SQL re-reading the 32MB raw to return 64 rows; no raw enters Lua and the
  result is not a universal byte-bound claim.
- Startup/archive caller RED fixtures added under `tests/red/`: blocked
  authority must stop `matrix.relay.start`, a single bounded `migrate.step`,
  a real inbox producer for `authority.start`, and archive planning only with
  both proofs.
- Static RED cleared: step is one store action (acks/drain are sidecars, not
  manifest rows), authority refuses without the real producer proof, archive
  requires both proofs, and relay.start/new plus boot use the gate.
- Native gate: 61 bounded advances, max 1 action each, changed stamp refused,
  producer shape accepted, tampered/blocked refused, restart resumes, adapter
  binds, archive plans 4 files with 0B ack/drain.
- Inbox producer `9cb44ef` supplies the flat identities plus the exact NUL
  `butler-inbox-compat-v1` tuple; store_id may be `config.store_id`,
  data_revision is frozen, verification_id is the final proof hash.
- `authority.adapter(providers)` binds once, then start(cfg,{inbox_proof=fn})/
  advance/certificate/status/inventories for the inbox coordinator.
- `relay_archive.providers` copies <=64KiB chunks to durable `.part.NNNN`,
  writes a digest manifest, re-reads one part per call, then renames and
  fences both parents; no whole-file SHA/publish. Native: 200KB -> 4 parts,
  max 65536B/call, manifest reopen resumes verification.

