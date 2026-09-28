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
defect. The default uses `/sync`. Add `ca_file=/path/to/ca.pem` or
`pin_sha256=<certificate SHA-256 hex>` on a later line for HTTPS homeservers;
HTTPS fails closed when neither option is configured. A certificate pin is
checked immediately after the TLS handshake and before an authenticated request
is sent.

Matrix reads use the authenticated `remuda butler matrix` commands:

- `status` shows the account, joined rooms, and saved sync cursors.
- `history [--room ROOM] [-n N]` reads recent events from the configured room.
- `rooms` lists joined rooms without changing membership.
- `thread ROOM EVENT_ID` reads a thread; `event` and `get` fetch one event.
- `download MXC [-o PATH]` downloads an `mxc://` attachment.

Add `--json` for machine-readable output. Room-scoped reads use the configured
room allowlist. Media downloads use the authenticated v1 endpoint and fall back
to the legacy v3 endpoint when the homeserver reports it is unsupported.

Butler topics use stable session names and are delivered through the Butler
message queue. The extraction boundary, runtime dependencies, and migration
plan are maintained in the repository's
[`BUTLER_MIGRATION.md`](https://github.com/warmblood-kr/remuda-butler/blob/main/BUTLER_MIGRATION.md).
