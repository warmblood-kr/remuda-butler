# Butler

## Caller identity

CLI members are resolved from the daemon supplied caller kind and session name,
matched to exactly one live Butler registration. Missing, unknown, unregistered
or ambiguous caller context fails closed for identity sensitive commands, with
a `Next:` instruction. Older cores without caller attribution therefore cannot
use those commands until upgraded. A caller classified as `outside` maps to the
operator under the named transitional policy `outside_is_operator_transitional`;
that mapping is written to `guard-audit.jsonl` as a `caller_policy` event, even
when guard observation is off. If the audit write fails, the caller is refused.
Guard hooks resolve the caller before writing audit or approval state. Registered
members and the audited outside operator may use them; service and unresolved
callers are refused. Hook requester details come from that resolved principal.
Status callbacks also refuse unresolved callers before writing telemetry.
This is **not an isolation boundary: advisory daemon
attribution within the cooperative model**.

MCP tools keep their existing session-capability fallback on cores without tool
caller fields; environment variables do not select a member. File access still
requires native caller context. Detached processes may be classified as outside,
which is another reason this transitional policy is not an isolation boundary.

Rollback keeps strict caller handling and native ancestry attribution; unknown
callers stay refused. It does not restore a mutable identity fallback.

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

## Folder trust and what it implies

Butler answers the folder-trust dialog (Claude Code's and Codex's) for sessions
it launched in a directory under `project_home`, or in a strict linked git
worktree of a repo under it. So any untrusted repo cloned under `project_home`
is trusted automatically, and its `.claude` settings, MCP servers and hooks can
execute. Do not clone untrusted repos under `project_home`.

The guards: never `$HOME`, its ancestors, `project_home` itself (a
`project_home` that is `/`, `$HOME` or an ancestor of it makes nothing
eligible), or Butler's own roots and anything below them; the dialog's exact
option text is matched and a digit is never sent; the path the dialog shows
must equal the launch directory (or its real path); an unexpected layout
presses nothing and alerts once.

## Closing sessions

`remuda butler close NAME [--force]` closes a session when the caller is its
leader. A person at a terminal counts as the root `butler`. The root may also
close a leader-less row (no leader, or a leader that is gone and not
relaunching) with the command line; the `butler_close` tool never closes
leader-less rows. Nobody can close the root row. Without `--force` a row with unread mail or one that is not idle
is refused.

When a lead exits, its live members move to the lead's leader (to `butler`
when that leader is gone too), so they stay closable and keep reporting to a
live session. Adoption changes only who the leader is: no one else gains close
rights, and the unread and idle checks apply as before.

A member that finishes its task can report with `remuda butler send-to-leader
--done ...` (the `butler_send_to_leader` tool takes `done: true`). Butler then
closes it on its own: every 30 seconds it tries the normal close with the
member's leader as the closer, never forced, so unread mail or a busy pane keeps
the member open until a later try. New mail to the member cancels the request,
and so does a daemon restart (the mark is kept in memory only). A report
without `--done` never closes anyone, and the root and leader-less rows are
never closed this way.

## The root AGENTS.md

Butler's own guidance in the root session's `AGENTS.md` sits between
`<!-- BEGIN remuda-butler:managed id=butler -->` and
`<!-- END remuda-butler:managed id=butler -->`. Text outside the markers is
kept; text inside is rewritten to Butler's current text. A file whose markers
are damaged or doubled, a symlinked `AGENTS.md`, and a file mixing LF and CRLF
line endings are left unchanged, and the trace names them. A file holding only an earlier Butler text is replaced by the
marked form; any other unmarked file keeps its text and gets the block appended.

## Schedules

A schedule sends a fixed text to a session at wall-clock times and survives
restarts. It is stored in `schedules.json` beside the mail store and delivered
as ordinary Butler mail.

```
remuda butler schedule list
remuda butler schedule add NAME "M H * * *" TEXT [--to SESSION]
remuda butler schedule rm NAME
```

`NAME` is 1-32 characters of `a-z`, `0-9` and `-`, unique among at most 16
schedules. `SESSION` is a live session alias and defaults to `butler`. `TEXT`
is at most 2048 bytes and holds no control characters except newlines; `-`
reads it from stdin. The schedule has five fields in the machine's local time:
the minute is `N` or `*/N` (N is 5, 6, 10, 12, 15, 20 or 30, so the gap
stays the same across the hour), the hour is `N` or `*`, and day,
month and weekday are `*`. `7 * * * *` is minute 7 of every hour,
`0 9 * * *` is 09:00 daily, `*/30 * * * *` is every half hour.

`list` is open to every session and prints each schedule's name, spec, target,
state, last firing and the first 80 bytes of its text. `add` and `rm` are for a
person at the terminal; a Butler agent is refused, because a schedule keeps
injecting its text after the agent has forgotten it. `add` asks for `yes` at
the terminal, as turning typed lines on does; `rm` does not ask.
The operator-only gate on `add` and `rm` is advisory within one user account, like
the typed-line switches: a process running as the same user with Lua access can
write the schedule store directly. A schedule's text is delivered as mail marked
as a timed message, never as typed input.

