# All-three native delivery companion (stacked on PR #563)

2026-11-05. `feat/all3-native-companion` adds Codex owner adoption and an
opted-in Claude channel to the OpenCode-only companion. Default off per kind;
no PTY downgrade for a bound session.

## Fixed helper map

Closed internal kind→verb map; no caller text becomes a command.

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
claude:{enabled}}`; each section independent and default off. Unknown keys or
non-booleans never enable; a missing section is `config_missing_section`.

## Codex adoption

Owner copies socket and canonical lowercase UUID from a fresh `/status`:
`remuda butler native adopt-codex ALIAS --socket PATH --thread UUID`.
Only `unix://` is normalized to an absolute local path; remote schemes,
queries, fragments and control bytes are refused. Butler prepares the 0700
binding dir/nonce, freezes the six-field adopt request, fences `row.id` and the
opaque instance before/after the helper yield, and persists only path, nonce,
session, kind and generation. `adopted` remains provisional until
the post-yield row check; `unavailable`/`uncertain` attach no binding.

Codex new launch is gated by `codex.enabled` plus the additive
`_codex_tui --binding` help capability; old/off argv is unchanged and the
launcher publishes after its owning-request capture. The child env is only
`REMUDA_BUTLER_BINDING_NONCE`; core `4f6993dd` reads the core-assigned
`REMUDA_SESSION_ID` (actual `row.id`), never an invented alias, and rejects a
missing/invalid nonce with `binding_env`. Explicit owner adoption remains.
Never kill an adopted server or the shared per-uid daemon dir.

## Claude channel

Explicit `claude.enabled` adds a second `remuda-channel` MCP entry
(`args:["_claude_channel"]`, env binding dir, nonce, alias session) to the
private 0600 config plus
`--dangerously-load-development-channels server:remuda-channel`. Consent stays
human; the ordinary entry/argv are unchanged and unopted Claude stays
PTY/unavailable. The channel publishes `<dir>/channel.json` (`claude-channel-v1`) only after
`mcp_initialized`; an ACK is never `accepted_queue`, and possible emission is
`uncertain(channel_emitted_unconfirmed)`.

## Immediate native timing

Native selection happens before `pending_tasks`/typing gates. A native arrival
dispatches in the same notify call with no quiet/cap timers and no screen
reads, including attached, busy, draft, pending first task and re-show. An
arrival queued during a helper yield is drained when the guard releases.
Recovery/remind/seed bypass PTY gates. A proven pre-write retry keeps bounded
backoff; unknown never retries.

## Per-dispatch claim

`request_id` is `msg_` + 16 CSPRNG bytes from `remuda.random_bytes`, generated
in the attempt snapshot before the first yield and journal reservation, and
reused unchanged for that one helper call. It is not derived from mail IDs or
the clock, so same-second legitimate claims differ. Without the entropy seam
the attempt is a pre-write refusal; no fallback hash. Suppression stays keyed
by recipient + mail IDs.

## First task and startup publication

A native first task is always written to durable Butler mail; only the
canonical pointer reaches the helper. No arbitrary task text, composer or
Return. This includes a sticky disabled binding (failed row identity): the full
body goes to mail and is never typed. A failed write is reported to the leader,
never typed instead.

A fresh launch races manifest/MCP publication. Only the core's typed
`binding_missing` parks, and only a just-launched binding, inside a bounded
window (120s OpenCode/Codex, 30min for a human-answered Claude channel), with
no attempt spend, timer, disable or PTY. A generic `invalid_binding`, wrong
parent/owner or malformed manifest is dead and disables. The first
non-`binding_missing` answer ends it. A missing manifest on an adopted
or reloaded binding is dead.

Launch completion and adoption call
`remuda._butler_notice.native_publication(alias)`. After a typed
`binding_missing`, a <=50ms presence watcher (core metadata; only exact
`not_found` is absent) flushes queued mail; the first attempt is always
immediate. No core push event exists, so a later publication outside a
Butler-visible step is detection latency, not an event guarantee.

## Limits

Codex adoption uses 0.166 helpers; live-row coverage and launch smoke are QA's.
Claude helpers are not in the pinned binary yet. No merge, install, reload or
rollout.
