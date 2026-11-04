# CI shell pool: why each mechanism exists

Scope: `tests/shell_tests.sh`, `tests/lib/pool.sh`,
`tests/lib/pool_task.sh`, `tests/ci/manifest.sh`,
`tests/ci/core_binary.sh`. This is a suite-specific scheduler, not a general
process supervisor.

## Task boundary
Every task is a fresh bash process in its own session/process group
(`POSIX::setsid`). Embedded Lua harnesses use `$$` for `h$$`/`h$$c` names, so a
shared parent PID would collide; separate bash processes make those names
unique. The wrapper refuses to run if it is not the group/session leader
(exit 98) and reports the failure instead of running in the parent's group.

## Why process groups
Tests start daemons, fake agents and relays. A plain worker PID is not a
process group; signalling it would miss children, while signalling the pool's
group would hit unrelated work. The pool records the wrapper's pid/pgid/sid,
verifies pid==pgid (and pid==sid on Linux) before every group TERM/KILL, and
never signals its own group. Unverified groups are failed closed and only the
direct PID is signalled.

## Why cancellation is TERM -> grace -> KILL
Tests install EXIT/TERM traps that stop daemons and remove scratch dirs.
Immediate KILL loses that cleanup and the evidence. The pool sends TERM to the
owned group, waits up to `SHELL_TESTS_CANCEL_GRACE` (default 15s) for status
files/traps, then KILLs and reaps. Status/log/scratch are retained on
cancellation; the pool returns nonzero.

## Why a token and a PID registry
A wrapper may clear `REMUDA_*` (the live Codex test does), and a daemon may
`setsid`/double-fork out of the task group. `CI_POOL_TASK_TOKEN` deliberately
does not start with `REMUDA_` so it survives that clearing; one final
`/proc/*/environ` sweep finds those detached processes. On platforms without
`/proc`, a task-private `registry/*.pid` written by the task is the ownership
evidence. Both paths re-verify ownership and prove no survivor remains after
TERM/KILL; an unrelated session is never killed.

## Why private roots
Live Butler sessions export HOME/XDG/runtime/capability/daemon identity.
Inheriting them lets a test reach the live daemon or a shared cache. The pool
boundary clears live identity and gives each task private
HOME/config/data/cache/state/runtime/tmp. Deliberate knobs
(`REMUDA_BUTLER_LIVE_CODEX`, `REMUDA_LUA_RESULT_WAIT`, `BUTLER_TEST_FILTER`,
`REMUDA_BIN`) survive; `CODEX_HOME` is pinned to the real login before HOME
moves.

## Why a pinned-binary cache
The shell job needs one release `remuda` at `CORE_REF`. Building it costs
60-85s. The cache key includes OS/arch, runner image/ABI, full core ref,
Rust toolchain, profile and recipe version. Every hit/build is validated
against the pin; failed validation is never published or used. Publish is a
staged directory rename under a lock whose owner PID is recorded for
diagnostics. A SIGKILL may leave the lock; a waiter fails after a bounded wait
with the lock path rather than deleting a lock it cannot prove dead (the next
job has a fresh TMPDIR). The cache contains only the binary and metadata,
never daemon/home/
config/state.

## Measurement
`/usr/bin/time -p` reports wall/user/sys for the task and children it reaps.
Detached processes are not included, so summaries say "observed task rusage",
never complete CPU. Runner-minutes must come from GitHub job durations, not
the sum of task walls.

## Consolidation
Only setups with no assertion loss are removed: two definition-only shell
helpers, the harness around the pure path table, and child-daemon startup for
five controller-only files. Every remote helper in no-child mode fails closed.
High-risk lifecycle, reload, permissions, single-instance, relay,
diagnostics, identity/mail, scheduler and parser coverage stays.
