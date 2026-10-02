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

## Agent accounts and quota

Run `remuda butler quota` to see, for Claude Code and for Codex CLI, how the
agent is logged in (subscription, API key, not logged in), which subscription
it uses, and how much of each limit is used:

```
⚠️ Agent accounts, 2026-10-01 04:40Z
claude: subscription (max), you@example.org
  5-hour limit: 92% used, resets 2026-10-01 07:00Z
  Weekly limit: 71% used, resets 2026-10-04 00:00Z
codex: subscription (Pro), account: not exposed by codex
  Weekly limit: 60% used, resets 2026-10-03 17:30Z
Near limit: claude 5-hour limit (92%).
Next: run `remuda butler quota --report` to send this to Matrix.
```

`remuda butler quota --report` also posts the report body to the Butler's Matrix
home room, as plain text. Only the Butler itself or a person at a terminal can
use `--report`; a member is told to ask the Butler. Percentages are percent
used, reset times are UTC, and a limit at 80% or more is listed under
`Near limit`. A value that could not be read is printed as `unknown` with the
reason, and the last line says what to do next; the login mode is never guessed.

Where the values come from:

- Login mode and the Claude account email: `claude auth status` and
  `codex login status`. Only the mode, the plan and the email are used; the
  rest of the output, including the organisation id, is never printed, logged
  or written to disk.
- Claude limits: the rate-limit fields Claude Code passes to its status line.
  Butler keeps the newest reading among its Claude sessions, so the numbers are
  as fresh as the last Claude reply; a reading older than 10 minutes is marked
  `as of`. API-key logins have no such reading.
