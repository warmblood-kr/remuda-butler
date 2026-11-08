# Inbox foundation QA gates

These tests cover metadata dedup refusal, canonical source/progress witnesses,
SQL Store acceptance/receipts/ownership and bounded restartable prefix sealing.
They do not establish journal/tail crash recovery, final barrier/certificate CAS,
caller integration, full promotion, production deployment or native TUI delivery.

## Required isolation dependency

Shell wrappers source tests/lib/isolated_env.sh; native Lua entrypoints guard
before mutations with tests/lib/isolated_test.lua. Both files belong to PR #603,
exact reviewed dependency f321b9e6a31efef97999ecc0d08b2d7b00484717.
This test-only change intentionally does not duplicate those helpers. Integrate
that dependency before executing this checkout's wrappers. Missing helpers fail
closed. Independent verification used immutable product archives overlaid with
those exact helpers, with no guard removal or fake-success shim. Run only through
the wrappers; never dofile daemon-mutating suites in a live Butler daemon.

## Native SQL lane is mandatory

Use installed native66138e39db21c8f7d069589c779bf6ac589f777c for
butler_inbox_progress_contract.sh, butler_inbox_source_advance_contract.sh and
butler_inbox_store_contract.sh. REMUDA_BIN selects the executable. These wrappers
pin that core by default; no SQLite capability or migration failure may become
SKIP. The older ae9ce9513941 core lacks remuda.db and cannot prove SQL correctness.
No new build is needed. Shell wrappers create private homes/runtime/module roots,
start their own daemon, validate its socket and clean only their private state.
The default-seal timing case has a watchdog targeting only its own daemon PID.

From the repository root, after the isolation dependency is integrated:

    luajit tests/butler_inbox_authority_contract.lua
    luajit tests/butler_inbox_authority_open.lua
    REMUDA_BIN=/path/to/native661/remuda bash tests/butler_inbox_progress_contract.sh
    REMUDA_BIN=/path/to/native661/remuda bash tests/butler_inbox_source_advance_contract.sh
    REMUDA_BIN=/path/to/native661/remuda bash tests/butler_inbox_store_contract.sh

Source/metadata disk wrappers also use the isolation dependency and their
existing core_ref.sh default. The relay corruption fixture is registered in
butler_matrix_relay.lua and runs under its isolated parent suite, not standalone.
Its delivery path uses the actual main/init hook with injected terminal notify
and relay HTTP adapter; it does not prove native model/TUI delivery.

## Independent evidence and scope

Immutable product489537597eb5f743e808920cf66b4b6330247719 plus exact603 helpers:
Store36/36 and open13/13 PASS on actual native661 inbox SQLite. Earlier independent
scoped gates: authority42, progress19, source advance13, source18, metadata15.
The Store suite includes real COMMIT forwarded before a lost return, reopen and
original receipt recovery, zero retry allocation/publish, root/owner fencing,
actual Store dispatch fairness, captured log absence/size, aggregate byte limits,
zero-budget shrink checks and malformed/legacy cursor refusal.

The v8 upgrade case initially withholds the installed private0009 up/down files,
so the native runner really initializes v8. It restores the published pair and
reopens, proving v9, explicit old-row invalidation, new capture/rotation schema,
and unchanged FILE_TRACKED marker and authoritative legacy log bytes. It never
edits the protected migration ledger. qa_legacy_seal_0008.sql is the exact
published offset-only migration from487decf, used separately for refusal tests.

F.create bootstrap deliberately reports promotion_proof=false. Green prefix
sealing and SQL acceptance do not certify journal, tail, barrier or callers.

## CI registration

`native-sql-661` is a push-to-main-only job in `.github/workflows/tests.yml`.
It builds exactly core 661 and runs `tests/ci/native_sql_tests.sh`, which owns
only the three SQL wrappers (`progress`, `source_advance`, `store`). The runner
clears `REMUDA_SQL_CASE`/`REMUDA_SQL_TEST_FILE` and forces
`REMUDA_SQL_CORE_REF` to the exact 661 pin before each suite. It requires
exactly one progress summary (19), exactly one source-advance summary (13), and
the Store PASS names to equal the wrapper's exact 36-case set (including
multiplicity). It prints provenance (core/butler/runner hash), retains named
manifests and full logs under the runner temp, and uploads them as an artifact
on every outcome. A wrong pin, missing product file or migration, partial or
duplicate manifest, suite failure, or timeout fails; there is no SKIP and no
retry. `tests/ci/native_sql_negative_tests.sh` proves the real 661 binary
propagates forced `db.open` rejection, owner initialize/start, suite assertion,
and broken-migration failures (nonzero, no PASS) inside a disposable copy, with
a per-case bound.

The pure authority contract/open Lua suites run in the default shell lane in
both `all` and `policy` modes. The source and metadata disk wrappers run only
in the default ae9 shell lane on main. The five daemon-backed Lua contracts are
excluded from standalone LuaJIT; their `.sh` wrappers own them. The SQL `.sh`
wrappers are classified as delegated to this lane in `tests/shell_tests.sh`, so
an unclassified new script still fails closed. `tests/core_ref.sh` remains
ae9; only the SQL wrappers use the fixed 661 pin.
