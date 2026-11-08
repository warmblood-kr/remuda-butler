# Bounded, restartable relay source ingest

`import_source`/`import_acks` are durable admission, not completed import. They
guard the existing 32MiB source and 256KiB record limits, write the original
bytes once into `relay_source_capture`, and return
`{accepted,done=false,state='hashing',ingest_id,revision}`. Retry compares
native bytes (`raw=?`) and returns the same receipt; different bytes, role or
stamp returns `source_changed`. Capture UPDATE/DELETE/duplicate INSERT abort.
JSON and sidecar ingests have distinct ids (`ingest:source:...`,
`ingest:sidecar:...`).

`ingest_step(ingest_id,{max_rows<=64,max_bytes<=262144,max_nodes<=8192})`
advances one persisted unit; `import_batch` auto-drives the JSON source first,
then the ordinary record pages. Phases:

- `HASH` one original chunk <=64KiB per call; persists offset/chunk index/hex.
- `ROOT_HASH` separate call hashes the fixed domain
  `butler-relay-source-v1\0<bytes>\0<chunkhex>`; seals the witness and copies
  the capture into the mutable projection only on the complete original.
- `JSON_ROOT`/`JSON_DUPLICATES` native JSON1 summary statements; no Lua root.
- `DISCOVER_FIELD`/`DISCOVER_ROOM` one key or child per call, started flag for
  empty keys; fields/units use `$.key` identifiers, JSON queries quote odd keys.
- `ACK_SCAN` reads <=64KiB original bytes and records <=64 complete line byte
  ranges; `ACK_APPLY` is a separate call applying <=64 ids/<=256KiB via those
  offsets. CRLF/blank/duplicate lines are preserved; a long line <=256KiB spans
  scans; a nonempty unterminated EOF blocks; >256KiB blocks `ack_oversize`.
- `READY` only after the exact artifact is complete. `verify_import`/`activate`
  refuse any pending or `BLOCKED` artifact, and refuse old staging without a
  capture. The proof version is 5.

Budget failure (`budget_too_small`) commits no progress. Owner/epoch is adopted
only through the existing exclusive capability, and every step CASes progress
revision. An unknown COMMIT quarantines the lease and returns
`{ingest_id,expected_revision,next_revision}` for same-operation recovery.

Migration `0004_relay_source_ingest` adds the capture, progress and ack-range
tables. Original files are never rewritten or deleted; archive remains out of
scope.
