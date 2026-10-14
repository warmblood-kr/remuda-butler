# Client configuration at agent start

Before starting a root or registered delegated Claude/Codex agent, Butler
initializes both clients' configuration in that session's actual working
directory:

- `.claude/settings.local.json`: merges `Bash(remuda:*)` and `mcp__remuda__*`
  into the allow list, preserving existing permissions, Skill entries and all
  other JSON settings. An identical deny or ask entry withholds that grant.
  More specific user restrictions remain present and are enforced by the client.
- `.codex/config.toml`: fills missing fields of the Remuda MCP server with
  `command="remuda"`, `args=["mcp"]`, environment variable names
  `REMUDA_SESSION_CAPABILITY` and `REMUDA_RUNTIME_DIR`, `enabled=true`, and
  `default_tools_approval_mode="approve"`. Existing fields, per-tool
  prompt/disable policy, user/server restrictions and other config stay intact.
- `.codex/rules/remuda.rules`: appends an attributable Butler block allowing
  the `remuda` executable prefix. Existing custom rules are retained byte for
  byte; their more restrictive decisions still take precedence. A modified or
  duplicated Butler block is preserved and reported rather than overwritten.

Withheld defaults (reported, never silently widened):

- Claude settings are not written when the working directory is below a
  repository root or is a worktree/submodule: Claude reads the root (or main
  checkout) settings, so a file here may be ignored, and the root is not
  written on the user's behalf. Native lookup was not exercised end to end.
- Codex `enabled` and `default_tools_approval_mode` are not inserted when
  `CODEX_HOME`, an ancestor `.codex/config.toml` mentions `remuda`, cannot be
  read, or the Codex home is unknown: a project layer outranks those.
- The legacy root permission writer leaves an unreadable settings file alone.

This broader scope follows the direct owner instruction in the coordinator's
API conversation: “and, I want to allow every remuda tasks, `remuda` cli execution,
or remuda mcp, no matter which tool in it.” It supersedes the earlier routine
coordination-only proposal. Client grants do not change managed automatic
review, sandbox settings, folder trust, daemon role restrictions, or the guards
on operations that need separate approval. Other executables and MCP servers
receive no grant. Explicit existing restrictions can still prevent an operation.

Root candidate specs and the shared member launch function initialize before
the agent's argv is built/spawned. Topic delegation with a supplied cwd uses
that cwd, and relaunches reuse this path. Claude and Codex receive the same
identity-free defaults, so different adapters sharing a workdir do not write
another session's identity. Monocle and other adapters are skipped. Repeated
launches leave unchanged files and their modification times alone; this is not
a reconciliation timer or a retrofit of already-running sessions.

The existing launcher MCP command/args and per-session capability overrides
remain authoritative. The generator never receives a token or session identity
and serializes only environment variable names. Existing inline capability
assignments are preserved with a cleanup diagnostic rather than copied into
validation fixtures or rewritten. The launcher's existing private bridge files
and in-memory flags are unchanged by this feature.

## Preservation and diagnostics

The merger plans and validates all three targets before writing any of them.
Unreadable files are not mistaken for missing files. Symlinks or uncertain link
checks refuse writes. A changed snapshot during validation aborts the merge.
Target writes use core private atomic writes; callbacks in one daemon serialize
shared-workdir merges. This is not a multi-process filesystem lock or a
three-file transaction: an I/O failure after a successful write may leave that
earlier file initialized, and the diagnostic states this. There remains a
check-to-write race against an external editor/link swap; core does not offer
an open-beneath/CAS transaction here. No stronger guarantee is claimed.

Claude JSON is decoded with core JSON and checked for permission shapes. Existing
TOML and rules use the installed Codex CLI's offline config/execpolicy parsers
in a freshly created, private temporary directory. These commands never start
an MCP server, and their output is not forwarded or logged because it may
contain user auth fields. Temporary directories are removed only if exclusive
creation succeeded. Without Codex, the exact literal fresh generated documents
remain supported; arbitrary existing/custom TOML/rules require Codex validation
and otherwise produce a diagnostic without target edits.

The TOML merge fills missing fields in the `[mcp_servers.remuda]` section
(including simple quoted components/keys) and preserves original text.
Escaped/dotted/inline representations that conflict with this conservative insertion are left unchanged after native
validation fails. Existing explicit settings are never silently overwritten to
force the default policy. Trace events `coordination_config_not_written` and
`coordination_config_written` record safe outcomes. Doctor identifies missing,
blocked, or initialized root defaults using a clearly labeled launch-time
report; it does not claim that user/managed restrictions allow every operation.

## Activation and validation

This source patch does not change installed modules or any running workdir.
An owner-controlled installation/activation is still required. It affects future
actual starts, not an already-running root adopted on activation. Existing
clients may need a restart/new session to load local configuration, and this
feature does not trigger one. The separately rejected live HOME patch remains
unapplied; there is no workaround through this local implementation.

```sh
REMUDA_BIN=/private/tmp/remuda-notify-policy/target/release/remuda bash tests/butler_coordination_config.sh
REMUDA_BIN=/private/tmp/remuda-notify-policy/target/release/remuda bash tests/lua_tests.sh tests/lua/butler_coordination_launch_test.lua
luajit tests/butler_permissions.lua
luajit tests/butler_approve_text_syntax.lua
```

Fixture coverage includes both clients/adapters, separate and shared actual
workdirs, root fallback specs, registered member starts/relaunches and delegated
cwd overrides; capability non-persistence; repeats and custom settings;
deny/prompt precedence; malformed JSON/TOML/rules; unreadability/link rejection;
and exclusive temporary-directory cleanup. Spawn-boundary stubs stop before
starting any real agent. The native parser uses installed Codex; tests require
that executable even though fresh runtime defaults can be generated without it.

Codex keys were verified against the
[official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
