# Session tree rollout

The one-function `_butler_sessions` hot patch is the first rollout step, under
its separate authorization. Capture the current function in the live Lua image,
apply only the parity-checked renderer, verify `remuda butler sessions`, then
remove the temporary in-memory rollback reference after successful validation.

The persistent package update is a later, separate step and requires separate
authorization after the live hot patch has been validated and the reviewed
branch is pushed and available. Do not run it automatically after push. When
separately authorized, the sequence is:

```sh
remuda mod update butler
remuda stop
```

Those persistent commands have not been run as part of this work. The test
runner documents the exact private acceptance command and explicit Remuda binary
override.
