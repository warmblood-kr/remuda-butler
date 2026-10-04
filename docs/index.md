---
layout: default
title: remuda-butler
---

# remuda-butler

Butler is Remuda's coordination extension for coding-agent sessions. It
provides a local service session, agent topics, durable messages, and an
optional Matrix bridge while relying on Remuda for the daemon, Lua runtime,
sessions, and MCP transport.

[Install Butler](#install) · [Read the migration notes](https://github.com/warmblood-kr/remuda-butler/blob/main/BUTLER_MIGRATION.md) ·
[View the source on GitHub](https://github.com/warmblood-kr/remuda-butler)

## Cascading spawn

![A terminal session tree: butler has spawned a lead session, which has in
turn spawned several of its own worker sessions, shown nested in the
sidebar](remuda-cascading-spawn.png)

The butler spawns a lead; a worker can spawn its own workers (cascading).

## Install

Install Remuda first, then install Butler as an extension:

```sh
curl -fsSL https://warmblood-kr.github.io/remuda/install.sh \
  | REMUDA_CHANNEL=nightly sh
remuda mod install warmblood-kr/remuda-butler
remuda exec butler
```

Run `remuda butler doctor` to check that Claude Code and Codex CLI are installed and signed in.

The launch command returns while readiness is still being checked. Use
`remuda butler status` to inspect the result: exit 0 means ready, exit 75 means
the readiness chain is still running, and exit 1 means every candidate failed.

The installer also supports the optional service setup:

```sh
curl -fsSL https://warmblood-kr.github.io/remuda/install-butler.sh | sh
```

The extension is loaded into the running Remuda daemon. It does not start a
second daemon or bundle Remuda's PTY, IPC, terminal, or session implementation.

## What Butler provides

### One service session

Butler starts and coordinates one service session through Remuda. Agent
sessions remain ordinary Remuda sessions, so the same CLI, Lua, and MCP
surfaces can inspect and control them.

### Topics and messages

Topics provide stable workspaces for delegating tasks. Messages are queued in
durable inboxes and carry explicit sender, recipient, and message identifiers.
The CLI remains the coordination boundary:

```sh
remuda butler sessions
remuda butler topic new docgen
remuda butler topic delegate docgen "build the documentation site"
remuda butler inbox
remuda butler send-to-leader "work is complete"
```

`launch`, `topic new`, and `topic delegate` take `--model M` to pick the
member's model (e.g. `remuda butler topic delegate docgen --agent codex
--model gpt-5.5 "build the documentation site"`). Claude members use the
explicit `opus` default when no model is assigned; set
`REMUDA_BUTLER_CLAUDE_DEFAULT_MODEL` to choose another Butler default. Claude's native
autocompact safety net defaults to `600k`; set
`REMUDA_BUTLER_CLAUDE_AUTOCOMPACT` to `auto` or a threshold such as `400k`.
The Butler scheduler remains the primary compaction path. The MCP
`butler_launch` and `butler_delegate` tools take `model`.

Codex members get extra writable directories with `--writable DIR` (repeatable,
absolute and existing; on `launch` and `topic delegate`; the MCP tools take
`writable`). `--sandbox full` removes the sandbox and is accepted only from a
person at a terminal, never from a Butler agent. `--writable` refuses `/`, the
home directory and its ancestors, and any directory that is, contains or lies
inside `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.codex`, `~/.claude` or Butler's
config, data and runtime directories; only `--sandbox full` grants those. The
profile is kept for relaunches and shown by `remuda butler sessions`. The
`--sandbox full` check covers every Butler entry point (CLI, MCP tools, the
launcher and relaunch). It is not a boundary against an agent that can run
Lua through `run_script`, which runs as the daemon.

Every Butler-managed agent receives `REMUDA_BUTLER_AGENT_ID` and, when it has
one, `REMUDA_BUTLER_LEADER_ID`. Therefore agents normally use the short forms:

```sh
remuda butler inbox
remuda butler send reviewer "please check the latest patch"
remuda butler send-to-leader "review complete: no blockers"
```

The sender is inferred from the calling shell's environment; quote the
message for `send`, since `remuda butler send FROM TO MESSAGE...` (what an
unquoted multi-word message parses as) is the operator form for sending a note on another
session's behalf. The short forms need a Remuda core that forwards the caller's
`REMUDA_*` variables to mod commands (warmblood-kr/remuda#95); on an older
core, pass the name explicitly (`remuda butler inbox "$REMUDA_BUTLER_AGENT_ID"`)
or use the MCP `butler_*` tools.

### Optional Matrix bridge

With Matrix credentials configured, Butler can bridge one room. The bridge is
optional and composes Remuda processes, hooks, sessions, and MCP rather than
introducing a separate runtime.

### Guard audit

`remuda butler guard on|off|status` switches an audit of what Claude members do;
it is off by default and may be switched by Butler and leaders. While it is on,
the per-session settings file of each Claude member launched from then on gets
`PreToolUse` and `PermissionRequest` hooks that call `remuda butler guard`.
Each call appends one JSON line (time, session, agent kind, event, tool,
class, a redacted and size-capped summary) to `guard-audit.jsonl` in Butler's
data directory (mode 0600, rotated at 1 MiB). The class is one of `push`,
`destroy`, `escape`, `net`, `control`, `weaken`, `identity`, `script` or `other`,
chosen by a fixed classifier over the tool name and arguments (`other` means "not recognised", not "harmless": wrapped commands such as `bash -c` are not unpacked); `run_script` calls
are logged with their size and first 120 characters. With only audit on, the
hook never blocks or asks and fails open: if the daemon or the log is unavailable
the agent proceeds as before. `remuda butler doctor` shows the switch. The audit
is a record, not a security boundary: agents run as the same user and can bypass
or edit it.

Every audit line carries a `grant_id` field, `-` until standing grants exist.
When grants land, `grant_id` comes from the grant store, never from agent input.
Each change of the `guard`, `guard deny` or `guard approvals` switch appends a
`switch` line naming who changed it (the caller's alias, or `operator`) and when.
`Who` is evidence from the forwarded environment, not a control; the `weaken`-class deny is the control.
Turning a switch off is audited first. If that line cannot be written the switch still turns off (it only narrows enforcement, so the owner is never locked out), the answer and stderr say "switched off, NOT audited", and a `guard-unaudited` marker shows in `guard status` and `guard stats` until the next audit line is written.
When the log passes 1 MiB, the previous `guard-audit.jsonl.1` moves to a
`guard-audit.jsonl.<UTC stamp>` archive, and archives older than 90 days are
deleted at that moment and never otherwise.
Two rotations in one second keep both archives (a `-N` suffix).
`remuda butler guard stats` prints the line count, the first and last time, and
the counts per class and per event over the log and its archives, bucketing names it does not know as `other` and counting oversized or unreadable lines as unreadable, as a baseline
to compare before enabling `guard deny`.

### Guard approvals

`remuda butler guard approvals on|off|status` is a second switch, off by
default and independent of `guard on|off`; routing runs only while both are on,
for Claude members launched after the switch. The `PermissionRequest` hook of
such a member registers each permission prompt as an approval request (id,
stored redacted summary, class, a sha256 of the request text) and posts one
message to the owner's Matrix HOME room. The verified owner answers it as for
`approve-text`: reply `yes` or `no` (also `승인`/`거부`) to that post, or react ✅ or
❌ to it. Only an allowlisted human in HOME on a live sync counts; an edit, a
reaction on another post or an unknown id does nothing, and a terminal cannot
approve (it may deny). An answer applies once, to that request, while the
member's hook waits; the hook then prints Claude's allow or deny decision.
Only `Bash`, `Read`, `Glob`, `Grep`, `WebFetch` and `WebSearch` calls are routed,
because the post shows their whole action; `Write`, `Edit` and other tools keep
Claude's own prompt. A command longer than 1000 bytes, a `run_script` call, a cap
(5 open requests per session, 20 in all) or a missing or failing Matrix
setup is not routed either. A call whose text redaction would change (a command with a token, password or URL credential) keeps Claude's own prompt, so the owner approves exactly what would run. A command with a control character (newline, carriage return, NUL, tab) is not routed either. Open-request caps count one kind of approval at a time. Pending requests are stored, and a restart expires them.

Every other outcome prints no decision, so Claude shows its own prompt: this
slice only adds a way for the owner to answer prompts the agent already raises,
and never allows something the member could not do before. A request expires
after about 5 minutes (the longest wait core allows a hook), which is
"no decision", not "deny"; a late answer is told "Expired." in the thread. The
owner sees the redacted command or path, not other tool input such as file
contents. Requests, answers and expiries are appended to the guard audit
(`approval_requested`, `approval_approved`, `approval_denied`, `approval_expired`).
Codex and Monocle members are not routed. This is a cooperative guardrail, not a
boundary: a member that goes through `run_script`, edits its own settings or
runs outside the hook is not covered.

### Guard deny

`remuda butler guard deny on|off|status` is a separate switch, off by default.
Denials run only while both `guard on` and `guard deny on` are set. For Claude
members launched after both switches are on, the `PreToolUse` hook denies
recognised permission bypass flags, owner-only Butler controls, daemon
stop/restart/kill commands, writes to hook/settings files, the home-level
`~/.codex/AGENTS.md` and `~/.claude/CLAUDE.md`, or protected directories, and force or delete pushes that name `main`, `master` or `trunk`.
Agents are also denied `remuda butler guard deny status`. Plain pushes and force
pushes to other branches remain allowed. `doctor` shows the deny switch.

The test harness can stop or restart its private daemon with `-s hNNN` (an `h`
followed by digits, optionally followed by `c`). This exception applies only
when every server selector names such a harness daemon and no other daemon
selector is present; other daemon stop/restart/kill commands are denied.

This is a cooperative guardrail. `run_script` calls and edits to a member's own
settings outside the hook can bypass it. The hook scans command text
lexically, including `sh`, `bash`, `zsh`, `dash`, `ksh` and `ash` `-c` bodies,
`eval` bodies, and `find -exec`/`-execdir` bodies. It does not unwrap `ssh`,
`su -c`, `script -c`, `setsid`, `stdbuf`, `ionice` or `busybox`; it also cannot
resolve `$var` command indirection or commands piped into `sh`. For payloads
over 64 KiB, it checks the tool name, file path, and at most the first 4 KiB of
a command. Protected roots are anchored to the user's home and active Butler
data directory. The user's `.claude` and `.codex` directories are not protected
wholesale; only hook/settings files there are protected, so auto-memory and
plans remain writable. Without an explicit
refspec, the hook cannot infer the current branch, so a force push with an
implied target is not denied. Writer detection covers redirects and the
lexical writers `rm`, `mv`, `cp` destinations, `tee`, `dd` output, `chmod`,
`chown`, `ln`, `touch`, `truncate`, `install` destinations, and `sed -i`.
`perl -pi`, interpreter one-liners, `rsync`, `curl -o`, and `patch` are not covered. If the
hook fails before it builds a decision, it fails open and prints no decision;
an audit append failure does not change a built denial.

## Compatibility

The extension declares the API it uses in
[`extension.toml`](https://github.com/warmblood-kr/remuda-butler/blob/main/extension.toml):

```toml
api = "remuda-lua-v1"
```

The current repository is the independent Butler distribution and migration
boundary. Runtime resolver support belongs to Remuda; standalone CLI and test
extraction work is tracked in
[`BUTLER_MIGRATION.md`](https://github.com/warmblood-kr/remuda-butler/blob/main/BUTLER_MIGRATION.md).

## Documentation

- [Butler behavior and configuration](butler.md)
- [Migration boundary and remaining work](../BUTLER_MIGRATION.md)
- [Remuda documentation](https://warmblood-kr.github.io/remuda/)
