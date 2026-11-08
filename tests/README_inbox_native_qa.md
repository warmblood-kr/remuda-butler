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
