# Canonical core row id on an old Lua projection

2026-11-05. Companion fallback for `row.id` missing from `remuda.ls()` on the
old 27b6 image. The daemon List wire still carries the stable id; only the Lua
projection drops it.

## Proof, not attestation

`native_identity.resolve(row, {rows, list, runner, json})` never trusts the
default server blindly:

1. `row.id` present and a token -> returned directly, no subprocess.
2. Else one bounded `remuda ls --json` (plain SessionSummary array, 5s,
   <=64 KiB). A parse error, nonzero exit, timeout or oversized output is
   typed `identity_unavailable`/`identity_invalid`.
3. Same-fleet check: the CLI set must equal the pre-yield `remuda.ls()` set
   exactly on count, unique names, non-empty opaque `instance_id` and strict
   boolean `alive`. This is current-fleet corroboration on the same account,
   not socket attestation; a cloned or replayed identical roster is outside
   the model.
4. Post-yield check: a fresh full Lua listing must still equal the pre set. A
   death, replacement, new or missing sibling fails closed
   (`identity_unverified`).
5. The target must appear once with the exact `name` + `instance_id`, be
   alive, and carry a non-empty id token. Duplicates and ambiguity are
   refused.

No alias and no instance-as-id, ever. An empty fleet cannot prove anything.
Nothing is cached: every launch/adopt proves again, so the agent/module/native
decision and pre/post id fences remain authoritative.

## Wiring

- `native_launch.join(plan, row, instance, resolve)`: uses `row.id`, else the
  injected resolver; any failure stays `disabled/missing_row_identity`, never
  PTY.
- `native_adopt.codex/opencode`: resolve once with the pre listing, fence the
  fresh `row.id`/instance before and after the helper, and require the stored
  id when the post projection has one.
- Notice/roster are unchanged: they consume the stored `row_id`/`session_token`
  and never look up per tick.

## Activation

Inert until the official `remuda ls --json` lands in the staged CLI. The live
27b6 daemon wire carries the ids, so the new CLI can read them without a core
takeover; the module-only source refresh then loads this consumer on the old
daemon. No config flips and no PTY in this change.
