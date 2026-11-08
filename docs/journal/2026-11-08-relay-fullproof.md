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
