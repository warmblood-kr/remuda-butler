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

The current `extension.toml` is migration metadata for that contract. Runtime
resolver support still belongs in Remuda core/native.

## Compatibility

During migration, the installed distribution should preserve:

```text
remuda exec butler
remuda butler ...
```

The preferred end state is a `remuda-butler` executable using generic Remuda
IPC/eval, with `remuda butler` forwarding to it or to a manifest-declared
command. Butler must fail clearly when Remuda or the Butler package is absent;
it must not silently download or re-embed itself.

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

## Current blockers

This staging repository is a source distribution, not yet a standalone build:

1. Remuda needs a generic disk extension resolver and manifest/API-version
   contract.
2. The CLI shim needs a transport-only client or external command contract so
   it no longer imports `remuda-core`/`remuda-native` source crates.
3. Butler integration tests need to be split from shared daemon tests.
4. The path checker must receive an explicit core checkout or validate a
   published loader contract instead of opening removed core files.

See `BUTLER_MIGRATION.md` for the proposed sequence.
