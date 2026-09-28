# Butler

Butler is Remuda's local session manager. It starts and coordinates one agent
session through the same Lua runtime and Remuda protocol used by other
extensions. It works without Matrix configuration.

When Matrix credentials are configured, Butler can bridge one room: inbound
messages arrive through a small sync process and replies use the Butler MCP
tool. The bridge composes existing Remuda primitives; it does not add a
separate runtime or extension catalog.

Butler topics use stable session names and are delivered through the Butler
message queue. The extraction boundary, runtime dependencies, and migration
plan are maintained in the repository's
[`BUTLER_MIGRATION.md`](https://github.com/warmblood-kr/remuda-butler/blob/main/BUTLER_MIGRATION.md).

At startup, Butler tries registered agent kinds in order and waits for each
agent's idle prompt before selecting it. The default order is Claude, then
Codex; set `REMUDA_BUTLER_AGENT_ORDER=codex,claude` to change it. This order
also applies to delegates without an explicit kind. `remuda butler sessions`
shows the selected kind and the reason each earlier candidate was skipped.

`remuda butler status` prints `butler: up (<kind>)` and exits 0 when the root
Butler is ready. During launch it exits 1 with output beginning `launching`;
after failure it exits 1 with output beginning `failed`. Both states include
one line per attempted candidate. The install script can poll this command
until it reports `up` or `failed`.
