# Durable lifecycle audit: next reviewed stage

The current diagnostics slice is a 200-event memory ring, not an audit trail.
No production persistence or configuration changes are included. The owner
also requested approval requests and session spawn/close as durable audit
records; stage this separately from the read-only viewer and reviewed fixes.

## Existing evidence and reuse

`guard_policy.lua` already appends `guard-audit.jsonl` with UTC time, IDs,
action, instance generation, rotation and a best-effort hash chain. It checks
write, flush and close, makes the live file private with `write_atomic`, and
uses an advisory lock. Its timeout falls back to unlocked append; the hash
chain can fork and is not an integrity/security boundary. No fsync guarantee.
Default retention: 1 MiB live file, at most 16 archives, age budget 90 days;
archive pruning occurs during appends/rotation. Earlier count eviction wins.
`guard_approval.lua` already records some approval requested/answered actions.
Reuse this writer rather than adding another log/transport, after reviewing
schema, contention and producer coverage. Do not expose legacy tool/summary
fields: they may contain redacted fragments of commands or other content.

`approval.lua` holds current approval status via the Matrix relay's existing
`.since` state file, written through `fs.write_atomic(...,{private=true})`.
This is recovery state, not a history: retain it as the authority for whether
an approval is pending. Inbox logs likewise remain mail recovery evidence,
not a general lifecycle journal. Reading the audit must not drain an inbox.

## Smallest next implementation

Add one strict lifecycle projection to the existing audit writer: schema
version, UTC time, stable event ID, approval/request ID where applicable,
actor kind and stable actor ID from verified caller attribution, target stable
ID + instance generation, phase, fixed action/outcome/reason, optional previous
transition/event ID. Use bounded fixed strings/opaque IDs. Exclude message text,
commands/args, paths, screens, rationale, transcripts and credentials. Never
trust environment variables for actor attribution. Avoid duplicate guard
approval records by identifying existing producers before adding hooks.

Start with approval requested and session spawn/close requested plus their
outcomes; then complete approved/denied/cancelled/expired/deferred and submission
attempted/outcome transitions. Approval answers must come from the existing
verified owner/caller path. A deferred approval is approved but unstarted, not
denied. Submission `write_returned` proves only that the core write returned;
it never proves agent receipt/consumption. Spawn success requires the returned
instance ID; close request/return is separate from observed process exit.
Emit operation attempt before the side effect and result after it, preserving
an operation ID. On restart a missing result stays unknown, never succeeded.

Append failure is observation failure, not authorization. Preserve existing
approval, expiry, denial and write-gate semantics; diagnostics cannot grant an
approval. Return a fixed `audit_append_failed` status, increment a memory gap
counter, and display unavailable/gap in the viewer. Do not claim an append is
recorded until write+flush+close succeed, or crash durable without fsync.
Existing audit-gated guard actions remain audit-gated; a new general lifecycle
observer must not silently change their policy. Any proposed fail-closed
spawn/close requirement needs a separate owner decision. Partial append/close
failure can leave bytes; use event IDs to deduplicate retries and mark a
truncated tail explicitly instead of claiming exactly-once persistence.

## Retrieval, retention and validation

Provide one bounded reader/projection shared by TUI and CLI, with explicit
source=durable/current-memory, node, retention window, gaps and read errors.
Read newest records under byte/row limits and fixed event allowlists; show
unavailable/truncated for inaccessible archives. Do not render arbitrary
legacy summary fields. Reuse existing cluster polling/authenticated transport
later; peers show stale/unavailable and last successful age.

Before implementation, confirm private directory and 0600 file/archive modes
on every rotation and reject unsafe symlink/non-owned paths. Existing budgets
are a starting proposal, not an owner retention preference. Review bounded,
configurable byte/count/age limits and their defaults before enabling the stage;
document pruning and restart limits.
Tests: requested/result order, actor/generation binding, content exclusion,
open/write/flush/close/rotate/lock failures, partial tail, duplicate retry IDs,
restart pending without invented outcomes, bounds/private modes, reader filters
and unavailable states. Review independently before enabling in production.
