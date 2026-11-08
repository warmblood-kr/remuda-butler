# Shared cluster guidance

Decision for remuda-butler#609: the generated `guidance-layers` block explains
the cluster-shared Remuda VFS, separating the automatic loader from the shared
guidance index agents read themselves.

## Facts

- The automatic loader reads the one stable layer file
  `remuda:///butler/guidance/cluster.md` (`guidance_layers.CLUSTER_URI`). Keep
  that URI and the loader precedence.
- The owner's entrypoint is `remuda:///remuda-guidance/index.md`: a shared
  index agents read with `remuda vfs get` when a task needs cluster rules
  beyond the loaded snapshot. It is not a layer and is not loaded
  automatically.
- `guidance_layers.cluster_from_vfs` reads only this node's stat/read and never
  the network. It reports `loaded`, `missing`, `empty`, `too-large` or
  `unavailable` (no store, no cluster identity, version not copied here,
  read error). It never fails a launch.
- Layer order is fixed: framework, cluster, team, personal, local; a later
  layer adds to or overrides an earlier one.
- `remuda vfs get URI` (no `cat`) prints the file and may ask other nodes;
  `--local` keeps it to this node's copy. `remuda vfs put FILE URI` writes one
  node's version and cannot promise every peer or running session has it.
- The instruction text lives in `guidance_layers.render`, not in the framework
  sections of `init.lua`/`agents_launch.lua`/`main.lua`. The block reaches the
  root, members and the welcome mail, and changing it preserves framework
  hashes and parity.

## Wording rules

- Present both URIs unconditionally: a status line may omit the loader URI
  (`unavailable`), and the index is separately maintained.
- State the distinction plainly: the loader runs automatically at session
  start, relaunch and pre-compaction (8 KiB cap, fixed order); the index is not
  loaded automatically and the agent reads it with `remuda vfs get`.
- Missing, empty, too large or unavailable: continue with the loaded layers,
  report the gap when it matters, never invent or auto-create shared rules.
  Do not infer contents from a failed read or unavailable status; an empty
  layer is reported as empty. A missing, unreadable or unavailable index means
  the agent continues and reports the gap; it never turns into an existence,
  contents or sync claim.
- A cluster URI is not a local filesystem path. A text containing
  `remuda-butler:managed id=` is withheld by `sanitize`, so shared files must
  not contain a managed marker.
- Reading the index or the loader source never bypasses a rejected status, and
  a newer or rejected file is never applied over the block.
- Publish only on an explicit owner or leader request, via `remuda vfs put
  FILE` to the index or the path it names, or to the loader file. A put does
  not guarantee every peer has synced it or that running sessions refreshed
  their snapshot.
