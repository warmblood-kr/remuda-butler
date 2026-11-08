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
  revision 40/40, case_turns 27/27, domain_priority 15/15, sealed 14/14,
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
- Near-32MiB is gated separately; record measured walltime and SQL page work
  rather than claiming a range that did not finish.
