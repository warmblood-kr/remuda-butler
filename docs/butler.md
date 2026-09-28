# Butler

Butler is Remuda's local session manager. It starts and coordinates one agent
session through the same Lua runtime and Remuda protocol used by other
extensions. It works without Matrix configuration.

When Matrix credentials are configured, Butler reads one allowed room and
stores inbound text as Butler mail, including the Matrix sender, room, event
ID, and UTC timestamp. The relay persists its sync cursor and processed event
IDs beside its config so it can resume after a restart. Without Matrix config,
it starts no Matrix relay.

If the saved `.since` state is unreadable or has invalid field types, the relay
starts with a fresh sync baseline. It does not replay room history; messages
sent while the relay was down can be missed, and pending deliveries recorded
only in the damaged state file cannot be recovered.

The Matrix config is a newline-delimited file: homeserver URL, room ID, the
Matrix account's own user ID, and a comma-separated sender allowlist. An
optional fifth line set to `messages` enables the `/rooms/{room}/messages`
polling fallback for account/room pairs affected by the homeserver `/sync`
defect. The default uses `/sync`.

Butler topics use stable session names and are delivered through the Butler
message queue. The extraction boundary, runtime dependencies, and migration
plan are maintained in the repository's
[`BUTLER_MIGRATION.md`](https://github.com/warmblood-kr/remuda-butler/blob/main/BUTLER_MIGRATION.md).

At startup, Butler tries registered agent kinds in order and waits for each
agent's idle prompt before selecting it. The default order is Claude, then
Codex; set `REMUDA_BUTLER_AGENT_ORDER=codex,claude` to change it. This order
also applies to delegates without an explicit kind. Each candidate waits up to
15 seconds by default; set `REMUDA_BUTLER_READINESS_TIMEOUT` to change that
per-candidate timeout. `remuda butler sessions` shows the selected kind and
the reason each earlier candidate was skipped.

`remuda butler status` prints `butler: up (<kind>)` and exits 0 when the root
Butler is ready. During launch it exits 75 and writes `launching` plus one
the effective `readiness budget: N` and one line per attempted candidate to
standard error. The budget covers the configured candidate chain plus a
cleanup margin. After failure it exits 1 and
writes `failed` plus each candidate's reason to standard error. Older Remuda
cores without `remuda.fail` report these states as ordinary command errors.
The install script polls status every half second until the reported budget
expires, continues while status is 75, and stops on ready or failure. Bare
`remuda exec butler` remains asynchronous; use `remuda butler status` to
inspect readiness.
