# Private reload recovery fixture

`recovery_fixture.sh` runs cases A, B and C against a reload-capable private
daemon. It never addresses the default runtime and never runs
`--check`/`reload`/`stop`/`close` against a production daemon. The private O is
live, but it is disposable and owns its scratch.

```
REMUDA_BIN=/path/to/reload-capable/remuda tests/reload/recovery_fixture.sh
```

Every daemon and client runs with `env -i` in a fresh, owned, 0700 scratch
tree. The fixture refuses the default runtime, uses a private `init.lua` serial
as a fresh-image marker, and keeps its scratch on an unclean failure.

- **A**: creates a host-backed session (`REMUDA_EXPERIMENTAL_SESSION_HOST=1`),
  requires `version --hosts` to report it, requires `reload --check` to be
  ready, reloads, and asserts the old PID is gone, a different PID serves the
  same socket, the init serial advanced, the host identity/session survived,
  and `<socket>.daemon-id` stayed the same (it is designed to outlive a daemon
  process). A same-binary reload cannot show a build transition; the live
  `27b6e99 -> 66138e3` transition is explicitly unproven.
- **B**: creates an in-process session without the flag, requires both
  `--check` and an actual `reload` to be blocked with the exact session name,
  and asserts the old PID, daemon id, socket and session are unchanged with no
  candidate left.
- **C**: injects an inline relay-style fake `schedule`/`cancel`,
  `_relay_timers` and `_fake_http_timers`, plus a fake callback registered but
  never invoked that would write a private counter file if replayed. It
  reloads and asserts the fake globals are gone, the counter file is still
  empty, and the real one-shot (`remuda.after`) fires exactly once, a real
  `remuda.schedule` ticks and stops after cancel, and the host survives. It
  does not require `_butler_matrix_request_clock` (an optional test seam;
  production is nil) or an empty `remuda.schedules`.
  C proves fresh **core** primitives, not real Butler graph recovery: this
  fixture does not install a private Butler mod/roster. That is a separate
  fixture.

D (request-receipt timing across the 10 s handover) and E (HANDOFF=1 mismatch)
are not implemented here and are printed as `UNVERIFIED`, never PASS. Case A/C
also report `UNVERIFIED` when host-backed creation is unavailable in the
environment rather than counting an in-process session as hosted.

The fixture is under `tests/reload/` so the `tests/*.sh` runner does not pick
it up; it requires a reload-capable binary, not the pinned test core.
