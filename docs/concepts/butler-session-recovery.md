# Explicit recovery of an unreachable Butler session

Scenario: a session is alive in the registry but unreachable — the x600 host
panicked, its reader thread died and the PTY mutex is poisoned, so input never
reaches the child and `close` cannot tear it down. The owner accepts that loss;
the team must come back with the same role, leader, workdir and members.

This is not the lease/takeover path. A lease takeover re-claims a *logical*
root whose instance is gone; this replaces a *physical* instance that is still
listed, and it therefore has to kill first.

## What the representation already gives us

- **Registry row** (`remuda.ls`): `name`, `instance_id`, `alive`, `team`
  (`agent_kind`, `model`, `leader{name, instance_id}`) — no `unavailable`, node,
  argv, cwd or env, so Butler cannot prove from Lua that a session is broken.
- **`agents.jsonl`**: durable ULID per alias and `leader_id`; an alias keeps its
  id across restarts.
- **`roster.json`** (private): alias, id, kind, model, session name,
  `parent`/`parent_id`, cwd, sandbox, writable, instance id, native row. It is
  the only durable launch spec; the root's `cwd` is recorded at registration.
- **Mailbox**: per-alias JSONL under a shared root, addressed by alias and
  message id. **Memory**: `memory/<alias>`. Both are keyed to the logical alias.

## Why identity continuity is the safety property

A member references its leader by **alias** (`parent`) and **ULID**
(`parent_id`); `send-to-leader` resolves the alias at call time. A replacement
that reuses both keeps every member's leader link, inbox, memory directory and
lineage check valid, with no member-side rewrite. A new ULID would silently
orphan `parent_id` everywhere.

That is why the replacement is "same logical identity, new physical instance",
the same split the effective-name work makes for the root.

## Kill eligibility (implemented in `packages/butler/session_recovery.lua`)

1. the operator names the **exact instance id**; a row without one is refused,
   never guessed, so a name reused by a live session can never inherit the
   previous decision;
2. the operator must **declare** the session unreachable — the registry does not
   prove it, and Butler must not pretend it did;
3. exactly one registry row may carry the name; a duplicate is a stop;
4. the roster row must bind the **same** instance and carry an id; otherwise the
   replacement cannot be rebuilt from what Butler recorded;
5. workdir and agent kind come from the roster or an explicit flag — never
   invented;
6. the caller may not replace itself.

## Order of operations (the apply step, next PR)

```
capture (roster row + row + id)  ->  refuse unless every rule above holds
kill   instance-fenced, by name + instance   ->  row retired, "screen lost"
verify the row is gone and the name is free
relaunch same alias, same ULID, same physical name, argv rebuilt from roster
re-bind the new instance; members keep parent = alias and parent_id = ULID
```

Live state is never repaired in place: a poisoned host has no recovery path
from outside, so kill-and-replace is the only safe move.

## Partial failure

- Kill failed: the row stays; report and stop. Never start a second instance
  under a held name.
- Kill succeeded, launch failed: no leader and a free name. Report exactly that;
  a retry is another explicit decision, never a timer.
- Nothing runs from the poller, `init.lua` or a schedule: only an operator
  naming an instance starts the sequence.

## Prerequisites in the core (from the x600 field report)

- `remuda.ls` does not expose `unavailable`, so the declaration is the
  operator's, not an observation; exposing it (with the node) would turn the
  claim into evidence.
- `remuda.close(name)` takes no instance and, on a failed transport, may leave
  the row `unavailable` without retiring it. The kill step needs an
  instance-fenced call that SIGKILLs the host, retires the row and says the
  screen is lost.

Until that exists, Butler can only decide and print the plan.

## Limits stated, not fixed

- The old screen and scrollback are the host's only copy: they are lost, as is
  child process memory; only what is on disk resumes.
- Memory and mail are shared with any surviving descendant of the killed
  instance (the same limitation the effective-name work states). Killing the
  host does not prove a `setsid` descendant is gone; it can still write.
- No environment value is copied or persisted: the replacement is rebuilt from
  the roster and the current daemon image, so tokens never travel through a
  plan file. A value that cannot be re-derived is a refusal, not a guess.

## Tests

- `tests/session_recovery.lua` (fast): the decision and rendering rules.
- `tests/lua/butler_recovery_plan_test.lua` (deep): a real child daemon — the
  live registry and roster, a mismatched instance, a missing declaration, and
  no change (the root is the same live instance afterwards).