A timer checks every 30 seconds. Each due schedule is delivered as mail from
the reserved sender `schedule`, with the subject `[schedule NAME]` and a first
line saying it is a timed message and not a human instruction. It is never
typed into a session or run as a shell command. The slot is recorded before the
mail is sent, so a failed send or a restart in the same minute never repeats
it, and a failed send is not retried. After downtime a schedule fires once, for
its latest missed slot. A slot is skipped, with a line in the trace log, when
the target session is not live (`schedule_target_absent`) or when the previous
mail of the same schedule is still unread (`schedule_unread_skip`), so a
schedule leaves at most one unread mail. When a clock change skips a scheduled
time, the schedule fires once at the first minute after the gap; a time that a
clock change repeats can fire twice. The session name `schedule` is reserved
and cannot be launched.

`add`, `rm`, firings and skips are written to the trace log
(`compaction-trace.log` under the Remuda config directory). A `schedules.json`
that is corrupt, oversized or of an unknown version is treated as empty and
traced; `add` and `rm` leave it untouched until it is fixed or removed.

### Moving a Claude cron to a schedule

A Claude `CronCreate` job lives only in one Claude session and stops with it. To
move the hourly North Star check and the staging-guard liveness check to the
persistent scheduler, run these at the terminal as the operator (each `add` asks
for `yes`; both default to the `butler` session, add `--to SESSION` for another):

```
remuda butler schedule add north-star "7 * * * *" "Hourly North Star check: follow the North Star check note in the operator's notes repo (delegate the legwork to a member/subagent). Also: remuda butler sessions + inbox; nudge any stalled or idle lead; confirm each team keeps <=3 members alive (post-reboot load limit)."
remuda butler schedule add staging-guard "37 * * * *" "staging-guard liveness: check remuda butler sessions shows staging-guard and its pane is not stuck on a dialog (capture it). If dead or stuck, report it; do not approve dialogs. No report to the owner unless action was needed."
remuda butler schedule list
```

Check that `list` shows both names with the right spec and target. Only then end
the two old Claude crons (`CronList`, then `CronDelete` on the `7 * * * *` and
`37 * * * *` jobs in the butler session), so the check never runs twice. The
text arrives as timed mail from `schedule`, not as a typed prompt; if you
change the wording, keep it free of shell quoting that the mail reader would
need to run. Undo with `remuda butler schedule rm NAME`.

## Handoff letters

