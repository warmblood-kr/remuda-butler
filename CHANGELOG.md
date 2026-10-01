# Changelog

All notable user-facing changes to Remuda Butler. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Butler has no
release tags yet; entries come from merged pull requests.

## Unreleased

### Added
- When the Butler cannot start any agent (not logged in, stopped at a dialog, not ready in time, exited, not installed), the owner gets one notice in the Matrix HOME room with the reason and the next command for each agent. It is sent once per failure, not on every retry, and never includes screen text.
- `remuda butler matrix setup` with no flags runs guided prompts (#127). The wizard always opens rooms and does not ask about room access (#145).
- Matrix open-room mode: anyone may invite the Butler, subject to `deny_room`/`deny_server` rules and a daily join cap (#136).
- Matrix join and leave accept a room alias or a public room name; public rooms can be browsed (#123).
- When an agent asks to join a Matrix room, the owner is asked in HOME (#138).
- `remuda butler doctor` checks agent CLIs and logins and prints the next command (#128).
- `remuda butler close NAME` lets a leader close its own members (#149).
- After a compaction or restart, a member is shown the last unanswered leader message again; `remuda butler inbox` shows message IDs (#159).
- `remuda butler matrix follow EVENT_ID` and `unfollow EVENT_ID` manage thread replies. HOME always delivers replies; other rooms deliver a reply only in a followed thread or on a mention. Replying, sending, and a mention from an allowlisted sender follow the thread automatically (#178).
- `remuda butler matrix send -` reads the message from stdin, up to 64 KiB (#170).
- Outgoing Matrix messages carry a formatted HTML body rendered from a Markdown subset; raw HTML is always escaped (#171).

### Changed
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

### Fixed
- `matrix setup --force` keeps the existing `deny_room`/`deny_server` lines (#154).
- Matrix length caps never cut a UTF-8 character (#155).
- Matrix invite follow-ups: refusals carry a next step, the quarantine list shows the room, and commands missing a room say what to pass (#162).
- Future Matrix join timestamps are kept (#141).
- `remuda butler doctor` reports probe timeouts (#135).
- The `matrix setup` wizard asks for a Butler bot name when it cannot take one from this computer's name (a stock Mac), instead of stopping. The flag form's refusal now ends with a `Next:` line naming `--bot` (#182).
- The `matrix setup` wizard prompts no longer show a doubled colon such as `URL::` (#186).
