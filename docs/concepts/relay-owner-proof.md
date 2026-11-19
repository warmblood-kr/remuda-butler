# Relay owner proof after a reload

The lifecycle treats a relay that was running when an activation stopped as
owner-unverified. `init.lua` restarts it only when
`matrix.relay.owner_proven()` returns true; otherwise it reports
`owner_unknown` and stays stopped. Until this change no production relay
implemented that method, so the barrier could never open: after a source
refresh (and after the reload path that refreshes the mod) the relay stayed
down while mail and the CLI kept working. Replies then failed with "Matrix
relay is not running".

## What the proof covers

The proof is **image-local**. `remuda._butler_relay_owners` is a registry in
the current Lua image:

- a start registers its instance and clears the proof;
- a stop unregisters only after every schedule handle it armed has left the
  core `remuda.schedules` registry;
- `owner_proven()` is true when no instance is registered and the last
  teardown was verified.

This proves that no **previous activation in the same image** can still own a
poll loop. It is exactly the boundary the barrier needs: a source refresh
stops one activation and starts another inside one image, where a hidden timer
closure is possible.

## What it does not cover

The proof is **not a process guard**. Cross-daemon exclusion is the guard's
contract, not this registry: `guard.lua` holds two OS advisory locks for the
owner's life (the data-home `butler/lock` and the resolved config path plus
`.lock`), conditional on the core providing `remuda.fs.lock`. `owner_proven()`
cannot see another OS process or that process's schedules. On a core without
`remuda.fs.lock`, guard reports "not guarded" and this proof cannot compensate.

A daemon reload starts a new process with a fresh registry, and the old process
is gone, so there is no writer to prove. Do not read `owner_proven()` as a
process-lifetime lock: a future reload that keeps a process alive, or any path
that can leave a writer outside the image, would need a separate OS-level
guard.

## Failure behaviour

- A live instance is never proof: the barrier stays closed while a relay runs.
- A stop whose cancellation did not land keeps its handles and its registry
  entry, so the barrier stays closed (`owner_unknown`) instead of racing a
  hidden writer. A direct retry that verifies every handle clears it.
- A core without `remuda.schedules` cannot verify cancellation, so it fails
  closed: an old core keeps the relay stopped rather than risk a second writer.
- A cold image has no marker and starts normally.

## Coverage

- `tests/butler_lifecycle_reload.lua`: the barrier's resume/stop graph with a
  stubbed relay.
- `tests/butler_matrix_relay.lua`: the real relay module proves a cold start, a
  live writer, a verified stop, an unverified stop, and a retried stop.
- `tests/live_reload.sh`: the real daemon and mod source refresh; every reload
  must restart exactly one owner, and the old mod (no proof) must stay down.
- `tests/butler_reload_real.sh`: a real `remuda reload` must leave exactly one
  owner and preserve the queued mail exactly once.
