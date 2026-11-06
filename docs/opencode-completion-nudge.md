---
layout: default
title: OpenCode completion nudge
---

# OpenCode completion nudge

A member can finish its turn and then idle without telling its leader. Butler
launches OpenCode members with a small server plugin that asks the member
itself, once per real work cycle, whether it has finished. The plugin never
reports for the member, never claims the task succeeded, and never contacts the
leader: only the member's own `remuda butler send-to-leader` does that, with the
member's own caller identity.

## Why a plugin and not a hook

OpenCode 2.2.5 (the installed release) has no stop or idle **hook**. Its plugin
hooks are prompt admission, model request (`context`, `compaction`, `generate`,
`title`, `model.request`, `http.*`, `retry`), tool `execute.before`/
`execute.after`, shell, and permission. Turn end is only visible on the event
stream.

Events verified against the installed binary, its served OpenAPI document, and
live sessions:

| Event | Payload | Meaning |
| --- | --- | --- |
| `session.execution.started` | `sessionID` | one admitted input's turn began |
| `session.execution.succeeded` | `sessionID` | that turn ended normally |
| `session.execution.failed` | `sessionID`, `error` | that turn ended with an error |
| `session.execution.interrupted` | `sessionID`, `reason` | `user`, `shutdown`, `superseded` or `inactivity` |
| `session.idle` | `sessionID` | session went idle; not emitted on every normal turn end in 2.2.5 |

`succeeded` means the agent loop for one admitted input ended; it does **not**
mean the assigned task is done. The plugin therefore only nudges; it never
writes a result or an outcome.

`ctx.session.synthetic()` on an idle session starts a new execution, so the
nudge wakes the member. That execution has its own `execution.succeeded`, which
is why loop prevention is structural rather than a timer.

## Identity

`launch.lua` starts an OpenCode member as `opencode --standalone <cwd>` with
`REMUDA_BUTLER_SESSION_NAME`, `REMUDA_BUTLER_AGENT_ID` and
`REMUDA_BUTLER_AGENT_KIND=opencode` in the child's environment. `--standalone`
gives each member a private server, so the plugin can require all three fields
and stay inert everywhere else. It does not read the caller capability, the
working directory, another session's transcript, or any daemon state. A
plugin-spawned `remuda` call has no caller identity (verified: `unknown caller`),
so the plugin never attempts one.

Known caveat: a nested OpenCode started **from a member's shell** inherits those
variables. Its sessions are then treated as that member's. The plugin only asks
a question that the member can ignore, so the failure mode is a stray reminder,
not a false report.

## Rules

Sent only when all of these hold for the turn that just succeeded:

- the turn consumed a real user inbox item (`session.inbox.delivered`, type
  `user`), tracked per execution so a queued second message is never attributed
  to an earlier turn;
- no delivered leader report in that execution. Report detection is narrow on
  purpose: a completed direct MCP tool named `butler_send_to_leader` (or the old
  `butler_report`); a shell segment that invokes `remuda ... butler
  send-to-leader` in command position with exit 0 and no refusal text; or a code
  mode `toolCalls` entry with that tool name, a known success status **and** a
  per-call result that is not an error or refusal (a success status alone does
  not prove delivery; the real tool event shape carries the result on the direct
  MCP event). A
  read-only mention (`cat`, `rg`, echo, a comment in code) never counts. Anything
  ambiguous fails closed: no result, an error flag, refusal text, an unknown code
  mode status, a missing shell exit, or a verb that only appears inside a quoted
  argument. A miss costs one extra reminder; it never produces a report. The
  reverse (suppressing a reminder after a report the detection cannot parse) is
  still possible, which is why detection is described as best effort;
- no other inbox item still queued;
- that user input has not been nudged already, and the 30 s cooldown has passed.

Never sent for `failed` or any `interrupted` reason, for a turn with no provable
user cycle (for example after a restart), for the nudge's own execution, or
twice for the same input. A cooldown-skipped cycle is dropped, not scheduled
late; an already-nudged input never re-arms.

Decisions are synchronous and the synthetic admission is dispatched without
awaiting it, so a slow admission cannot stall the event stream. A user prompt
that is admitted between the end of a turn and the nudge admission is steered
into the nudge's turn: the note stays visible, is bounded to one, and is not
cancelled. There is no claim of out-of-order cancellation.

The note is a synthetic message, visible in the transcript and described as
`butler completion nudge`:

> Butler: if you have finished this task and have not already reported to your
> leader, send the result now with `remuda butler send-to-leader` and stop. If
> you are still working, continue; do not start unrelated work.

Report detection is best effort, so the wording never asserts that no report was
sent. A completed tool call proves execution, not delivery; refusal text, error
flags, missing results and unknown statuses are therefore excluded instead of
assumed successful.

## Wiring

At launch, for `opencode` members only, Butler writes the plugin to
`<data>/remuda/butler/opencode/completion-nudge/index.js`, adds it to
`OPENCODE_CONFIG_CONTENT` as `"plugins": ["<dir>"]`, and sets
`REMUDA_BUTLER_COMPLETION_NUDGE=on`. Set the same variable to `off` (or `0`,
`false`, `no`) before a launch to disable it. No global OpenCode configuration
and no project file is modified.

## Other agents

- **Claude Code** already has a real `Stop` hook. Butler uses it for idle
  telemetry only (`status_hook.lua`); reporting to the leader is still an
  explicit `send-to-leader`.
- **Codex** exposes no status hook; Butler reads a status file through its TUI
  adapter, and reporting is explicit.
- **Monocle** has no hook either.

This nudge is therefore the first event-driven reminder in Butler. It reminds;
it does not report.

## Tests

- `tests/lua/butler_opencode_nudge_test.lua` — the plugin file, path quoting,
  and the `OPENCODE_CONFIG_CONTENT` fragment decode as JSON.
- `tests/opencode_nudge_events.sh` — extracts the shipped plugin source and
  replays events with node or jsc (56 checks): one nudge per user turn, no nudge
  for the nudge turn, queued turn deferral, MCP/shell/code-mode report
  suppression and every fail-closed case (refusal text, error flag, missing
  result, unknown status, missing exit, quoted compound), every interrupt
  reason, duplicate and concurrent success, cooldown and old-cycle behaviour,
  session isolation, restart and unprovable association, failed send, deletion,
  identity gate.

Live check on 2.2.5 (private server, explicit model): a normal turn produced
exactly one synthetic note, a turn containing a completed `send-to-leader` shell
command produced none, a provider-failed turn produced none, and a user
interrupt produced none.
