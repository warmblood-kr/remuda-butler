# Resumable source API: progress protocol v2

Source:snapshot/witness/recipients and certifier v1 are unchanged. Synchronous
`source-v1` is a SEPARATE protocol for small callers, not live large-mailbox
progression. Source:advance and Store:advance reuse the SAME #585-extended
staged generation, never repeated snapshots from zero.

Config dot adapters:
`fs.read_range(path,offset,max_bytes) -> {bytes,eof} | nil,error`;
`progress.load(root,recipient) -> state | nil,error`;
`progress.commit(root,recipient,expected_revision,cursor,delta) -> result | nil,error`.
Only definitive not_found starts a generation. Generic unavailable refuses.
Rows, bounded cursor and proof ledger commit atomically with revision CAS.
Unknown COMMIT requires recovered revision/state reconciliation, never blind
reapplication. No process-local hash object or whole-mailbox JSON checkpoint.

Advance budget: `{max_bytes,max_tasks,max_ms}` positive integers. Result:
`{state="backlog"|"ready",cursor,complete,processed_bytes,processed_tasks,snapshot}`.
Snapshot exists only on ready and has canonical deliveries/exact read set.
Durable cursor carries `protocol_version=2`, generation, phase, log offsets,
partial line, after_key and chain. Returned cursor may be diagnostic; durable
rows hold deliveries, last PRESENT resent, reads, dependencies and proofs.

## Deterministic order and checkpointing

1. Process inbox then read log in fixed chunks; preserve unfinished JSONL line
and parse offset across calls. First distinct delivery gets dense seq; later
PRESENT resent replaces annotation, a plain duplicate does not clear it.
Retain orphan reads. EOF without newline is partial, never ready; persist tail
so a later append can resume. Rows and consumed offset commit together.
2. Discover files in DELIVERY seq order, not global path order. For each
row consider envelope, body, then retained note. Hash each physical path at
its FIRST encounter in this order; shared paths contribute once per pass.
A proof-complete shared path does not add another chain record. Metadata-only
completion does not add a file hash. Discovery uses at most one bounded
SQL delivery page per unit; checkpoint after_key even if no file task exists.
An unfinished row retains seq-1, so restart rechecks that row, not all history.
3. Read each file's exact bytes, SHA-256, validate identity, stage metadata,
digest/length and cursor atomically. Pass2 repeats inbox/read chunks and the
SAME delivery/role first-encounter order, comparing exact path presence,
length and digest against pass1. There is NO global path sort.
4. Equal ordered chains plus exhausted phase2 and exact dependency/metadata
coverage permit atomic ready. Partial/skipped/torn data never proves absence
or authorizes promotion. SQL rows still pass the exact certifier. Source
mutation invalidates the generation; budgets/restarts alone never reset pass1.
Supported writer exclusion and immutable content exclude hostile ABA.

## Versioned witness

Progress v2 token: `source-progress-v2:sha256:<hex>`.
Seed H=sha256(frame("source-progress-v2",root,recipient)). Each deterministic
record advances H=sha256(frame(H,path,presence,offset,length,sha256(bytes))).
Frame each field as decimal byte length + ':' + exact bytes. Logs use fixed
64KiB boundaries independent of caller budget, with length/end/absence records.
Files use one digest record in the order above. Tokens are opaque to certifier
v1; no zero-collision assurance. Synchronous source-v1 is not renamed.

Seed, token and durable cursor version MUST agree. Versionless or progress-v1
cursors cannot resume or become ready under v2; refuse explicitly. A new v2
generation requires an explicit migration/reset path, retaining old unpublished
rows; never silently reinterpret or mix chains. Reopen v2 preserves version,
after_key and proofs. Source files are untouched by protocol invalidation.

## Bounds and QA

Check task/time budgets between units. One log unit is <=64KiB; a lower byte
budget still permits one chunk for progress. One whole-file read/hash is the
explicit unbounded latency/memory exception; no hard wall-time promise.
max_single_file_bytes + fs.size checks before read; oversize is source_oversize,
not perpetual partial. Final ready snapshot assembly is a separate large-table
exception; do not serialize that snapshot as one SQL JSON checkpoint.

QA: cross-order paths and shared body/note give the expected v2 framed chain;
max_tasks=1 discovery checkpoints one page; reopen resumes without rereading
complete file tasks; versionless/v1 cursors refuse resume AND ready; mutation
fails stale_generation; ambiguous COMMIT reconciles; pre-ready has no snapshot.
