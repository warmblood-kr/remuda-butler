# Same-running-session delivery: support and limits

Verified 2026-11-05 before implementation: Claude Code2.1.317, Codex CLI0.166.0, OpenCode2.2.5. A shared transcript/session ID alone does not prove the same running engine. New SDK processes, ACP subprocesses and resumed engines must be labelled separately. No production session was used in these probes.

## Claude Code

[Channels](https://code.claude.com/docs/en/channels) and [reference](https://code.claude.com/docs/en/channels-reference) support opted-in same-TUI MCP events. Actual2.1.317/fakechat0.0.1 rendered ONE inbound in original PID92691, using auth in place and isolated plugin cache/child HOME. Account hold blocked model reply/receipt. Unopted TUI late adoption is unestablished. [Runtime evidence](../evidence/2026-11-05/native-delivery/claude-fakechat-runtime.md) records isolation failures and runtime-write/updater limits.

## Codex

[CLI reference](https://learn.chatgpt.com/docs/cli/reference) documents `queue --thread UUID --message TEXT`; explicit `--remote` selects the server. [App server](https://learn.chatgpt.com/docs/app-server) supports native queue/turn protocols and TUI connections. Never use `--resume` during delivery: queue success and resumed execution are distinct. Exact implementation: [0.166 queue](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/session_queue_commands.rs).

Disposable real Codex server + original TUI, exact endpoint/UUID shown by `/status`: idle and busy-turn queue consumed; unsubmitted synthetic draft preserved. Original busy turn completed before followup. Enqueue occurred while turn active, not proven during the running shell command.

Critical negative result: repeating one clientUserMessageId admitted THREE queue items and THREE completed turns, including two identical payloads. It is correlation, not idempotency. Timeout/ACK loss must not trigger retry or PTY fallback.

Blank pre-created thread bootstrap failed `no rollout found`, one failed path. Later passive observation proved original TUI creates root before model input, but source/originator reflected the observer, not creator. Ephemeral title threads also appear. Fresh `/status` on an ALREADY running unbound TUI proved socket+UUID; ONE queue consumed in unchanged PID91522 with exact draft. Separate /new and resumed-A checks: [adoption evidence](../evidence/2026-11-05/native-delivery/codex-existing-adoption.md). `/status` injected into a draft appends literal text: arbitrary live acquisition is unsafe. Current inherited PTY has no safe sole-input/ready boundary, so status-only product acquisition is withdrawn. An owning-connection response tunnel is under probe design. Freeze initial A across UI changes.

## OpenCode

Use [v2 server/plugin docs](https://opencode.ai/v2/docs/build/plugins/server), not v1 routes. [ACP](https://opencode.ai/v2/docs/cli/acp) creates a separate private server. Pinned v2.2.5 [schema](https://github.com/anomalyco/opencode/blob/v2.2.5/packages/protocol/openapi.json), [connection/auth](https://github.com/anomalyco/opencode/blob/v2.2.5/packages/cli/src/services/server-connection.ts), [inbox reconciliation](https://github.com/anomalyco/opencode/blob/v2.2.5/packages/core/src/session/inbox.ts).

Actual OpenCode server/TUI with an isolated local mock MODEL provider passed authenticated admission, idle consumption/rendering, busy queue draining, exact idle/busy draft preservation and fixed A delivery after UI moved to B (A1/B0). Mock-provider evidence is not real-provider/tool/permission-pause coverage.

POST `/api/session/ID/prompt` with `delivery:queue` admits fixed-target input. Default/true `resume` schedules the EXISTING loop; false leaves pending without waking it. This flag is not permission to create/reacquire a session. Preverify target existence: CLI --session can create a missing ID.

The same immutable message ID retained one item before/after consumption, lost-response replay and orderly server restart. Different body/same ID keeps first content; wrong-session ID reuse returned409. Bind IDs to frozen bodies. This observed behavior is NOT generalized to Codex, crash recovery or exactly-once processing. Wave1 still forbids automatic lost-ACK replay.

## Common policy

Launch-owned fixed task target is distinct from current UI selection; never guess retargeting. Attachment, busy state and composer contents are not automatic admission gates. Bound native sessions never fall back to a possibly different PTY conversation. Unbound legacy sessions retain one atomic PTY send. Keep durable inbox authoritative; admission, consumption, rendering and inbox read are separate facts. Durable uncertainty survives inbox read, compaction and restart; no automatic replay. New-wrapper independent tests passed idle/busy drafts, fixedA/UIB A1/B0 with zeroPTY, refusal and cleanup. Limits: pre-watcher spawn death gap, same-UID races, Windows unsupported.
