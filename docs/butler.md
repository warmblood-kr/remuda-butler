# Butler

Butler is Remuda's local session manager. It starts and coordinates one agent
session through the same Lua runtime and Remuda protocol used by other
extensions. It works without Matrix configuration.

When Matrix credentials are configured, Butler listens in its HOME room, the
shared ALL-BUTLERS room when configured, and every configured joined room. In
HOME, every human message is delivered to that room's Butler. In ALL-BUTLERS,
every top-level human message is delivered to every Butler; thread replies are
delivered only to Butlers subscribed to that thread. A Butler subscribes when
it is mentioned in a thread or posts in the thread. Subscriptions and the event
cursor persist across restarts. Agent messages are delivered only when they
mention the receiving Butler, and Butler never auto-replies to agent-authored
messages. Mail records the Matrix sender, `room` (`home`, `all`, or `joined`),
room ID, event ID, and thread ID.
An allowlisted owner can invite the bot from Element, and it joins the room.

Roster classification uses Matrix MXID localparts: case-insensitive `agent-`
and `butler-` prefixes identify AGENT accounts; configured `butler_senders`
also identify older agent accounts. Every other syntactically valid MXID is a
HUMAN account. Malformed or unrecognized sender IDs are not routed to mail.
The sender allowlist applies before classification. Butler classifies each
event directly from its sender MXID, without a cached roster.

If the saved `.since` state is unreadable or has invalid field types, the relay
starts with a fresh sync baseline. It does not replay room history; messages
sent while the relay was down can be missed, and pending deliveries recorded
only in the damaged state file cannot be recovered.

## Installation and sign-in check

Run `remuda butler doctor` to check whether Claude Code and Codex CLI are on
`PATH` and whether each CLI reports an active login. The check runs
`claude auth status` and `codex login status`; it discards their output and
prints only installed and sign-in states. It does not start an agent session.

When a CLI is missing or signed out, the doctor prints the corresponding next
command. Claude Code uses its shell installer on macOS and Linux and its
PowerShell installer on Windows. Codex CLI can be installed with
`npm install -g @openai/codex`. To sign in, run `claude auth login` or
`codex login`. Once both CLIs are installed and signed in, the doctor points to
`remuda butler matrix setup` for the optional Matrix bridge.

`remuda butler --help` includes the doctor command with the other installed
Butler verbs.

## Matrix commands and configuration

Use `remuda butler matrix` for Matrix reads and writes. Options come before
the verb or its positional arguments. `--json` selects machine-readable
output. Verbs that accept `--room ROOM` require the configured HOME,
ALL-BUTLERS, or a joined room.

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
remuda butler matrix [--json] quarantine [--id EVENT_ID]
```

`remuda butler matrix setup --default` writes the token and config to the
running Butler's resolved paths, then starts or replaces only its Matrix
relay. Accept the invite in Element before sending the Butler a message; setup
ends with `Next: accept the invite in Element; the relay is running, so write to the Butler there.`
when the relay is running. `--dir PATH` writes a separate Butler's files and leaves the running
relay alone. Start that Butler with
`REMUDA_BUTLER_TOKEN=PATH/token REMUDA_BUTLER_CONFIG=PATH/config remuda -s matrix-test daemon`,
replacing `PATH` with the chosen directory.

`event` and `get` are aliases for the same read.
The `remuda butler matrix rooms` command lists configured rooms, saved aliases,
and how each room was added; server-side memberships show in
`remuda butler matrix status`. Use `remuda butler matrix rooms --public [TERM]`
to browse up to 20 public rooms, optionally filtered by a search term.
The config file remains the
single room boundary: an invite from an allowlisted human
owner adds `room=ROOM_ID how=owner-invite`, and operator `join` adds
`room=ROOM_ID how=operator`. Operators can join with a room ID, `#alias:server`,
or a public room name. An alias is saved as a display label on the room line;
it does not grant trust. A public name joins only when exactly one public room
matches; multiple matches are listed for the operator to choose from. Invites from other senders are not joined and are
reported to HOME; joined rooms use the HOME sender rules. The inviter check
relies on the homeserver appending the real invite event to `invite_state`
(Synapse does). `leave` removes a
joined room by ID or alias, while HOME and ALL-BUTLERS cannot be left or removed. The
`send -` stdin form is unsupported until core #213.

`join` and `leave` change room membership and are operator-only. Until core
#218 enforces caller identity, this is best-effort policy: another local
process running as the same user may still invoke those verbs.

`quarantine` lists rejected inbound Matrix message events; add `--id EVENT_ID`
to inspect one. It is operator-only under the same caller policy. The relay
stores at most 200 records, with a body preview capped at 1 KiB and a 30-day
expiry. Quarantined events are never delivered through Butler mail. The relay
state file containing these records is mode 600 on Unix hosts.

Run `remuda butler matrix setup` to configure Butler; with `--register` and no
`--registration-token-file`, setup asks for the homeserver registration token
using a hidden prompt.

```text
remuda butler matrix setup --homeserver https://matrix.example.org --owner @alice:example.org --register --pin <64-hex-sha256> --default
```

The token is stored in a separate token file. The newline-delimited config
file contains:

1. Homeserver URL.
2. The HOME Matrix room ID.
3. The Matrix account's own user ID.
4. A comma-separated allowlist of sender MXIDs. Messages from senders not on
   this list are ignored; a blank line allows no senders.
5. Optional `messages` to use the `/rooms/{room}/messages` polling fallback
   for homeservers affected by a `/sync` defect; blank uses `/sync`. ALL-BUTLERS
   requires `/sync` and is rejected with this fallback enabled.
6. Optional sync timeout in milliseconds; blank defaults to `30000`.
7. Optional transport and room settings, one `key=value` per line:
   `all_room=ROOM_ID` configures the shared ALL-BUTLERS room;
   `ca_file=PATH` trusts a custom CA, and `pin_sha256=HEX` pins the
   homeserver's leaf key. `butler_senders=@id:server,...` remains accepted for
   older accounts that do not use the prefix convention; `agent-` and
   `butler-` MXID prefixes identify agent accounts and prevent
   Butler-to-Butler reply and send loops.

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
ID. It records cursor, processed IDs, pending deliveries, quarantine records,
event-to-mail/thread correlation, and pending/sent replies in the
`<config>.since` state file. After Butler mail accepts an event, its ID is
appended to `<config>.acks`; the relay folds acknowledgements into the state
file and removes completed pending entries. Together with mail's event-ID
deduplication, this provides exactly-once delivery across relay restarts. If
the state file is unreadable or has invalid field types, the relay starts from
a fresh sync baseline; it does not replay room history, and pending deliveries
in the damaged state cannot be recovered.

`remuda butler matrix reply EVENT_ID TEXT` sends a threaded reply. The relay
records the returned event ID against the originating Butler mail. A human
replying in that thread needs no mention: the event-to-mail correlation routes
the follow-up to Butler and sets its mail `in_reply_to` to the original mail.
That correlation survives a relay restart. Butler does not reply to messages
from another configured Butler account.

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

On each fresh agent-session start—first launch, resume, or a relaunch or
respawn after a Butler or daemon restart—Butler checks for unread mail. If any
is unread, it queues one notice with the count, using the normal debounce; it
does not duplicate a notice that is already pending.

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
