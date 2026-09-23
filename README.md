# remuda-butler

Standalone Butler distribution for Remuda. Butler is a trusted Lua extension
and coordination CLI; it is not a second daemon and does not contain Remuda's
PTY, IPC, terminal, or session implementation.

This is the independent Butler extension repository. The migration boundary
from the original embedded package is documented in `BUTLER_MIGRATION.md`.

## Runtime dependency

Install Remuda core/native first. Butler requires a running `remuda` daemon and
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

- `packages/butler/`: Lua package, mail, telemetry, and agent adapters.
- `cli/butler_cli.rs`: current Butler command shim to extract into a standalone
  CLI.
- `install/install-butler.sh`: config validation, bootstrap, loader, and
  systemd/launchd persistence setup.
- `docs/butler.md`: Butler behavior and configuration documentation.
- `tests/butler_daemon.rs` and `tests/support/`: Butler integration-test source
  retained from the original daemon test while it is split into standalone
  tests. It still contains shared daemon-test helpers and is a known migration
  blocker, not a claim of standalone compilation.
- `scripts/check-butler-path-convention.py`: path consistency check spanning
  the Butler installer and the Remuda daemon loader.
- `BUTLER_MIGRATION.md`: boundary, retained core responsibilities, risks, and
  extraction sequence.

## Install

```sh
remuda mod install warmblood-kr/remuda-butler
remuda butler --agent codex
```

`remuda mod update butler` updates the installed extension. An already-running
daemon keeps its current Lua image until `remuda butler` is run again or the
daemon is restarted.

`remuda butler --agent claude|codex` selects the root Butler agent without an
environment variable. Add `--headless` when only the service should start.

### One-line install

For a fresh machine, this composes the core install with mod install, a
daemon restart to load the new mod, and a butler launch:

```sh
curl -fsSL https://warmblood-kr.github.io/remuda/install.sh | REMUDA_CHANNEL=nightly sh && ~/.local/bin/remuda mod install warmblood-kr/remuda-butler && ~/.local/bin/remuda stop -f && ~/.local/bin/remuda exec butler
```

Verified end-to-end in a fresh container: it gets you `remuda` installed, the
`butler` mod installed, and a daemon that has attempted to launch butler. It
does not by itself produce a working Matrix-bridged session. In a bare
container the daemon's reconcile loop fails even before reaching Matrix
setup, because it tries to spawn a `claude` CLI as the underlying agent
process and retries continuously once that's missing; a real colleague's
machine, which already runs a coding-agent CLI, gets past that point. Beyond
it lies the Matrix `REMUDA_BUTLER_TOKEN`/`REMUDA_BUTLER_CONFIG` requirement,
which this line intentionally leaves unset — see
[`docs/butler.md`](docs/butler.md) for Matrix bridging configuration.