A Butler that is about to stop or be replaced leaves its open items as a mail to
`butler` whose first line is `HANDOFF`, written with `remuda butler send butler -`.
The root Butler keeps its ULID across a relaunch, so the letter is still unread
in its inbox, and its launch prompt tells it to read a `HANDOFF` mail before
anything else. The convention has no verb of its own. Put decisions, open
items and pointers in the letter (up to 8 KB), never secrets or tokens.

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
remuda butler matrix [--json] [--room ROOM] send TEXT | - | --file PATH
remuda butler matrix [--json] [--room ROOM] reply EVENT_ID TEXT | - | --file PATH
remuda butler matrix [--json] [--room ROOM] react EVENT_ID KEY
remuda butler matrix [--json] [--room ROOM] upload [--thread EVENT_ID] [--caption TEXT] PATH
remuda butler matrix [--json] [--room ROOM] redact EVENT_ID [--reason TEXT]
remuda butler matrix [--json] join ROOM
remuda butler matrix [--json] leave ROOM
remuda butler matrix [--json] quarantine [--id EVENT_ID]
```

`thread` takes an event ID or the ID of a Matrix mail (`01M...`). A mail ID
reads the room and thread root recorded in that mail, so `--room` is not
needed, and a `--room` other than the mail's is refused. A member can read only
mail delivered to it; any other mail ID is refused with
`Next: remuda butler inbox`. An event delivered as mail also resolves its room.

`send` and `reply` take the text as arguments, `-` for stdin, or `--file PATH`
for a file. Bodies are limited to 64 KiB, and a file must lie inside the
caller's working directory, as for `remuda butler send`. A text that starts
with `--` and is not `--file` is refused with a `Next:` line; put `--` before
the text to send it literally (`send -- --text`). The output names the room
posted to.

`upload` posts a file (up to 20 MB) to the room, as an `m.image` or `m.file` event.
With `--thread EVENT_ID` the file goes into that event's thread, built like a
`reply`: the event must be one the Butler received as mail or sent itself, and in
the room addressed, or it is refused with the same `Next:` line as `reply`. With
`--caption TEXT` the event `body` is the caption and `filename` the file name;
without it `body` is the file name. The upload is recorded as a Butler event, so
a reply to it works. `remuda butler reply MESSAGE-ID --attach PATH [CAPTION...]`
posts the file into the Matrix thread of that mail (one file per command; a mail
that did not come from Matrix is refused; `--file` still means "read the text
from a file"). An agent session may upload only a file inside its working
directory; the refusal says to copy the file there first and pass the copy.

`download` writes the media to `-o PATH`. PATH must be an absolute path, from a
terminal too: a relative one is refused ("is not an absolute path"), because
the daemon writes the file and its directory is not yours. From an agent
session PATH must also lie inside the session's working directory; with no
`-o` the file is written there as `matrix-<media id>`.

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

### Prepared text approvals

An agent can register exact text with `remuda butler approve-text request
SESSION -` and stdin, or the `butler_approve_text` MCP tool. Text can contain
multiple lines and is limited to 8 KiB. Core input normalization strips ESC
and other C0/C1 controls and turns CR and CRLF into LF. Registration applies
the CR normalization and refuses those controls except tab and newline. Butler
posts that normalized stored text to the configured approval room with a
quoted, escaped display, a four-character request id, target session, byte
count and `ID/bytes` fingerprint. The fingerprint is the request id and stored
byte count; the normalized text and byte count are stored with the request.

An allowlisted owner can approve with ✅ or a `yes`/`승인` reply, optionally
including the id. A ❌ or `no`/`거부` denies it. Replies must arrive in live
Matrix sync; messages from agents and the terminal approve/deny verbs cannot
deliver prepared text. Butler types only after confirming the same live session
instance is live and its input box is safe to type into; an attached terminal
does not block it (the reply says so). After typing, Butler reads the pane back
for up to 3 seconds and replies `typed (seen)` only when the text appears there
(wrapping tolerated; the whole text must appear, very short text can match
unrelated output, and the session must still be the same instance); otherwise it replies `typed, NOT seen
in the pane; check SESSION before approving it again`. It never types again on
its own, and neither the reply nor the trace repeats the text. The owner sees the same normalized text that Butler stores. The display escapes control, line
separator and bidirectional formatting characters. A refusal before typing
leaves the approved request available for another owner reply until expiry.
Before typing, Butler persists a one-shot delivery marker; if typing can have
started, the request cannot be retried. If Butler restarts after saving that
marker, delivery is uncertain: the text may not have been typed, and it must
be registered again. Requests expire after 60 minutes; no
more than five may be pending at once, and an agent may register at most ten
in ten minutes.
Session binding uses the Butler session identity and a non-secret launch marker;
the root Butler identity can survive a pane relaunch, so its fresh launch marker
is what distinguishes that instance.
`remuda butler approve-text on|off` is a terminal-only switch that asks for
`yes` before enabling. It is off by default; with it off, replies stay on the
ordinary mail path. Registration is also refused in Matrix messages fallback
mode because that mode cannot receive live owner approvals. Doctor reports
`Approve text: on|off`.

### Status commands

An allowlisted owner can send `?status` or `?help` as a whole line in the HOME
room, a followed thread, or a message that mentions the Butler. Butler answers
with one threaded notice built by code, with no LLM and no agent running:
`?status` lists each session's name, kind, context percent, idle or task, and
unread mail count, then the Claude quota from the cached statusline reading
(Codex quota shows `n/a`; load shows cpu, memory and disk when readable; on
macOS `df /` reports the read-only system volume and memory is approximate);
`?help` lists the commands. The
answer holds at most 14 lines and 1500 bytes and never includes mail bodies,
prompts, screen text, paths, or accounts. A sender gets one answer per 10
seconds, separate from the typed-line limit. A command is never typed into a
session, and a message that is not exactly one known command stays on the
ordinary mail path. `remuda butler status-commands on|off` turns it off or on
(on asks for `yes` at the terminal; an agent is refused); it is on by default. In `matrix.conf`, `status_commands` is on when absent or `true`;
any value other than `true` or `false` turns it off.

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
Two Butlers talked N turns without a human, so I paused thread ROOT (ROOM) to avoid ping-pong. No action needed; reply in that thread only if you want it to continue.
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
room by ID or alias, while HOME and ALL-BUTLERS cannot be left or removed.
`mark-all ROOM` (operator only) marks an already-joined room, for example one entered by
owner invite, as ALL-BUTLERS by turning its `room=` line into `all_room=`; it refuses when an
ALL-BUTLERS room is already set. Before running it, check that the room's members are only you and Butlers: ALL-BUTLERS
receives approval requests posted in full (`doctor` prints this in its `Next:` line). Config changes, including this one, take effect after a
Butler reload (`remuda exec butler`). The interactive setup wizard writes `rooms=open` without asking; flag-based setup
defaults to allowlist unless given `--rooms open`. `send -` reads the text from
stdin (up to 64 KiB, one trailing newline dropped); `send -- -` sends a literal `-`.

`join` and `leave` change room membership. Butler identifies CLI members by the
daemon's caller session, matched to a unique live registration; clearing launch
variables does not change that identity. Unknown or unregistered callers are
refused. Outside callers use the audited transitional operator policy. MCP tools
also retain their existing session-capability fallback. This is advisory within
one user account, not an isolation boundary.

Approvals: when an agent runs `matrix join`, Butler resolves the room and
posts one request as an ordinary message with an owner mention. Prepared-text
and Claude guard approvals use the same room. `approval_room=all` (the default)
uses the joined ALL-BUTLERS room and falls back to HOME; `approval_room=home`
always uses HOME. Doctor shows the configured mode and resulting room. Every
allowlisted owner is mentioned, while Butler senders and the relay's own MXID
are excluded. A second human who is not on the allowlist can read the request
in a shared room but cannot answer it. The lounge must stay the owner plus the
owner's own butlers, otherwise set `approval_room=home`.

The lounge accepts prepared text up to 1 KiB. Longer prepared-text requests are
posted whole in HOME with the full text and hash, and HOME is the only room
where they can be answered. There is no second HOME copy. Butler types the full
stored text after approval. Approval posts carry `app.remuda.approval=true`; relays skip marked
events from Butler senders before quarantine or delivery to prevent
Butler-to-Butler loops. If the lounge post fails, Butler reports `Could not post
approval request` and does not retry the request in HOME.

The owner answers with a ✅ or ❌ reaction, or a `yes`/`no` reply, to that exact
message within 30 minutes (`approval_ttl_minutes`, 1 to 1440; Claude guard
approvals keep their fixed 290 second window). Only an allowlisted human sender
in the request's room counts. A bare `yes` does nothing.
The owner can also answer from the terminal: `remuda butler approvals` lists
the open requests, and `remuda butler approve ID` or `deny ID` answers one
(operator-only). Terminal approve/deny are refused for a Butler member, by the
same daemon-derived caller principal; clearing launch variables does not change
it. Unknown callers are refused. This is advisory, not an isolation boundary.
The Matrix answer path
is bound to the owner's MXID. An approved request joins the room ID resolved
at request time and writes `room=ID how=approved`. The asker gets mail for every outcome:
approved, denied or expired. A repeat ask for the same room returns the same
request. Each agent may have 3 open requests, and there may be 5 in total.
Requests live in the relay state file.
The config accepts `approval_room=all|home`; an absent or invalid value uses
`all`.

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
environment (stdin is closed), so treat it as running with your own authority.

Whoever made the password keeps it. Setup saves no copy of a password you
supply, with `--password-cmd` or with `--password-file`, and says so: "The
password you supplied was not copied." Only a password that setup generates
(`--register` with neither option) is saved, and setup prints where.

Where a generated password is saved:

| System | Place |
|---|---|
| Windows 10/11 | Credential Manager |
| macOS | login Keychain |
| Linux | the private file `password` beside the token (for now) |

- The entry is named `butler/matrix/<bot user ID>/password`, under the service
  `remuda`. Setup prints: "Bot account password saved in the OS secure store
  (BACKEND) as NAME".
- If the store is missing or refuses (no desktop session, a locked keychain,
  an older core), setup saves the password in the private file `password`
  beside the token instead, mode 600 on Unix hosts, and prints "Bot account
  password saved privately: PATH". When a store is there but refused, it also
  prints "The OS secure store was not used: REASON" (`unavailable` or
  `denied`).
- `--dir PATH` always uses that file in `PATH` and never touches the store.
- A password from `--password-file` or `--password-cmd` is never put in the
  store.
- If setup fails after it stored the password, it deletes the entry again. If
  that delete fails, or the daemon dies in between, the entry
  `butler/matrix/<bot user ID>/password` stays: delete it by hand (see below
  for where to find it). A failed delete names the entry in the error.
- An old `password` file is left in place when the password goes to the store
  or was supplied by you. Setup names the file; delete it if you no longer use
  it. Only when the store refuses after the account was created does setup
  replace that file, and it says so.

Butler never reads the password back; it is kept for you. To read it by hand:

- macOS: open Keychain Access, search for `remuda` (service `remuda`, account
  `butler/matrix/<bot user ID>/password`), and choose Show Password.
- Windows: open Control Panel > Credential Manager > Windows Credentials and
  look for the entry `remuda:butler/matrix/<bot user ID>/password`.

The store is not a sandbox. Any Lua that runs in the daemon image, including
the MCP `run_script` tool, runs as the same program and can read the store.

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
   `approval_ttl_minutes=N` sets how long an owner approval request stays open
   (default 30; a Claude guard approval keeps its fixed 5 minute window);
   `approval_room=all|home` selects the joined ALL-BUTLERS room or HOME
   (default `all`);
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

Butler waits for a known empty composer before typing a mail notice. A pane can
report background work while its own prompt is idle; Butler types notices only
into an empty composer and waits for an attached human to pause. If notice
delivery cannot be verified, Butler retries after 20 seconds, one minute, five
minutes and 15 minutes, then sends one failure message to the original mail
sender with the exact command to resend. The sent failure notice is recorded in
mail so a daemon restart cannot send it again. Mail without a Butler sender
identity, such as CLI or Matrix mail, is reported to the recipient's leader. If
that leader is absent or has exited, the root Butler receives the failure mail.
The root records its own notice failure without mailing itself. Notice retries
stop when the mail is read or the recipient exits.

The client session list leads each Butler session line with its status, read
from the agent's own screen probes: `working`, `idle`, `needs you` (a trust,
update or startup dialog) or `other` (no screen, an unreadable one, or a kind
without reliable probes such as Monocle). The screen is captured at most once
per session every 2 seconds and only the status word is shown, for example
`idle · claude · opus · 123K · ✉2`.
For Claude members, Claude Code hooks written into the member's settings file
(UserPromptSubmit = `working`, Stop = `idle`, a permission or elicitation
Notification = `needs you`, an idle-prompt Notification = `idle`) call the
internal `remuda butler status-hook`, which stores only that word and a time in
`<status file>.state`. A hook word beats the screen while fresh: 10 minutes for
`working` (a missing Stop means a crash or interrupt), an hour for `idle` and
`needs you`; those two still yield to a screen that shows `working`. Otherwise
the screen probe decides. Codex has no hooks yet and stays on the screen probe.
Explicit Monocle launches use this argv: `monocle agent --workdir DIR --session NAME --auto-approve`;
Butler adds `--model M` when specified.
`--auto-approve` means the member runs with Monocle's own auto-approval. Butler
adds no extra gate for this kind: no permission rules, no MCP token, no trust
dialog. Launch it only in directories you trust.

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

## Guardrail grants (slice 3 design rules)

These rules are final for slice 3 of the guardrails (#339). All of slice 3 sits
behind one switch that is off by default, and with it off no grant exists and
no guard behavior changes.

### Binding owner conditions

- Scope is slice 3 only. There is no learning loop (3b), no slice 4 and no
  slice 5.
- The owner can freeze and revoke from Matrix (see Freeze and revoke). Freeze
  and revoke only narrow power; lifting a freeze stays owner-approved.
- Any push that touches CI or workflow files is T3 and always asks. A standing
  grant never covers it (see Pushes under a grant).
- Every audit line carries `grant_id`. The audit log has a daily hash digest
  posted to the HOME room, a retention period of 90 days, and a `guard stats`
  baseline snapshot saved before any grant code ships.
- The approval post offers three separate reactions: approve once, approve as
  a standing grant, and deny. They are never one button.
- The switch is off by default. The owner flips it, after one week of saved
  baseline stats.
- PR4 MUST: `load()` cross-checks each grant's approval event id against
  Butler's own record of the owner's reaction before a grant can allow.
  The store trusts its own lines; a grant is never allowed on the store alone.

### Who decides

A grant is created only from an authenticated owner Matrix reaction: an
allowlisted mxid, on the event id of the approval post for that request. No CLI
verb creates a grant. A process without a Butler identity is treated as the
operator by the CLI, so a CLI path would let it grant itself.

The grants switch is classed in `guard_policy` like `guard on/off`: an action
that weakens the guard, owner-only.

Only the owner grants `writable:DIR`, `git:common` and `net:DOMAIN`. Butler
root, leaders and members request; none of them decides. A first use of a new
scope is T2: the owner is asked once. A leader does not pass grants to a
child in slice 3; a child gets the default profile for its role and asks for
anything more. `device`, open `net` and `full` stay T3.

### Approval post and reactions

Butler composes and posts the options itself. Only the owner's reaction on
that event id counts: an allowlisted human mxid, in the post's room, live (not
backfill), after the post was made. Three separate reactions, never one button:

| Reaction | Meaning |
| --- | --- |
| ✅ | approve this one call (single-use) |
| 🔄 | approve this call and record a standing grant for the scope shown; while it lasts, a later Claude call it covers is allowed without a post (see Grant use) |
| ❌ | deny, and remember the deny (see Request limits) |

Each post is one request with its own id and nonce, and the post's text hash
covers the offered grant. A reaction naming another request's event, from
anyone else, in another room, before the post, outside live sync, on an
expired or answered request, or on a request that offers no grant (🔄 on
anything but a guard post, or on a call that cannot be granted) creates
nothing. Each reaction is consumed once. Only 🔄 creates a grant; ✅ and ❌
create none. While the grants switch is off the post offers no 🔄 and a 🔄
that arrives anyway does nothing; the request stays open.

What can be offered: a fetch (`net`, the exact host) and a plain `git push`
(`git`, the working directory). Every grant is T2, one hour, and ends at the
absolute time the post shows. A call
that cannot be scoped narrowly (an unparseable host, a push that is not a
plain `git push [remote [branch]]`, a protected place) is not offered one.

Grants are created in one place: the reaction handler registered by the
approval module in the same load that defines it, through the grant store's
one-time `register`. If `register` answers "already registered" (the store was
handed out earlier in this load), Butler logs it to stderr, the daemon log and
the audit log (`grant_register_refused`), and no reaction can create a grant
until Butler reloads.

Limit: `approval.answer(id, "grant", who, event)` trusts its `who` and
`event` arguments. The relay passes only the verified owner's mxid and the
reaction's event id, and every call site must keep doing so; Lua running inside
the daemon can call it directly, so, like `register`, this is a cooperative
limit and not a boundary.

The cross-check: the store trusts only grants whose approval event id is the
owner's reaction event that Butler itself recorded on the request (reaction
event, grant id, class and scope all equal). A line written into the file by
hand, or one that reuses a real reaction for another scope, is no grant.

The post shows the resolved (realpath) scope and the absolute expiry time, both
derived from the request by Butler, never from agent text.

### Request limits and remembered denies

With the grants switch on (off: no new behavior at all):

- **Per scope: 10 approval posts per hour** (the host or repository, or the
  tool, class and directory when no scope applies; never the command text).
  The number protects the owner from a flood of posts for one kind of call: an
  agent that varies the text of a command (a trailing space, `; :`) still hits
  the same limit.
- **Overall: 30 approval posts per hour.**
- **Per agent session: 5 approval posts per minute**, as an extra bucket only.
- **A deny is remembered for 10 minutes** for the same scope, whichever agent
  or session name asks. During that time the same request is answered deny at
  once, without a post. Another scope, or the same request after 10 minutes,
  is asked as usual.

The per-session bucket uses the alias from the resolved caller principal.
Requester metadata cannot choose that bucket. Remembered denies and per-scope
limits apply across sessions (and the remembered deny keeps exact command text
when no scope applies), while the per-session bucket remains an extra limit.

A request over a post limit is refused without a post: the hook prints no
decision, so Claude shows its own prompt, and the refusal is an audit line
(`approval_limited`). A remembered deny is an audit line (`approval_denied`,
"remembered deny"). Limits and remembered denies live in the daemon's memory
and end when it restarts. The existing caps (open requests per session and in
all, 30 requests per 10 minutes per asker) stay.

### Freeze and revoke (owner, Matrix only)

Three lines the owner types in the HOME room. Each takes no other text (`guard revoke` takes exactly one id); a line that starts with one of these verbs and has more, or a malformed id, is answered with its usage and never handed on as mail or a typed line:

| Line | What it does |
| --- | --- |
| `guard revoke gNNN` | ends that one grant at the next hook call; answers plainly when the id is unknown, already revoked or already expired |
| `guard freeze` | no grant matches and none is offered or made until the freeze is lifted |
| `guard unfreeze` | asks to lift the freeze: Butler posts a request, and only the owner's ✅ reaction on that post (or `yes ID` as a reply) lifts it; ❌, `no ID` or expiry keeps the freeze |

They take the same owner gate as the reactions: an allowlisted human mxid, live
sync (not backfill or the first sync after a start), a message that is not an
edit, in the HOME room, and not older than the relay. Any other sender (a
stranger, an agent, Butler itself) or any other room does nothing. There is no
CLI verb for them and an agent cannot reach them: `remuda butler guard freeze`
is a usage error, and the terminal cannot approve the unfreeze request.
Freeze and revoke only narrow power; widening it again (lifting a freeze) is
always the owner's answer on a Butler post, never a plain command.

Butler answers each line with one short plain confirmation in the room (no
agent text, no mention) and writes an audit line (`grant_revoked` with the
`grant_id`, `grants_frozen`, `grants_unfrozen`, `owner_line_refused` for a usage
answer); every summary names the sender and the Matrix event of the line (of
the answering reaction for an unfreeze). Freeze and revoke act even when their
audit line cannot be written and log the failure. Lifting widens, so the
`grants_unfrozen` line is written first: if it cannot be, the freeze stays and
Butler says so. A revoke rewrites that grant's
line in the store as revoked. A new `guard freeze` (also when already frozen)
expires any open unfreeze request, and an unfreeze post made before the latest
freeze lifts nothing, so a late ✅ on an old post cannot beat a newer freeze. If
the unfreeze post cannot be made, is already open or is refused by a cap, the
reply says which. Freeze and revoke use the grant store's public functions, so
they still work when the private hand-over to the reaction handler did not
happen (a refused register, or the approval module reloaded alone); the add and
the unfreeze never leave the handler. A freeze is a marker file in the protected data
dir, so it survives a restart; while it stands the approval post offers no 🔄
and a 🔄 on an older post is refused. Both fail closed: if the revoke or the
marker cannot be saved, the grant (or every grant) is off in memory and Butler
says so, until it restarts. `remuda butler guard grants` shows `frozen` and the
revoked grants.

### Expiry notice

Grants that expire within 60 seconds of the first one are announced in one
notice in the owner (HOME) room, naming each (`g001 net example.com`); there
is no notice per grant and no mention. A grant is tracked from the store, frozen or not, so one that
expires during a freeze is still announced. Only grants this daemon saw held are
announced: one that expired while Butler was not running is not. With the
switch off nothing is tracked or posted.

### Grant lifetime and store

A grant's TTL is at most 24 hours; the default is 1 hour. The cap applies to
every grant however it was created.

The grant store lives under the protected Butler data dir, which a deny rule
covers. Each entry holds the absolute expiry time (never a duration), the scope,
the holder (the asking session's Butler id, see Grant use) and the approval
event id for cross-check. The store is reloaded on
Butler start. An entry that is expired, unparseable, lacks a matching approval
event, or was written with a clock that has gone backwards is no grant (fail
closed). Limit: processes running as the same user, outside the hook, can still
write the file; the deny rule governs agent tools, not the OS.

Installed guard modules always use the ordinary clock, filesystem case probe
and approval cross-check, with fixed 2-second aggregate Git and command limits.
They ignore `REMUDA_BUTLER_TEST` and legacy test fields on every load and reload.
Deterministic test subjects live under `tests/`, outside the installed package.
This remains a cooperative layer: arbitrary Lua in the same image can replace
ordinary dependencies or functions. The text deny
refuses code that names the grant store module, the `_butler_test` field or the
env name (`run_script` code, and `remuda -e`, `lua`, `exec` or `run` commands),
and commands that set `REMUDA_BUTLER_TEST=`; writes into the data dir are
refused as protected writes. Plain reads of repo files that mention them
(`git diff packages/butler/guard_grants.lua`, `rg guard_grants`) are allowed.

### Grant use

A grant answers only a Claude `PermissionRequest`: the prompt Claude would show
for that call is skipped and the call is allowed. It never answers at
`PreToolUse`, so a deny rule there and Claude's own permission checks still
run first. Codex sessions never use grants. The hook decides in this order, and
the first refusal wins:

1. `guard on`, `guard approvals on`, `guard grants on`, and a Claude session.
   With any of these off the grant store is not read.
2. No deny rule names the call (the deny rules are checked again here, with the
   deny switch on or off).
3. The call is a plain push (Bash or PowerShell, class `push`) or a WebFetch
   (class `net`). Every other class asks.
4. The target is not a protected place, the grant is live (not frozen, expired,
   revoked, unverified or written ahead of the clock), and it covers the call
   (see Pushes under a grant and Network scopes).
5. The grant has a use left this hour (below).
6. A `grant_used` line naming the grant is written to the audit log.

Every refusal, and every error on the way (the store, git, the match itself,
the audit write), asks: the call goes on to the approval post, or to Claude's
own prompt. Nothing on an error path allows.

Holder: a grant is held by the session that asked for it, and it covers that
session and the sessions below it (its members, and theirs), never a sibling or
a leader above. Butler takes the session from core's caller identity (the hook
process's ancestry up to its session pane), not from the alias in the agent's
environment, and records it as the session's Butler id (a ULID; an alias can be
reused after a member exits). The approval post names the holder, the hash
covers it, and the store line is vouched for only when Butler's record of the
owner's reaction names the same holder. A call whose caller is not exactly one
session Butler knows (outside any pane, unknown, a pane Butler did not launch)
is offered no grant and uses none. The identity is read once when the hook
starts, before any audit write can wait on the lock. Core states that its caller
identity is advisory, not authentication: like the rest of the guard this keeps
agents in their lane and is no isolation against a malicious same-user process or
`run_script`. The subtree is cooperative too: `topic delegate --leader L` lets
any agent start a child under any leader, and that child is covered by the
grants L holds. The owner can revoke a grant or freeze them all.

Audit before allow: the call is allowed only after its `grant_used` line was
written. The use is reserved before the write (which can wait on the audit lock
while another hook runs), so two calls at once cannot both take the last use. If
that line cannot be written the call asks and the reserved use is given back, because the audit line is the only record the owner and the hourly
limit rely on, and asking costs one post while an unaudited allow cannot be
reconstructed.

`grant_id` is `gNNN` only on the `grant_used` line of a call a grant allowed,
on the `grant_limited` line below, and on the grant's own create and revoke
lines. The request line of the same call, a deny and every asked call keep `-`.

Hourly limit: a grant allows at most 30 calls in any rolling hour. The 31st
asks and writes one `grant_limited` line naming the grant; further calls in
that hour ask without another line. The count lives in daemon memory and
survives a live reload. After a restart, a grant's first use rebuilds its count
from the `grant_used` lines of the live audit log within the last hour; if the
log cannot be read, the call asks. A rotation within that hour moves older lines
out of the live log, so a rotation plus a restart can reset a grant's count by
up to 30, once per restart.

`remuda butler guard grants` ends each active grant's line with `used N/30 in
the last hour` (`?` when the count cannot be read), the same count the limit
uses. `remuda butler guard stats` adds `auto-allowed by grants: N of M permission
requests (P%), L limited` once any `grant_used` or `grant_limited` line exists.

Clock skew: Butler keeps the highest clock time it has seen. A clock more than
60 seconds behind it matches no grant until it catches up; a forward jump only
expires grants early.

With grants on and no live git grant, matching runs no process: the git probes
start only when a git grant could cover the call.

Where a push runs: a git grant's scope is compared with the `cwd` field of the
`PermissionRequest` payload, while the push itself runs in the Bash tool's own
shell directory. The two are assumed to be the same directory (the payload has no
other directory field). A command that changes directory first (`cd DIR && git
push`, `cd DIR; git push`) is a compound and never matches.

The CI-path check diffs against the local tracking ref
(`refs/remotes/REMOTE/BRANCH`), which a same-user process can move (`git
update-ref`), hiding an earlier commit that touched CI files. Like the rest of the
guard this is cooperative; server-side branch protection is the real control.

Any same-user process with a session's environment can run the hook command
itself with a made-up payload. The allow then goes to its own output, not to
Claude, but its `grant_used` lines spend the grant's uses, so later calls ask;
revoke and freeze still work.

### Scope patterns

- A scope is a class plus a narrow pattern: a repo, a domain or a directory.
- A bare `*` is never a scope.
- A glob may only be a whole path segment `*` below a fixed absolute prefix
  (`~/projects/rx/*`). Partial-segment globs (`rx-*`, `t1*`) are refused, and
  so is `*` as the first segment. A directory scope covers its subtree.
  `*` never matches `.` or `..`.
- The pattern is resolved when the grant is made and stored as the resolved
  value. Later changes to the filesystem do not widen it.

### Path canonicalisation

One shared function canonicalises every path for grants and for deny rules. It
takes the `realpath` of the target. If the target does not exist, it takes the
`realpath` of the nearest existing ancestor and appends the remaining segments,
refusing any `.` or `..` among them. It case-folds on macOS and Windows. A path
it cannot parse yields no grant: the action falls back to its tier. A symlink
that leaves the scope puts the target outside it.

Residual limit: the path can change between the hook's check and the tool's
run (time of check to time of use). Grants are not a defense against an agent
that races its own filesystem.

### Network scopes

`net:DOMAIN` matches the exact host only; a subdomain needs its own grant. The
host is compared lowercased, without a trailing dot, in punycode form. A URL
with userinfo (any `@` in the authority), a backslash, whitespace or a control
character gets no grant, because parsers disagree about its host. A port
other than the scheme default is a different scope. An IP literal never matches
a domain scope; it needs its own `net:IP` scope, T3. A redirect is a new
request and is judged on its own host. Grants never apply to codex (see Codex
grants), whose sandbox network is all-or-nothing.

### Pushes under a grant

A command string cannot show which files a push changes. Every push covered by
a grant is checked at hook time: `git diff --name-only` against the remote ref,
best effort. A push touching `.github/workflows`, other CI configs, or scripts
those call (`scripts/`, `Makefile`, `justfile`) is T3 and asks. The diff is
taken without renames, so a move out of a CI path still lists the source, and
with repo config, hooks, external diff and textconv neutralised. A push is
covered only when the command is exactly `git push [remote [current-branch]]`:
no shell syntax, refspec, flag, `cd`, `-C`, `env` or `GIT_DIR` prefix.
Anything else falls to the tier. A push of `main`, `master` or `trunk` in any
case (the checked-out branch, read as its full ref, for a bare `git push`, the
named branch otherwise), a push of the remote's default branch (its
`refs/remotes/REMOTE/HEAD` as last fetched; when that is unknown locally only
the three names count), and a push that publishes tags (`push.followTags` set) always ask: a grant never
covers them. Only a push or a WebFetch can match a grant at all; a call the
guard classes as weaken, identity, escape, control, destroy, script or other
never does. All the git probes of one call share a budget of about two seconds;
when it runs out, or no git grant exists, there is no grant. The path set is a
list in code, reviewed like any guard rule. Server-side branch protection and required review remain the real
backstop; this check is a convenience, not a boundary.

`git:common` covers the main repo's `.git` except `.git/hooks` and git config.

### Agent text in approval posts

Text an agent supplied (a `why:` line, an intent name, a task description) may
appear in an approval post only as one quoted line of at most 200 characters,
labelled `agent-supplied`, after Butler's own lines. Control and bidirectional
characters are escaped, and Matrix HTML and markdown, mentions (`@room`, the
owner's mxid) and links are stripped. It is never styled or placed as Butler
text, and it never selects the scope, the TTL or the reactions. On a guard post the only agent-supplied text is the tool's own
`description` field (when it has one).


### Audit chain

The live audit log rotates at 1 MiB. Butler keeps at most 16 archives, including
`guard-audit.jsonl.1`, and removes dated archives older than 90 days at rotation.
When the count fills first, it removes the oldest archives, preserving the
newest evidence and numeric ordering of rotations within the same second.
Normal storage is about 17 MiB plus the final record in each file; this is an
archive-count budget, not a filesystem quota. Rotation or pruning failures
refuse new appends rather than allowing the live log to keep growing. Required
operator attribution fails closed on open, write, flush, or close errors.

Every outside principal resolution records its own `caller_policy` event;
polls are not sampled or aggregated, and a command can resolve more than once.
Read-only commands that do not resolve a principal, such as `sessions`, add no
policy event. Prefer those for frequent roster polling. Export evidence before
it ages out or fills the archive budget if longer retention is needed; daily
HOME-room digests remain the off-box record.

Each new audit line carries `prev`, the SHA-256 of the line before it (its text
without the newline). A log that is new, or whose last line predates the chain,
starts with a `chain` genesis line (`"prev":"genesis"`); older lines are not
rewritten. When the log rotates, the first line of the new live log carries the
hash of the rotated file's last line, so the chain runs across files. If the
hash cannot be computed the line is still written, without `prev`: audit never
blocks on hashing. Required operator attribution still refuses when its audit
write cannot complete.

`remuda butler guard verify` (read-only, not a weakening verb) walks the dated
archives, `guard-audit.jsonl.1` and the live log in order and prints `ok` with
the chained line count and last hash, or `BROKEN at FILE line N` with the
reason. It detects a removed, edited or unchained line and a removed rotated
file. A final line of the live log with no newline yet is a write in
progress: it is reported as a note, not as BROKEN. It cannot detect the whole log replaced by a consistent forgery by the
same user, nor the truncation of the newest lines, and it cannot check the
oldest kept archive's first link (older archives are pruned after 90 days or
when the archive budget fills).

Verify hashes every line in pure Lua, about two seconds per megabyte on an M1
Max, inside the daemon. Each file holds at most 1 MB before it rotates, so a
log with all 16 archives can take tens of seconds; run it when the
daemon may be busy that long.

A fork of the chain (the audit lock fell back after 1 s and two writers raced, a line
written without `prev` because the hash failed, a line cut short by a crash and
appended to) makes verify report BROKEN at that line, and it keeps doing so until the
file holding it is pruned (up to 90 days, or sooner under the archive budget).
There is no way to acknowledge or re-anchor the chain, and verify stops at that
first break.

The audit lock is core's `remuda.fs.lock`, which never blocks (it is a try-lock, a
busy lock answers at once). The audit write retries it for about a second, then
writes without it, so a holder that never lets go cannot hang the hooks; the cost
is a possible fork, as above.

Once per UTC day, Butler posts a digest of the last completed day to HOME (the
owner room): its audit line count, the hash of its last line, and the hash of
the previous digest. A day with no audit lines gets none, a restart does not
repeat one (the last day and hash are kept in the protected data dir), and a
failed post is retried. The digest holds only counts and hashes, never agent
text. The digest in the owner's room is the real control: it is off the box, so
a replaced log no longer matches it. The local chain only detects.

After downtime (or a run of failed posts across midnight) the days since the last digest
are attested oldest first, each linking the digest before it, so the chain has no
skipped day within the last 7 days. A gap older than that cap is never covered: the digest
resumes with the newest 7 days and its previous-digest link still names the last one
posted. A quiet day is scanned once, and a failed post is retried without scanning
again. If the digest state cannot be saved (`guard-digest.json`), a restart may post
the same day again: a double post, the safe direction.

### Codex grants

Grants apply to Claude sessions only. A codex session keeps its fixed launch
profile (sandbox and writable roots, set when it starts); no path widens it, and
Butler never edits a running codex sandbox. A codex grant would need its own
owner-approved design. Claude grants are checked on every hook call, so expiry
and revocation apply on the next tool call.
