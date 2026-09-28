# Butler

Butler is Remuda's local session manager. It starts and coordinates one agent
session through the same Lua runtime and Remuda protocol used by other
extensions. It works without Matrix configuration.

When Matrix credentials are configured, Butler reads one allowed room and
stores inbound text as Butler mail, including the Matrix sender, room, event
ID, and UTC timestamp. The relay persists its sync cursor and processed event
IDs beside its config so it can resume after a restart. Without Matrix config,
it starts no Matrix relay.

The Matrix config is a newline-delimited file: homeserver URL, room ID, the
Matrix account's own user ID, and a comma-separated sender allowlist. An
optional fifth line set to `messages` enables the `/rooms/{room}/messages`
polling fallback for account/room pairs affected by the homeserver `/sync`
defect. The default uses `/sync`.

Butler topics use stable session names and are delivered through the Butler
message queue. The extraction boundary, runtime dependencies, and migration
plan are maintained in the repository's
[`BUTLER_MIGRATION.md`](https://github.com/warmblood-kr/remuda-butler/blob/main/BUTLER_MIGRATION.md).
