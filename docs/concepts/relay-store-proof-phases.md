# Relay full-proof phases (3d7 + root-approved correction)

`verify_import` keeps the bounded ABI (`max_rows<=64`, `max_bytes<=262144`,
`max_nodes<=8192`) and now persists a phase machine in
`relay_verify_progress`: `witness -> source_rows -> target_reverse -> derived ->
ready`. One call advances at most one phase/unit task, one fixed witness chunk,
or a selected record prefix. A phase-transition call may report `count=0`.

## Sealed witness

At the first successful source/sidecar admission, the same transaction inserts
`relay_verify_witness` `{source_id,kind,role,stamp,bytes,raw_sha256,
root_digest,chunk_size}`. BEFORE INSERT-when-present, UPDATE and DELETE abort;
`INSERT OR REPLACE` cannot bypass. Retries compare the baseline first and never
replace it. `manifest` membership/roles are matched both ways. A staged row
without a witness refuses `source_witness_missing`; verification never seals the
current raw.

WITNESS rehashes one sealed `chunk_size` (<=64KiB) raw-byte chunk per call with
`substr(CAST(raw AS BLOB),offset,length)`, persists `{index,offset,chunks}` in
`phase_cursor`, and accumulates at most 32KiB of chunk hex; a zero-byte input
hashes the empty domain directly. The reverse direction also holds: every
retained witness must still have its live source plus manifest entry (or its
sidecar), so deleting both the manifest and import-source rows refuses instead
of dropping a witnessed original from the proof. The existing domain
`SHA('butler-relay-source-v1\0'..bytes..'\0'..chunks)` is rebuilt; a final input
over 64KiB refuses `digest_budget`. Digest/bytes/role/stamp/root_digest must
match the sealed baseline, otherwise `source_changed`. Backup evidence and
sidecars are witnessed too; the original raw bytes stay as evidence.

## SOURCE_ROWS / TARGET_REVERSE

SOURCE_ROWS first walks paged `json_each` keys and nested room keys from the
original raw and requires the exact source field and, for every nonempty
collection, exactly one unit with the original kind/parent/count. It then pages
the stored units and fields back against the original domain with the original
token/type/ordinal/kind check. Zero-expected units are refused; this is the
original-domain-to-unit bijection, so deleting a unit/record pair and zeroing
`staged_count` cannot certify an empty projection. Cursor presence/null/value
and source-field/unit structure parity follow.
Planning order is LENGTH-only candidates -> byte prefix <=256KiB -> `json_tree`
nodes for that selected prefix only -> node prefix <=8192 -> exact SQL join
returning counts. Payload never enters Lua before the budget filter.

TARGET_REVERSE pages target `namespace/parent_key` groups starting before the
empty namespace (<=64/call), then pages units. Each group must map to exactly
one canonical unit and count, and each unit's canonical target count must equal
its expected count, including expected=0 domains. `unknown:` is valid only for
raw units, so an alias like `unknown:approvals` cannot borrow a real unit's
count. No whole-target COUNT/EXCEPT is used.

## DERIVED and READY

DERIVED checks both directions exactly: processed `(source,ordinal,event_id)`,
pending events payload/room/source_key/state (delivered only when a witnessed
ack sidecar names the event, with CRLF normalized; unexplained ack refused),
`inbox_mail_id` must stay NULL for imported events, and imported outbox intents
payload/txn/attempts/imported=1/state uncertain. Extra or missing rows refuse. READY creates the certificate only when all phases share the same
witness and `data_revision`; activation checks the indexed
certificate/checkpoint/witness/data_revision/owner/epoch equality.

## Revision matrix

Importing-only I/U/D triggers cover the populated proof inputs: manifest,
import source (including `staged_count`), source fields, units, cursors,
records, processed, events, reply intents, sidecar, and witness INSERT. Narrow
exclusions are verification progress/certificates, `verified_count`, the exact
status promotion to verified, authority bookkeeping, and ACTIVE raw retirement/
normal mutations. `CREATE TRIGGER IF NOT EXISTS` does not repair an older
incomplete predicate, so schema open drops and recreates every relay trigger
before use; an installed old definition is replaced rather than trusted.