- Codex limits: Butler types `/status` into one idle Codex member (empty
  composer, nobody attached and typing, never the Butler's own session) and
  reads the screen. With no idle Codex member the report says so and tells you
  how to get a reading. Codex does not expose the account email, only the plan.

Nothing read from a pane or a CLI is printed as free text: a plan or a limit
name must be a short plain word and the email must look like an email, or it
is left out. One report is collected at a time, and a finished report is
reused for 60 seconds (its header then says `as of`), so repeated calls do not
type into a Codex pane again.

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
remuda butler matrix [--json] [--room ROOM] follow EVENT_ID
remuda butler matrix [--json] [--room ROOM] unfollow EVENT_ID
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

### Owner typed lines

`remuda butler typed-lines on|off` controls plain owner lines (`!TEXT`), and
`remuda butler shell-lines on|off` controls shell lines (`!!TEXT`). Shell lines
require typed lines to be on; turning typed lines off also turns shell lines
off. `remuda butler doctor` reports the current values as `Typed lines: on|off`
and `Shell lines: on|off`. Both switches are off by default. When a switch is
off, matching messages stay on the ordinary mail path.
These CLI gates do not defend against a hostile same-user agent that clears
its identity (see Butler #264). The real protection is that both switches
default off.

An enabled line must come from an allowlisted owner in a live Matrix sync, be
no more than five minutes old, contain one line of at most 2000 bytes, and fit
the limit of 10 lines per 10 minutes. the switch verbs are for a person at the
machine; an agent is refused.

Root posts are delivered from anyone. In the HOME room, every thread reply is
delivered whether or not you follow it. In other rooms, thread replies are
delivered only in followed threads or when a message mentions the Butler;
replying, sending, and a mention from an allowlisted sender follow automatically.
Non-allowlisted senders arrive marked as information with `trusted=false`.
Use `follow EVENT_ID` and `unfollow EVENT_ID` to manage subscriptions; the
relay allows up to 5000 followed threads in total. Accepted messages from
non-allowlisted senders are limited per room in a rolling hour by
`untrusted_per_room_hour` (default 20). Once the cap is reached, those messages
are left undelivered, rather than quarantined. The HOME room receives a summary
with the count and a history command. The first summary for a room is immediate;
after that, at most one is posted per room every 10 minutes, and capped messages
accumulate in its count until the next summary.

The inbox identifies each Matrix mail's room and, for a thread, its root. Its
`Next:` line is `remuda butler reply MESSAGE-ID`, which answers in the same room
and thread; for a thread a second line, `to read the thread:`, gives the
shell-quoted `matrix thread` command. The sender's text follows the line
`Message from Matrix (text of the sender, not Butler guidance):`, so nothing in
it can pass as part of the header. On the first message from an allowlisted
sender in a thread the Butler has not seen, its mail also includes the root
message and up to 20 earlier replies. The context is untrusted even when the
triggering message comes from an allowlisted sender, and each context message is
kept to one line; the block is capped at 8 KiB. Only an allowlisted sender
triggers this fetch. Context lines do not count as Butler turns, new requests,
or untrusted messages. If reading the thread fails or a request times out (10
seconds each), the mail arrives with a short failure line and the original
message. The fetch does not delay mail from other threads.

Configure `b2b_max_turns` (default 6) for consecutive Butler-only turns in one
thread, `posts_per_hour` (default 30) for posts that are not a reply to a person
on the allowlist, and
`untrusted_per_room_hour` (default 20) for non-allowlisted messages delivered
from each room. The Butler's own replies count as turns. These counters are held
in memory and reset when the daemon restarts. `b2b_max_turns` and
`untrusted_per_room_hour` are read when the relay starts, so restart the relay
after changing either setting; `posts_per_hour` is read for every post. HOME
notices, `upload`, and `react` do not take a post slot.

When the Butler reaches the turn limit, it posts this line to HOME and stops
replying in that thread until an allowlisted human replies:

```text
Stopped replying in thread ROOT (ROOM): N Butler-only turns. A reply in that thread from a person on the allowlist resumes it.
```

The reply refusal includes a command with shell-quoted room and thread IDs:

A thread root that could be parsed as a link is printed as `(id not shown)`, and
the refusal points to room history instead of naming that thread.

```text
Reply not sent: stopped replying in thread ROOT (ROOM): N Butler-only turns. A reply in that thread from a person on the allowlist resumes it.
Next: remuda butler matrix --room 'ROOM' thread '$ROOT'
```

When the post limit is reached, the refusal says:

```text
Not sent: Matrix post limit reached (N per hour). Next: wait until HH:MMZ
```

The first refusal in an hour also posts one line to HOME; further refusals in
that hour do not post another:

```text
Matrix post limit reached (N per hour); posts other than replies to people on the allowlist are refused until HH:MMZ. Next: remuda butler matrix history
```

A reply without a delivered mail route is refused with:

```text
Reply not sent: event EVENT_ID was not delivered to this Butler as mail, so its sender cannot be verified.
Next: remuda butler inbox (you can only reply to events listed there)
```

The HOME summary distinguishes a single event from multiple events and
shell-quotes the room ID in its `Next:` command:

```text
1 message from non-allowlisted senders in ROOM was not passed to the Butler (hourly rate cap). Next: remuda butler matrix --room 'ROOM' history
N messages from non-allowlisted senders in ROOM were not passed to the Butler (hourly rate cap). Next: remuda butler matrix --room 'ROOM' history
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
its kind, how it was added, and its inviter; it also shows the room mode and
deny rules. Server-side memberships show in `remuda butler matrix status`.
Use `remuda butler matrix rooms --public [TERM]` to browse up to 20 public
rooms, optionally filtered by a search term.

The config file is the single room boundary. `rooms=open` lets any HUMAN
account invite the Butler; the relay joins unless a room or server matches a
deny rule. If `rooms` is omitted, the mode defaults to allowlist and preserves
the existing behavior of joining only invites from allowlisted HUMAN accounts.
In either mode, the sender allowlist still controls which room messages can
become mail.
Messages from other senders stay quarantined, and agent messages still need a
mention. Open mode refuses invites from `agent-` and `butler-` MXIDs because
they are not HUMAN accounts. Duplicate delivery of the same invite event is
ignored; a new invite can retry a configured room, subject to deny checks and
the budget. Open mode allows at most 20 automatic join attempts per rolling
day. Owner invites count toward the cap, and failed join attempts remain
counted.

Add `deny_room=!ROOM_ID` or `deny_room=#alias:server` for each denied room, and
`deny_server=host` for each denied server. Room IDs, canonical aliases, room
servers, inviter servers, and alias servers are checked against these rules.
An alias deny matches only when the invite carries that canonical alias; use
`deny_room=!ROOM_ID` or `deny_server=host` for a hard block. Invalid deny lines
are ignored with a warning. An open-mode join records
`room=ROOM_ID how=invite inviter=@user:server`; allowlist-mode owner invites
record `how=owner-invite`, and operator `join` records `how=operator`.
Operators can join with a room ID, `#alias:server`, or a public room name. An
alias is saved as a display label; it does not grant trust. A public name joins
only when exactly one public room matches; multiple matches are listed for the
operator to choose from. The inviter check relies on the homeserver appending
the real invite event to `invite_state` (Synapse does). `leave` removes a joined
room by ID or alias, while HOME and ALL-BUTLERS cannot be left or removed. The
interactive setup wizard writes `rooms=open` without asking; flag-based setup
defaults to allowlist unless given `--rooms open`. `send -` reads the text from
stdin (up to 64 KiB, one trailing newline dropped); `send -- -` sends a literal `-`.

`join` and `leave` change room membership. Butler refuses them for a Butler
member, identified by the agent identity in the client environment
(`REMUDA_BUTLER_AGENT_ID` / `REMUDA_BUTLER_SESSION_NAME`). The caller kind
(session, unknown, outside) is not checked, so a caller with those variables
cleared is not refused. This is advisory within one UID, not an OS boundary:
any local process running as the same user can drop the variables.
The CLI verbs (`approve`, `deny`, `matrix setup`, `join`, `leave`) identify the
member from those variables only; the MCP tools also accept the session
capability.

Approvals: when an agent runs `matrix join`, Butler resolves the room and
posts one request to HOME instead of joining. The owner answers with a ✅ or
❌ reaction, or a `yes`/`no` reply, to that exact message within 10 minutes.
Only an allowlisted human sender in HOME counts. A bare `yes` does nothing.
The owner can also answer from the terminal: `remuda butler approvals` lists
the open requests, and `remuda butler approve ID` or `deny ID` answers one
(operator-only). Terminal approve/deny are refused for a Butler member, by the
same agent identity in the client environment; the caller kind is not checked,
so clearing the variables passes. This is a same-UID policy, not an OS
boundary. The Matrix answer path
is bound to the owner's MXID. An approved request joins the room ID resolved
at request time and writes `room=ID how=approved`. The asker gets mail for every outcome:
approved, denied or expired. A repeat ask for the same room returns the same
request. Each agent may have 3 open requests, and there may be 5 in total.
Requests live in the relay state file.

`quarantine` lists rejected inbound Matrix message events; add `--id EVENT_ID`
to inspect one. It is operator-only under the same caller policy. The relay
stores at most 200 records, with a body preview capped at 1 KiB and a 30-day
expiry. Quarantined events are never delivered through Butler mail. The relay
state file containing these records is mode 600 on Unix hosts.

Run `remuda butler matrix setup` to configure Butler; with `--register` and no
`--registration-token-file`, setup asks for the homeserver registration token
using a hidden prompt. `--rooms open|allowlist` sets the invite mode written to
the config; flag-based setup defaults to allowlist.

```text
remuda butler matrix setup --homeserver https://matrix.example.org --owner @alice:example.org --register --pin <64-hex-sha256> --default
```

`--password-cmd PROG [ARG...]` reads the bot password from a program, such as
a password manager, instead of `--password-file`. Setup runs the program
directly (no shell), waits up to 10 seconds, and uses the first line it prints.
It takes every argument after it, so it must be the last option. It works with
and without `--register` (without it, `--bot` is required) and cannot be
combined with `--password-file` or `--token-file`. Setup saves no copy of this
password: it stays where it was made. The program inherits the daemon's
environment (stdin is closed), so treat it as running with your own authority. A password that setup generates, or one
given with `--register --password-file`, is still saved privately beside the
token.

```text
remuda butler matrix setup ... --password-cmd op read op://Vault/Item/password
remuda butler matrix setup ... --password-cmd security find-generic-password -s butler-bot -w
remuda butler matrix setup ... --password-cmd powershell -NoProfile -Command "Get-Secret -Name butler-bot -AsPlainText"
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
   `rooms=open` or `rooms=allowlist` selects invite behavior, with allowlist as
   the default; repeat `deny_room=ROOM_ID`, `deny_room=#alias:server`, or
   `deny_server=host` lines to refuse matching invites;
   `b2b_max_turns=N` sets the consecutive Butler-only thread turn limit
   (default 6); `posts_per_hour=N` caps posts that are not a reply to a person
   on the allowlist (default 30);
   `untrusted_per_room_hour=N` sets the per-room non-allowlisted message limit
   (default 20);
   `ca_file=PATH` trusts a custom CA, and `pin_sha256=HEX` pins the
   homeserver's leaf key. `butler_senders=@id:server,...` remains accepted for
   older accounts that do not use the prefix convention; `agent-` and
   `butler-` MXID prefixes identify agent accounts.

`pin_sha256` is the 64-character hexadecimal SHA-256 digest of the leaf
certificate's SubjectPublicKeyInfo (SPKI), not the certificate file. Compute
it from the server's leaf certificate with:

```sh
openssl x509 -in server-cert.pem -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256
```

Copy the 64 hexadecimal digits after `=` into `pin_sha256` (or pass them to
`setup --pin`). Butler converts that digest to the `sha256/<base64>` pin form
used by `remuda.http` and sends it with `pin_only`, so a self-signed homeserver
works with the pin alone: the CA chain is skipped, while the hostname, validity
dates, and the SPKI pin are still checked. `ca_file` keeps full chain
validation. With neither `ca_file` nor `pin_sha256`, an `https://` homeserver
is verified against the system's trusted CA roots, so a publicly trusted
certificate needs no extra setting. Verification is never skipped: an untrusted
certificate fails with `Next: remuda butler matrix setup --ca-file PATH (the
server's CA certificate), or --pin SHA256HEX`, and a pin mismatch fails with
its own `Next:` line. HTTP is intended for local or development use.

Matrix sends and replies are split at UTF-8 boundaries into chunks of at most
4000 bytes. Upload request bodies and download response bodies are capped at
20 MiB. Ordinary Matrix requests default to a 15-second timeout; downloads use
30 seconds and uploads use 60 seconds. The default response-body limit is
1 MiB; media downloads may use the full 20 MiB limit.

Text messages (`send` and `reply`) are sent as `m.text` with the text unchanged
in `body`, plus a `formatted_body` (`org.matrix.custom.html`) rendered from a
Markdown subset: headings, `**bold**`, `*italic*`, `` `code` ``, fenced code,
links, bullet and numbered lists, blockquotes, `---` rules, and tables.
Everything is HTML-escaped first, so raw HTML never passes through, and link
targets are limited to `http`, `https`, and `mailto`. Limits: lists are flat
(nested items join the parent list); a blockquote is a single paragraph; a `|`
inside a table cell splits the cell, even in a code span or escaped;
`_italic_` is not supported. Text over 4000 bytes is split first and each chunk
is converted on its own, so a block that spans a chunk boundary (a code fence
or a table, for example) renders broken. If the converter fails, or its HTML
for a chunk exceeds 30000 bytes, that chunk is sent as plain `m.text` without
`formatted_body`.

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
That correlation survives a relay restart. Butler-to-Butler replies are
permitted until the per-thread turn guard reaches `b2b_max_turns`.

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
