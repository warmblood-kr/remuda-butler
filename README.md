# remuda-butler

Standalone Butler distribution for Remuda. Butler is a trusted Lua extension
and coordination CLI; it is not a second daemon and does not contain Remuda's
PTY, IPC, terminal, or session implementation.

This is the independent Butler extension repository. The migration boundary
from the original embedded package is documented in `BUTLER_MIGRATION.md`.

## Cascading spawn

![A terminal session tree: butler has spawned a lead session, which has in
turn spawned several of its own worker sessions, shown nested in the
sidebar](docs/remuda-cascading-spawn.png)

The butler spawns a lead; a worker can spawn its own workers (cascading).

## Runtime dependency

Install Remuda core/native first. Core `0.1.0-nightly.20261001000710.0a5f090`
introduced the lifecycle `start` hook (warmblood-kr/remuda#104)
that boots Butler right after activation. An older core ignores `start`; Butler
then boots by a one-shot fallback on the next tick and writes `booted by
fallback -- run \`remuda upgrade\`` to the daemon log (`tests/old_core_boot.sh`).

Identity-sensitive CLI commands also require daemon-supplied caller kind and
session fields, matched to one live Butler registration. Older cores without
those fields refuse these commands; upgrade core or use the MCP tools with the
session's configured capability. Environment variables never select CLI identity.
Caller attribution is advisory, **not an isolation boundary**. See
[Caller identity](docs/butler.md#caller-identity); CI's core pin is in
`tests/core_ref.sh`.

The Butler CLI requires core `remuda.cli.parse`, introduced by
warmblood-kr/remuda#465 (2026-10-02). Upgrade Remuda before using
`remuda butler` on an older core.

Shared-parser syntax changes: put `reply --file PATH` and
`reply --attach PATH` before the message ID; use `send --from SENDER TO` to
set an explicit sender and put `send --file PATH TO` to read a body from a
file; the former positional `send FROM TO ...` form was ambiguous with a
multiword message and is removed. Use `inbox -- -NAME` for a name beginning
with a dash. `compact` accepts its options around the session argument; malformed
options are reported before session lookup, and `--` must precede a session name
that begins with a dash. `launch` and both `topic`
subcommands now reject missing or extra arguments with parser usage, and
`--help`/`-h` show each command's declared options and examples. Normal `--help`
and `-h` now show parser-generated command usage.

Butler requires a running `remuda` daemon and
the generic Lua/runtime APIs supplied by `remuda-native`, with protocol and
session policy from `remuda-core`. The package uses sessions, process helpers,
schedules, hooks/events, filesystem helpers, tools, and MCP.

The intended independent installation layout is a Remuda extension directory,
for example:

```text
$XDG_DATA_HOME/remuda/extensions/butler/
  extension.toml
  packages/butler/init.lua
  packages/butler/mail.lua
  packages/butler/telemetry.lua
  packages/butler/agents/*.lua
```

The `extension.toml` manifest is the installation contract. Remuda resolves it
from disk; Butler is never compiled into the Remuda executable.

## Compatibility

The installed distribution preserves:

```text
remuda exec butler
remuda butler ...
```

The manifest declares `command = "butler"`. `remuda butler` loads the
extension, while `remuda butler ...` dispatches to its Lua command handler.
Butler fails clearly when it has not been installed; it does not silently
download or re-embed itself.

The current CLI source is retained at `cli/butler_cli.rs` as a migration input.
It still imports Remuda workspace crates and is not independently buildable
until the generic external CLI/client contract is implemented in Remuda core.

## Contents

- `packages/butler/`: Butler core, mail, telemetry, and agent adapters.
- `packages/butler/matrix.lua`, `matrix_request.lua`, `matrix_read.lua`,
  `matrix_write.lua`, and `matrix_relay.lua`: the Matrix relay and command
  composites. See the [Matrix command and configuration
  reference](docs/butler.md#matrix-commands-and-configuration).
- `cli/butler_cli.rs`: current Butler command shim to extract into a standalone
  CLI.
- `install/install-butler.sh`: config validation, bootstrap, loader, and
  systemd/launchd persistence setup.
- `docs/butler.md`: Butler behavior and configuration documentation.
- `tests/butler_daemon.rs`, `tests/butler_mcp.rs` and `tests/support/`: Butler's
  Rust integration tests. `tests/rust_tests.sh` builds them inside a pinned
  Remuda core checkout and runs the Butler ones; CI runs it on every PR.
- `scripts/check-butler-path-convention.lua`: path consistency check spanning
  the Butler installer and the Remuda daemon loader.
- `scripts/check-no-python.sh`: CI guard for Python files and invocations;
  its Matrix and statusLine exceptions have explicit ownership TODOs.
- `BUTLER_MIGRATION.md`: boundary, retained core responsibilities, risks, and
  extraction sequence.

## Install

```sh
remuda mod install warmblood-kr/remuda-butler
remuda butler --agent codex
```

`remuda mod update butler` updates the installed extension on disk. To apply
an update to the running daemon immediately, use
`remuda mod update butler --reload`. After editing the installed Butler files
directly, run `remuda -e "remuda.reload('butler')"`. With a core supporting
source refresh, development commands can use
`REMUDA_RELOAD_SOURCE=1 remuda butler COMMAND`: before dispatch, core compares
already loaded entry/helper source and reloads changed lifecycle code. This is
opt-in and applies on the next command, without restarting the daemon. A failed
refresh fails the command visibly; corrected source is retried. Use this during
idle development. Butler defers refresh visibly while launch choosers, startup,
mail delivery, managed dialogs, approvals, or its Matrix relay are active; retry
when idle. If the active version predates the guard, refresh refuses and asks
for one explicit reload when idle to enable guarded refresh. An explicit reload
remains a deliberate lifecycle replacement.
There is no background file watcher. Ordinary edits and updates without either
opt-in refresh or `--reload` leave the running Lua image unchanged. Reload requires the
lifecycle-managed Butler module; `remuda exec butler` does not re-run an active
module.

`remuda butler --agent claude|codex` selects the root Butler agent without an
environment variable. Add `--headless` when only the service should start.

## Testing

New Butler behavior tests belong in `tests/lua/`. Keep Rust tests for core
primitives and the wire protocol. Run all Lua tests or one file with
`REMUDA_BIN=<pinned remuda> tests/lua_tests.sh [tests/lua/file_test.lua]`.
All interactive Butler CLI verbs use `remuda.cli.parse`; the no-argument guard
hook is a stdin protocol. The parser ratchet in `tests/hand_parsed_verbs.sh`
prevents adding hand-parsed verbs.

The harness uses private daemon names `h<pid>` and `h<pid>c`, private HOME,
XDG, and runtime directories, and never targets the default daemon. Teardown
reports `left: 0`. Keep `tests/lib/harness.lua` free of `os.execute` and
`io.popen`.
Test files can set `T.child_env = { PWD = "/path/" }` before startup to customize the child daemon environment.
