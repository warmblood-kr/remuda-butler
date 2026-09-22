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

## Install

Install Remuda first, then install Butler as an extension:

```sh
curl -fsSL https://warmblood-kr.github.io/remuda/install.sh \
  | REMUDA_CHANNEL=nightly sh
remuda mod install warmblood-kr/remuda-butler
remuda exec butler
```

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

Every Butler-managed agent receives `REMUDA_BUTLER_AGENT_ID` and, when it has
one, `REMUDA_BUTLER_LEADER_ID`. Therefore agents normally use the short forms:

```sh
remuda butler inbox
remuda butler send reviewer "please check the latest patch"
remuda butler send-to-leader "review complete: no blockers"
```

The sender is inferred from the environment. `remuda butler send FROM TO
MESSAGE...` remains available for an operator who intentionally sends a note
on another session's behalf.

### Optional Matrix bridge

With Matrix credentials configured, Butler can bridge one room. The bridge is
optional and composes Remuda processes, hooks, sessions, and MCP rather than
introducing a separate runtime.

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
