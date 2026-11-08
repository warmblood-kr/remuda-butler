# Shared cluster guidance

Decision for remuda-butler#609: the generated `guidance-layers` block explains
the cluster-shared Remuda VFS file, so every agent surface gets the same rule.

## Facts

- The one stable location is `remuda:///butler/guidance/cluster.md`
  (`guidance_layers.CLUSTER_URI`). Do not add a second path or verb.
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

- Present the URI unconditionally: a status line may omit it
  (`unavailable`), so the paragraph must still name it and tell the agent to
  use it for cluster-shared guidance.
- Give the loader's refresh points (session start, relaunch, pre-compaction),
  the 8 KiB cap, and the layer order.
- Missing, empty, too large or unavailable: continue with the loaded layers,
  report the gap when it matters, never invent or auto-create shared rules.
  Do not infer contents from a failed read or unavailable status; an empty
  layer is reported as empty.
- The URI is a cluster location, not a local filesystem path. A text containing
  `remuda-butler:managed id=` is withheld by `sanitize`, so the shared file must
  not contain a managed marker.
- Inspection is for a task that needs the source; it never bypasses a rejected
  status, and a newer file is never applied over the block.
- Publish only on an explicit owner or leader request, via
  `remuda vfs put FILE remuda:///butler/guidance/cluster.md`. A put does not
  guarantee every peer has synced it or that running sessions refreshed their
  snapshot.
