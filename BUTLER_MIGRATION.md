# Remuda Butler migration boundary

This directory is the local staging repository for the planned `remuda-butler`
repository. It was copied from Remuda commit `93e9c28` and curated to retain
the Butler distribution sources, CLI/installer assets, tests, and migration
metadata without changing the source clone at `../clone-remuda`.

## What belongs here

The Butler distribution is the following package and its command/persistence
surfaces:

- `packages/butler/` — the Lua entry package, mail and telemetry modules, and
  Claude/Codex agent adapters.
- `cli/butler_cli.rs` — the current Butler command parser and
  IPC/eval shim; this should become the `remuda-butler` CLI in the extracted
  repository.
- `install/install-butler.sh` — token/config validation, daemon bootstrap,
  `init.lua` loader, poller, and systemd/launchd persistence setup.
- `docs/butler.md` — user and behavior documentation.
- Butler-focused integration coverage in `tests/butler_daemon.rs`, including
  package loading, Matrix helper, mail, telemetry, agent, topic, and recovery
  tests. These tests should be split into focused Butler tests during the
  extraction; the non-Butler daemon tests remain in Remuda core.
- `scripts/check-butler-path-convention.py` — currently cross-checks Butler
  installer paths against the package and daemon loader. It should move here
  with its core-side check reduced to a documented compatibility contract.

The staging tree intentionally does not contain Remuda's core/native source,
Cargo workspace, general CI, or unrelated design/step documents. The retained
CLI and test source are migration inputs and still have references to the
removed workspace; they are not yet standalone build targets. No source files
in `clone-remuda` were modified, deleted, or committed by this staging step.

## Dependencies on Remuda

Butler is a trusted Lua extension, not a replacement daemon. It requires a
running Remuda daemon and the generic Lua/runtime surface supplied by
`remuda-native`, backed by the policy and wire types in `remuda-core`.

The current package uses `remuda.new`, `send`, `close`, `ls`, `capture`,
`process`, `schedule`, `on`, `emit`, `tool`, `exec`, directory operations, and
MCP. Its `_butler_*` names are package-owned state and should become an
explicitly versioned Butler API rather than native Remuda implementation
details.

The core repository must retain:

- `core/` and `native/` crates, including the daemon, IPC protocol, Lua image,
  process/PTY support, and generic script bindings;
- a generic package/extension resolver and disk package contract, so Butler can
  be installed after Remuda and upgraded independently;
- generic `remuda exec`/`remuda <extension>` dispatch or an equivalent external
  command handoff;
- daemon user-config loading at `XDG_CONFIG_HOME/remuda/init.lua`, unless the
  extension activation mechanism replaces it compatibly;
- the stable session, process, schedule, hook, filesystem, and MCP APIs used by
  Butler;
- core release/install machinery for the `remuda` binary only.

## Compatibility expectations

For the transition, an installed Butler must continue to support:

```text
remuda exec butler
remuda butler ...
```

The preferred independent implementation is a `remuda-butler` executable that
uses generic Remuda IPC/eval. Remuda may retain a compatibility dispatch for
`remuda butler`, forwarding to that executable or to a manifest-declared
extension command. The dispatch must give a clear error when Butler is not
installed, and must not silently re-embed or auto-download Butler.

An extension manifest should declare its name, entry file, compatibility/API
version, and optional command executable. Resolution needs deterministic
precedence (installed package versus temporary compatibility fallback), and
loading/upgrading needs a daemon restart or explicit reload rule because the
Lua image persists for the daemon lifetime.

## Migration sequence

1. Define and test the generic extension manifest, resolver, install location,
   precedence, and API-version error messages in Remuda core.
2. Extract the Butler Lua tree and CLI into this repository; replace direct
   package-table assumptions with the resolver contract.
3. Split Butler integration tests from `native/tests/daemon.rs` and keep core
   tests for missing/unknown extensions and compatibility dispatch.
4. Give Butler its own release workflow, checksums, installer, version index,
   and documentation. Install package, manifest, and CLI atomically.
5. Release a compatibility period with the embedded Butler fallback, then
   remove that fallback only after the independent installer and dispatch have
   been exercised on each supported platform.

No GitHub repository was created and no remote was changed by this staging
operation.
