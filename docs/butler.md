# Butler

Butler is Remuda's local session manager. It starts and coordinates one agent
session through the same Lua runtime and Remuda protocol used by other
extensions. It works without Matrix configuration.

When Matrix credentials are configured, Butler connects to one configured
room. It stores inbound text as Butler mail, including the Matrix sender,
room, event ID, and UTC timestamp. Without Matrix config, it starts no Matrix
relay.

If the saved `.since` state is unreadable or has invalid field types, the relay
starts with a fresh sync baseline. It does not replay room history; messages
sent while the relay was down can be missed, and pending deliveries recorded
only in the damaged state file cannot be recovered.

## Matrix commands and configuration

Use `remuda butler matrix` for Matrix reads and writes. Options come before
the verb or its positional arguments. `--json` selects machine-readable
output. Read verbs accept `--room ROOM` where applicable; it must name the
single room in the config file.

```text
remuda butler matrix [--json] status
remuda butler matrix [--json] rooms
remuda butler matrix [--json] [--room ROOM] [-n N] history
remuda butler matrix [--json] [--room ROOM] thread EVENT_ID
remuda butler matrix [--json] [--room ROOM] event|get EVENT_ID
remuda butler matrix [--json] [-o PATH] download MXC
remuda butler matrix [--json] [--room ROOM] send TEXT
remuda butler matrix [--json] [--room ROOM] reply EVENT_ID TEXT
remuda butler matrix [--json] [--room ROOM] react EVENT_ID KEY
remuda butler matrix [--json] [--room ROOM] upload PATH
remuda butler matrix [--json] [--room ROOM] redact EVENT_ID [--reason TEXT]
remuda butler matrix [--json] join ROOM
remuda butler matrix [--json] leave ROOM
```

`event` and `get` are aliases for the same read. `rooms` is read-only. The
configured room is the security boundary: no verb adds a room to it or widens
the allowlist. Change the config explicitly to use a different room. The
`send -` stdin form is unsupported until core #213.

`join` and `leave` change room membership and are operator-only. Until core
#218 enforces caller identity, this is best-effort policy: another local
process running as the same user may still invoke those verbs.

The token is stored in a separate token file. The newline-delimited config
file contains:

1. Homeserver URL.
2. The single configured Matrix room ID.
3. The Matrix account's own user ID.
4. A comma-separated allowlist of sender MXIDs. Messages from senders not on
   this list are ignored; a blank line allows no senders.
5. Optional `messages` to use the `/rooms/{room}/messages` polling fallback
   for homeservers affected by a `/sync` defect; blank uses `/sync`.
6. Optional sync timeout in milliseconds; blank defaults to `30000`.
7. Optional transport settings, one `key=value` per line: `ca_file=PATH`
   trusts a custom CA, and `pin_sha256=HEX` pins the homeserver's leaf key.

`pin_sha256` is the 64-character hexadecimal SHA-256 digest of the leaf
certificate's SubjectPublicKeyInfo (SPKI), not the certificate file. Compute
it from the server's leaf certificate with:

```sh
openssl x509 -in server-cert.pem -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256
```

Copy the 64 hexadecimal digits after `=` into `pin_sha256`. Butler converts
that digest to the `sha256/<base64>` pin form used by `remuda.http`. HTTPS
fails closed unless `ca_file` or a valid `pin_sha256` is configured; HTTP is
intended for local or development use.

Matrix sends and replies are split at UTF-8 boundaries into chunks of at most
4000 bytes. Upload request bodies and download response bodies are capped at
20 MiB. Ordinary Matrix requests default to a 15-second timeout; downloads use
30 seconds and uploads use 60 seconds. The default response-body limit is
1 MiB; media downloads may use the full 20 MiB limit.

The relay resumes from its saved sync cursor and deduplicates by Matrix event
ID. It records cursor, processed IDs, and pending deliveries in the
`<config>.since` state file. After Butler mail accepts an event, its ID is
appended to `<config>.acks`; the relay folds acknowledgements into the state
file and removes completed pending entries. Together with mail's event-ID
deduplication, this provides exactly-once delivery across relay restarts. If
the state file is unreadable or has invalid field types, the relay starts from
a fresh sync baseline; it does not replay room history, and pending deliveries
in the damaged state cannot be recovered.

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
