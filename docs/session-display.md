# Cluster session display

Butler can publish a small set of session facts for the local cluster tree and
authenticated remote session lists. This needs the companion Remuda session
display API (stacked on core PR #884), plus an upgraded viewer. Older cores and
peers keep their ordinary session list.

In the publishing node's trusted config, before loading Butler:

```lua
remuda._butler_publish_session_display = true
```

The default is off. Enabling shares the verified leader relationship, agent kind,
configured model and available fresh numeric context usage with every peer
already authorized to list this node. Session names are preserved. Tasks,
prompts, mail, commands, paths, sandbox details, credentials and terminal contents
are excluded. No remote Eval is used.

Each two-second tick publishes only agents bound to an exact current session
instance. A leader alias requires a matching durable parent identity. The core
independently validates the instance and typed bounded fields. Publication lasts
at most ten seconds without renewal. Disabling clears on the next tick; cached
remote values can last only until their original deadline. Module stop clears
publications, and daemon image disposal invalidates the publication generation.

Model selection configured at launch can be shown without telemetry. Observed
model and context require an observation record bound to the exact status
payload. The Claude statusline and upgraded Codex observer produce this private
record. Claude records additionally bind the exact session instance, including when
reusing a root status path; Codex launches allocate a fresh path. An older observer or missing/invalid record yields omitted telemetry,
not guessed values. Samples younger than 60 seconds can be published; the core
TTL can extend visibility by up to ten seconds. Other adapters need an explicit
fresh observation source before their usage is shared.

Freshness uses a wall-time origin followed by monotonic elapsed time, so wall
clock rollback and replay cannot revive samples while Butler remains loaded.
After image restart, freshness again depends on the initial local wall clock;
a rollback spanning restart cannot be proven from these files. Future or
uncertain observations are omitted. No telemetry is persisted by this publisher.

The default frontend shows optional `← leader · kind · model · 42% ctx` after
the session name. Sessions remain grouped by node; the arrow is an optional
leader annotation and does not change navigation or grouping. Missing or expired
fields are omitted. Operational liveness,
node reachability and input status remain independent. A frontend document can
override `decorate_session(session, spans)` without access to private routes.

Run the pure publisher regression test with:

```sh
luajit tests/session_display.lua
```
