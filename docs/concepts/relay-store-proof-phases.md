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

WITNESS advances one source/sidecar at most and rehashes one sealed
`chunk_size` (<=64KiB) raw-byte chunk per call with
`substr(CAST(raw AS BLOB),offset,length)`, persists `{index,offset,chunks}` in
`phase_cursor`, and accumulates at most 32KiB of chunk hex; a zero-byte input
hashes the empty domain directly. The reverse also holds: every retained
witness must still have its live source+manifest (or sidecar), one per call, so
deleting both refuses instead of dropping a witnessed original. The domain digest is rebuilt; input over
64KiB refuses `digest_budget`. Digest/bytes/role/stamp/root_digest must
match the sealed baseline, otherwise `source_changed`. Backup evidence and
sidecars are witnessed too; the original raw bytes stay as evidence.

## SOURCE_ROWS / TARGET_REVERSE

SOURCE_ROWS first walks `json_each` keys and nested room keys from the
original raw, one domain per call starting before the empty key, and requires
the exact source field and, for every nonempty collection, exactly one unit
with the original kind/parent/count. It then pages stored units and fields back
one per call against the original domain with the original
token/type/ordinal/kind check; the `$` root field is mandatory. Zero-expected
units are refused, so deleting a unit/record pair and zeroing `staged_count`
cannot certify an empty projection. Cursor presence/null/value
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

DERIVED checks processed and pending-event directions with indexed aggregate
passes (not per-row JSON); delivered events require a witnessed CRLF-normalized
ack and `inbox_mail_id` must stay NULL. Outbox intents are paged metadata-only:
no payload enters Lua; SQL decides payload/txn equality, and only bounded
attempts (<=64B trimmed or <=16 hex digits) or a long-number comparison enter
the check. Long junk requires stored NULL; other long numeric forms refuse.
The first page has no lower bound so an empty reply id is checked. Extra or
missing rows refuse. Measured: derived ~2ms/2k rows; the 110001-row proof
<=0.12s/call. READY creates the certificate only when all phases share the same witness and
`data_revision`. The certificate id is recomputed from its exact inputs plus
`PROOF_VERSION`; `relay_proof_state` binds the version and store id.
READY/activation require the recomputation, so an older-verifier or fabricated
certificate is reset/reverified while same-version resume continues.
`store:proof(certificate_id)` returns the current certificate/witness/source
inputs for the startup/archive coordinator; it is necessary input, never an
archive authorization.

## Revision matrix

Importing-only I/U/D triggers cover the populated proof inputs: manifest,
import source (including `staged_count`), source fields, units, cursors,
records, processed, events, reply intents, sidecar, and witness INSERT. Narrow
exclusions are verification progress/certificates, `verified_count`, the exact
status promotion to verified, authority bookkeeping, and ACTIVE raw retirement/
normal mutations. Schema open writes pending=1 BEFORE repairing trigger DDL, then bumps
`data_revision`; on bump failure it deletes checkpoints/certificates and fails
closed; later opens retry from the durable pending/fingerprint state. A
weak-trigger certificate cannot stay READY even when repaired SQL later looks
correct. Now 18 tables, 31 `relay_rev_*` triggers.
