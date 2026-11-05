# All-three native delivery companion (stacked on PR #563)

2026-11-05. `feat/all3-native-companion` adds Codex owner adoption and an
opted-in Claude channel to the OpenCode-only companion. Default off per kind;
no PTY downgrade for a bound session.

## Fixed helper map

One closed, internal kind→verb map — no caller text becomes a command:

| kind | notice | adopt/channel |
| --- | --- | --- |
| opencode | `_agent_notice` | wrapper launch |
| codex | `_codex_notice` | `_codex_adopt` |
| claude | `_claude_notice` | `_claude_channel` |

Every notice keeps the frozen Request1 (`version,binding,nonce,session,
instance,request_id,text,message_ids`). Endpoint, socket, thread and auth never
appear in notice argv, status, journal or roster. `_agent_notice` is never used
for Codex/Claude; common-entrypoint unification is future work.

## Config

`native.json` root `{version:1, opencode:{enabled}, codex:{enabled},
claude:{enabled}}`; each section independent and default off. Unknown root or
section keys and non-boolean values never enable. Missing section is
`config_missing_section`.

## Codex adoption

Owner copies socket and canonical lowercase UUID from a fresh `/status`:
`remuda butler native adopt-codex ALIAS --socket PATH --thread UUID`.
Only `unix://` is normalized, to an absolute local path; remote schemes,
queries, fragments and control bytes are refused. Butler prepares the 0700
binding dir/nonce, freezes the six-field adopt request, fences `row.id` plus
the opaque instance before and after the helper yield, and persists only
path, nonce, session, kind and generation. `adopted` remains provisional until
the post-yield row check; `unavailable`/`uncertain` attach no binding.

Codex new launch is `owner_adopt_only`; the core tunnel owns any future launch
binding. Never kill an adopted server or the shared per-uid daemon dir.

## Claude channel

Explicit `claude.enabled` adds a second `remuda-channel` MCP entry to the
member's private 0600 config plus
`--dangerously-load-development-channels server:remuda-channel`. The channel
consent prompt stays for the human; nothing auto-answers it. The ordinary
`remuda` entry and argv are unchanged. Unopted Claude stays PTY/unavailable.
The channel publishes `claude-channel-v1` only after `mcp_initialized`; an ACK
is never `accepted_queue`, and possible emission is `uncertain
(channel_emitted_unconfirmed)`.

## Immediate native timing

Native selection happens before `pending_tasks`/typing gates. A native arrival
dispatches in the same notify call with zero quiet/cap timers and zero screen
reads, including attached, busy, non-empty draft, pending first task and
re-show. An arrival queued during a helper/journal yield is drained as soon as
the guard releases. Recovery/remind/seed bypass PTY gates. A proven pre-write
retry keeps its bounded backoff; unknown never retries.

## Per-dispatch claim

`request_id` is `msg_` + 16 CSPRNG bytes from `remuda.random_bytes`, generated
in the attempt snapshot before the first yield and the journal reservation and
reused unchanged for that one helper call. It is not derived from mail IDs or
the clock, so same-second legitimate claims (re-show/re-prune) differ. Without
the entropy seam the attempt is a pre-write refusal; no fallback hash is made.
Suppression stays keyed by recipient + mail IDs.

## First task and startup publication

A native first task is always written to durable Butler mail; only the ordinary
canonical pointer reaches the helper. No arbitrary task text, composer or
Return. A failed mail write is reported to the leader, never typed instead.

A fresh launch may race manifest/MCP publication. `binding_missing` parks only
a just-launched binding, inside a bounded window (120s OpenCode/Codex, 30min
for a human-answered Claude channel), with no attempt spend, no timer, no
disable and no PTY. The first non-`binding_missing` answer ends the window and
flushes queued unreserved mail. A missing manifest on an adopted or reloaded
binding is dead: a formerly-published binding never becomes indefinite startup
waiting. Corrupt/wrong identity stays distinct from genuinely absent.

## Status

`remuda butler sessions` gains a read-only `NATIVE` section (alias, kind,
state, reason, generation prefix). No path, nonce, socket, thread or token.

## Limits

Codex adoption is proven against core 0.166 helpers; no Butler-owned live row
was used in unit tests. Claude `_claude_notice`/`_claude_channel` are not
installed in the pinned product binary yet; the builder entry is tested as
config/argv only. Full owned new/chooser/main-boot startup-race smoke remains
QA-owned. No merge, install, reload or rollout.
