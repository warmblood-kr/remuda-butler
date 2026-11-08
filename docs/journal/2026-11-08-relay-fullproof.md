# 2026-11-08 relay full-proof

Implemented the root-approved phased proof on `feat/relay-sqlite-authority`:
immutable `relay_verify_witness`, `witness -> source_rows -> target_reverse ->
derived -> ready` progress, byte-chunk rehash, structure/cursor parity, reverse
target coverage, bidirectional derived checks, and certificate/activation
witness binding. `return nil, fail(...)` was removed everywhere because it
returned `nil, nil`.

Evidence: `revision_proof.lua` 40/40, `verify_focused.lua` 3/3,
`migration_0003_check.lua` 16 tables/31 `relay_rev_*`, `changed_raw_witness.lua`
refuses changed raw and aborts UPDATE/DELETE/REPLACE, owner handoff and
committed-recovery checks pass with the witness. QA `case_turns.lua` is 26/27
because case24 still calls `verify_import()` once; it must loop until
`verified` or a nil refusal. 110001-row evidence is in
`/private/tmp/relay-sqlite-qa/fullproof-110k.log`.

Reverse records are proved by per-`namespace/parent_key` target count vs unit
`expected` after forward exact per-row parity, not by per-row PK JSON lookups;
this keeps the call bound and needs lead/QA acceptance. Derived joins add
`r.parent_key=''` so the processed parity uses `relay_records_order` and stays
under the 10s statement timeout.

## Sealed/domain HOLD correction

QA `sealed_proof.lua` produced eight counterexamples against 0616730: missing
whole original domain, `unknown:` namespace alias, empty namespace tuple,
sealed backup loss, fabricated `inbox_mail_id`, retained old trigger
definition, empty ack, and CRLF ack. The fix adds a paged original-source
domain walk (keys and nested rooms) with an exact domain<->unit bijection,
sealed-baseline->source reverse membership, exact namespace injectivity with
the empty tuple included, expected=0 refusal, zero-byte witness hashing, CRLF
normalization, NULL `inbox_mail_id`, and trigger drop/recreate on open.
All 14 sealed/coverage cases now pass.

Two additional boundedness edges surfaced while validating the 64-key envelope:
raw units are complete after their one row (both import_batch and source_rows),
and structure parity is paged over units then fields instead of loading them in
one call. A 64-key source now verifies, and max_rows=1 no longer replays a raw
row or inflates staged_count.

Outbox attempts are compared with the import normalization: integer tokens and
integral real/numeric-text tokens (1.0, "1") become the same integer, while
1.5/"x" normalize to NULL. A direct test confirms 1.0 and "1" verify as 1 and a
later mismatch refuses with import_incomplete:intent.

## 646b static correction

The next candidate adds: started cursors so an empty original root/room key is
not skipped; raw units require parent='' nested=0 in both structure and reverse;
sealed baselines are checked one per call; domain keys/rooms and structure
units/fields advance one per call; source rows advance at most one unit per
call. Outbox attempts are checked in a bounded Lua page using the importer's
`tonumber` rule, which fixes 1junk/1e2/0x10. Schema open compares installed
trigger SQL with the recreated SQL and bumps data_revision on any difference,
invalidating a READY certificate made under a weak trigger. Field paths require
one canonical interpretation, parent identity is part of the match, and `$` is
mandatory. The many-domain and node-rich scope probe is
`/private/tmp/relay-sqlite-qa/scope_limits.lua`.

## 42b upgrade/outbox HOLD

Four QA REDs fixed: schema repair now writes a durable pending marker before
bumping data_revision, deletes checkpoints/certificates and fails closed if the
bump aborts, and retries from the marker on the next open; relay_schema_state
stores the trigger fingerprint. relay_proof_state binds PROOF_VERSION to a
verification, so a 646 (or older-verifier) READY certificate is reset and
reverified while same-version resume continues; READY and activation require
it. The outbox page selects only attempt/txn scalars and a SQL payload-equality
flag, never payload JSON, and has no lower bound on its first page so an empty
reply id is validated. Migration is now 18 tables / 31 relay_rev_*; QA's
migration check reports 18.

## 010 HOLD correction

The candidate fixes three groups: pending=1 is written before
repair DDL when the state table exists (a missing fingerprint row is the
durable signal on first creation), so an aborted pending publication leaves the
old trigger fingerprint and retries; certificate ids are recomputed from their
exact stored inputs plus PROOF_VERSION and require the proof_state store id, so
an old 646 certificate or a wrong-store version row cannot bless READY; and the
outbox page checks each text attempt's length against max_bytes, fetches it one
row at a time, and applies the exact Lua tonumber rule; txn/payload equality stay
in SQL. PROOF_VERSION is 4. Schema state stores schema_version + pending before repair.

`abee747`: 13/13 long numeric forms, 8/8 long attempts; 110001 rows in 1742
calls, max 0.144s, 0 mismatches, 26 reopens.
