# Automatic mailbox wakeup investigation

Baseline: Butler `2fe6ef9`, also the installed source revision. Design and early
QA used Codex gpt-6.1-sol; programming used OpenCode Go deepseek-v4.1-flash.
The team agreed the plan before implementation.

## Reproduction and policy

Read-only captures of `cluster-ui-flash`, `cluster-ci-flash`, and
`cluster-ui-peer` showed empty composers. Running the installed OpenCode parser
classified them NON-EMPTY, with 9,350, 10,243, and 277 bytes respectively. Its
upward scan absorbed historical bordered output across intervening prose.
Peer delivery had worked under an earlier layout; it was not consistently
immune. Session traces corroborated repeated 20-second probe timeouts with
10,044 or 741 draft bytes. Quiet-window debounce already had a 2-second delay
and a 10-second cap; the failure occurred after admission parsing.

The owner subsequently directed automatic mailbox wakeups across OpenCode,
Codex, and Claude Code to stop predicting composer emptiness. The revised
plan uses atomic core send, preserves durable inbox contents, and distinguishes
transport acceptance from recipient read. Startup readiness, first-task
delivery, and owner-approved typing remain separate workflows.

## Real-client QA

QA used an isolated daemon and private sessions under
`/tmp/opencode-delivery-design-qa`; no production install or reload occurred.

| Client | Idle | Detached draft | Active turn |
| --- | --- | --- | --- |
| OpenCode 2.2.5, DeepSeek V4.1 Flash | Replied `QA_IDLE_OK` | Prefix and followup concatenated and submitted | Accepted followup and replied `QA_BUSY_FOLLOWUP` |
| Codex 0.166.0, GPT-6.1-Sol | Replied `QA_IDLE_OK` | Prefix and followup concatenated and submitted | Accepted followup and replied `QA_BUSY_FOLLOWUP` |
| Claude Code 2.1.312 | Input appeared in transcript | Prefix and followup concatenated and submitted | Account hold prevented model-processing verification |

For both active-turn tests, the original `QA_BUSY_DONE` was absent: terminal
followups steered current work. Atomic send is not equivalent to an independent
native message queue. Draft concatenation and turn steering are accepted
consequences of the revised wakeup policy, not guarantees of draft preservation
or uninterrupted task execution.

A private attached `/bin/cat` test exposed another distinction: raw Lua
`remuda.send` returned `nil` successfully and wrote the sentinel while
`attached=true`. An explicit attached-session preflight is therefore required.
Name-addressed SendLine does not atomically fence human attachment or session
replacement between preflight and write. The Butler fix cannot claim that
stronger guarantee. Core write serialization still applies.

## Native alternatives

Installed `opencode --version` reported 2.2.5. Actual help exposes `acp`, `api`,
`serve`, `--standalone`, and `--server`. The
[v2 ACP documentation](https://opencode.ai/v2/docs/cli/acp) describes a private
stdio server with one active prompt. Starting ACP does not attach to an
already running standalone TUI instance and cannot replace busy-turn queueing
by assumption.

The [v2 server plugin documentation](https://opencode.ai/v2/docs/build/plugins/server)
describes native session prompting, queue/steer choices, and retry IDs. A future
same-process plugin or explicitly bound API endpoint could avoid terminal draft
coupling. It must verify the installed schema, exact server/session ownership,
permission behavior, and acknowledgement semantics before adoption. Current
documentation alone does not establish compatibility with the installed
private TUI instance.

The exact upstream `v2.2.5` tag resolves to
`9bbb8ce18c80f099e0e448775f59d965ead40a21`; its
[prompt renderer](https://github.com/anomalyco/opencode/blob/v2.2.5/packages/tui/src/component/prompt/index.tsx)
was located; its full geometry invariants were not verified. Current Remuda styled capture provides
text/dim spans and cursor position, not a composer rectangle or background
colors, so it cannot by itself resolve the historical-border ambiguity.

## Final verification

The frozen candidate passed 54 standalone Lua tests, 8 related isolated
harness checks, and pinned-core `ae9ce95` integration: 74 mailbox tests and
92 daemon tests. The full run used four threads and a process-local open-file
limit of 4096 after the default macOS limit caused `os error 24` failures.
The read-leader-brief regression verifies that uncertainty suppression
survives the stuck report closing, another compaction, and preserved-bus
reseeding. A full daemon restart can still nudge unread mail again.
