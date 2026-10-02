# Changelog

All notable user-facing changes to Remuda Butler. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Butler has no
release tags yet; entries come from merged pull requests.

## Unreleased

### Added
- `remuda butler matrix send` and `reply` accept `-` and `--file PATH` like the mail verbs, a text starting with an unknown `--option` is refused instead of posted (use `--` for literal text), and the output names the room posted to (#251).
- A mail whose first line is `HANDOFF` is the handoff letter: the root Butler reads it first after a relaunch.
- `remuda butler schedule list|add|rm` keeps fixed texts that arrive as Butler mail from the reserved sender `schedule` at set times (`M H * * *`), across restarts; `add` and `rm` are for a person at the terminal.
- Matrix `?status` and `?help` answer from code without an LLM, so the fleet stays visible when a model is out of quota; `remuda butler status-commands on|off` switches them (on by default).
- `remuda butler matrix setup --password-cmd PROG [ARG...]` reads the bot password from a program such as a password manager (`op read ...`, `security find-generic-password ...`, `powershell -NoProfile -Command ...`). It must be the last option, and setup saves no copy of that password.
- Butler resolves installed agent CLIs on Windows, uses `USERPROFILE` when `HOME` is missing, and gives a clear next step when launch fails.
- `remuda butler matrix setup` with no flags runs guided prompts (#127). The wizard always opens rooms and does not ask about room access (#145).
- Matrix open-room mode: anyone may invite the Butler, subject to `deny_room`/`deny_server` rules and a daily join cap (#136).
- Matrix join and leave accept a room alias or a public room name; public rooms can be browsed (#123).
- When an agent asks to join a Matrix room, the owner is asked in HOME (#138).
- `remuda butler doctor` checks agent CLIs and logins and prints the next command (#128).
- `remuda butler quota` reports, for Claude Code and Codex CLI, the login mode, the subscription account and the used share of each limit with its reset time; `--report` posts the same report to the Matrix home room.
- `remuda butler close NAME` lets a leader close its own members (#149).
- After a compaction or restart, a member is shown the last unanswered leader message again; `remuda butler inbox` shows message IDs (#159).
- `remuda butler matrix follow EVENT_ID` and `unfollow EVENT_ID` manage thread replies. HOME always delivers replies; other rooms deliver a reply only in a followed thread or on a mention. Replying, sending, and a mention from an allowlisted sender follow the thread automatically (#178).
- `remuda butler matrix send -` reads the message from stdin, up to 64 KiB (#170).
- Outgoing Matrix messages carry a formatted HTML body rendered from a Markdown subset; raw HTML is always escaped (#171).
- Matrix `posts_per_hour` (default 30) caps the Butler's Matrix posts per hour that are not a reply to a person on the allowlist; a refused post says `Next: wait until HH:MMZ`, and the first refusal in an hour posts one line to HOME (#223).
- When the hourly cap for non-allowlisted senders is hit, HOME gets a summary with the count: the first one at once, then at most one per room per 10 minutes (#223).
- The first Matrix mail from an allowlisted sender in an unseen thread includes the thread root and up to 20 earlier replies as one-line context; the inbox names each mail's room and thread (#235).

### Changed
- The Matrix turn-limit notice says plainly that two Butlers talked without a human, that the thread is paused, and that no action is needed; the limit and the resume rule are unchanged (#278).
- `remuda butler matrix setup --register` saves the password it generates in the OS secure store (Credential Manager on Windows 10/11, Keychain on macOS) as `butler/matrix/<bot user ID>/password`, and no longer writes `<dir>/password` there. It needs a core with `remuda.system.credential`. With no store, a store that refuses, or `--dir PATH`, the password goes to the private file as before, and setup prints which place it used. A password from `--password-file` or `--password-cmd` is never stored. An old `<dir>/password` file is left in place and named ("delete it if you no longer use it"). Any Lua in the daemon image, including MCP `run_script`, can read the store: it is not a sandbox.
- `remuda butler matrix setup --register --password-file PATH` no longer saves a copy of the chosen password to `<dir>/password`; whoever made the password keeps it, as with `--password-cmd`. Setup prints "The password you supplied was not copied." and an old `<dir>/password` file no longer blocks it. A password that setup generates is still saved (see the entry above).
- `matrix setup --pin` and `pin_sha256` now trust a self-signed homeserver on their own, using core `pin_only`. The hostname, validity dates and SPKI pin are still checked, and `ca_file` keeps full chain validation. Recommended core: `0.1.0-nightly.20261001000710.0a5f090` (#164).
- A Matrix config with an `http://` homeserver plus `ca_file` or `pin_sha256` is now refused at load, with a `Next:` line naming the config file. Only core's exact `SPKI pin mismatch` error gets the recompute-pin hint (#167).
- The notice for a joined room outside HOME names "the owner" or a count of allowlisted humans instead of listing their MXIDs (#165).
- Matrix replies stay in the room they came from; the text-only `matrix_reply` MCP tool is gone (#150).
- Matrix join/leave decides who the operator is with `remuda.caller()`, not environment variables (#148).
- A Codex compaction slower than 45 s is no longer reported as failed: Butler waits up to 180 s and monitors until idle (#156). The compaction monitor gives up after 30 minutes and releases the fleet lock (#160).
- Codex members are compacted on gpt-6-luna for the session, then their model is restored (#134).
- Launch friction fixes: a verified workspace-trust answer, `delegate --cwd`, and a `--leader` retry (#144). Unreadable Claude trust paths are left for a human, and root trust is offered only at the root (#152).
- An agent session that starts fresh gets one unread-mail notice (#137). Deferred notices can no longer wait forever (#133).
- An `https://` homeserver with a publicly trusted certificate needs no `--pin` or `--ca-file`: core verifies it against the system CA roots. An untrusted certificate still fails, with a `Next:` line naming `--ca-file` and `--pin` (#172).
- The `matrix setup` wizard accepts Enter at the HTTPS trust prompt to use this system's trusted certificates; a certificate pin or CA file path can still be entered (#175).
- Matrix messages from senders not on the allowlist are delivered with a not-on-allowlist marker and are capped per room per hour; their media is quarantined (#178).
- The unread-mail notice fires on a timer, 2 s after the last arrival and at most 10 s after the first, on cores with `remuda.after` (#177).
- One Remuda daemon owns a Butler home. A second daemon on the same home changes nothing and answers every Butler verb with one line naming the owner and a `Next:` line; `remuda butler doctor` still runs there. This needs a core with `remuda.fs.lock`; older cores run as before with one warning line. The root and member MCP configs are now written owner-only (0600) (#195).
- `matrix setup` takes this computer's name for the default bot from core's `remuda.hostname()` when the core has it, so a stock Mac gets a default bot name and no bot-name prompt. On such a core the daemon's `HOSTNAME`/`COMPUTERNAME` and the hostname files are no longer read; older cores keep that lookup (#207).
- Butler-to-Butler Matrix replies are no longer blocked. A per-thread turn guard (`b2b_max_turns`, default 6) stops the Butler after 6 Butler-only turns and posts one line to HOME; a reply in that thread from a person on the allowlist resumes it (#223).

### Fixed
- On Windows, Butler no longer picks the extensionless `claude` / `codex` script that an npm install puts next to `claude.cmd`; it starts the `.cmd` (or `.exe`) file.
- Codex members get the `remuda` MCP server and are told to use the `butler_*` tools: the `remuda butler` CLI cannot reach the daemon from inside the Codex sandbox. This needs a core whose `_codex_tui` forwards `-c KEY=VALUE`; on an older core the launch is unchanged (#201).
- `matrix setup --force` keeps the existing `deny_room`/`deny_server` lines (#154).
- Matrix length caps never cut a UTF-8 character (#155).
- Matrix invite follow-ups: refusals carry a next step, the quarantine list shows the room, and commands missing a room say what to pass (#162).
- Future Matrix join timestamps are kept (#141).
- `remuda butler doctor` reports probe timeouts (#135).
- The `matrix setup` wizard asks for a Butler bot name when it cannot take one from this computer's name (a stock Mac), instead of stopping. The flag form's refusal now ends with a `Next:` line naming `--bot` (#182).
- The `matrix setup` wizard prompts no longer show a doubled colon such as `URL::` (#186).
- The `matrix setup` wizard shows its whole summary and the `Continue?` question before asking: the summary is printed above the prompt instead of being cut at 256 characters. This needs a core whose `prompt_line` takes a preface; older cores show the cut summary as before. A very long homeserver no longer pushes the registration-token prompt past one line (#186).
- Scheduled compaction of a Claude session already on Sonnet no longer types `/model` before or after `/compact`; a failed compaction keeps its 10-minute cooldown instead of retrying after a few minutes, and a `/compact` that was not submitted fails at once (#206).
- Scheduled compaction of a Claude session on Opus now waits for `/model sonnet` and the restore to be confirmed (status line or settings.json, dialog gone, empty composer) before typing the next command, so `/compact` is no longer lost behind the switch (#206).
