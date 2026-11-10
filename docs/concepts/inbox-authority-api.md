# Inbox metadata authority API v1

v1, main5269382. Abstract seam:
`dofile("packages/butler/inbox_authority_contract.lua")`. Product module must
export identical functions from `packages/butler/inbox_authority.lua` and
return M (no globals required). Contract stubs deliberately return
`nil,{code="contract_unimplemented",operation=...}`. RED scaffolding only; QA binds the product module when available.

## Exact parity certificate callable

`M.certify(source, actual, context) -> certificate | nil, error`

Both snapshots are `{deliveries={row,...}, reads={ [message_id]=true,...}}`.
Deliveries are in canonical order; row is
`{message_id=string, seq=integer, resent=string|nil, envelope_ref=string,
object_ref=string, metadata=string}`. `resent` is canonical JSON of the LAST
annotation, nil for absent. `metadata` is canonical JSON of preserved envelope
metadata including stable sender/recipient ids and aliases, refs, forwarding,
thread, room/event ids, and content identity/hash. Canonical encoding must be
shared by source and SQL adapters, never raw arbitrary JSON byte comparison.
Refs/content identity remain included when bodies are immutable files. Fixtures may use empty metadata and fixed refs.

Source adapter collapses duplicates at first occurrence into dense seq 1..N;
last PRESENT resent supplies the annotation; a plain duplicate does not clear it. Reads are the exact
whole read set, including orphan legacy reads; no intersection truncation.
Invalid/torn/unreadable source is incomplete, never silently skipped.
Actual is read in one SQL snapshot, ordered by seq; duplicate ids, bad seq,
extra/missing ids, read-key or resent/ref/metadata drift must fail certification.

Context is `{root=string,recipient=hex_string,epoch=integer,
source_before=string,source_after=string,db_snapshot=string,
complete=true,writer={owner=true,guarded=true,root=string}}`.
Source witnesses are full-content generation tokens, NOT size/head/count.
Unequal tokens, incomplete state, missing witnesses or writer/root mismatch
fail closed. Tokens are obtained by the adapters around the SQL snapshot;
caller cannot manufacture production proof from fixture booleans. Function is
pure, compares every ordered row and both exact read sets, opens no files,
and cannot certify by counts/MAX(seq). Success is
`{state="match",root=...,recipient=...,epoch=...,source=source_before,
db_snapshot=...,deliveries=N,reads=N}`. Error is `{code=...,field=...,id=...}`;
codes: `partial`, `stale_generation`, `writer_conflict`, `parity_mismatch`,
`invalid_snapshot`. Classification precedence: invalid shape => invalid_snapshot; incomplete => partial;
writer mismatch => writer_conflict; changed witness => stale_generation;
any row/read difference => parity_mismatch (field names delivery/read/resent/refs/metadata).
Errors omit bodies. RED: source A,B,C,
read B vs SQL A,B,D; reordered A,C,B; swapped read C; resent drift; equal-count
all must fail, exact match must pass. Altered proof must also fail. Each mutation pairs with
an exact-match positive; negatives assert these specific codes, so reject-all
stubs cannot pass. Orphan reads preserved in source must match exactly in SQL.

## Store seam

`M.open(config)` returns Store or nil,error. Config has root, marker adapter,
SQL opener, body/envelope adapters, existing585 importer, writer capability.
Marker inspection precedes DB access. Store methods use colon invocation:

- `status()` returns authority/epoch/schema/import progress/classified error.
- `lookup_matrix(recipient,room,event)` returns
  `{state="found",message_id=id}` or `{state="absent",complete=true}` or
  `{state="unknown",reason=code}`. Exact triple; metadata only, zero historical
  body opens. Missing/corrupt metadata refuses conservatively. Dedup hydrates only a found
  hit; rendering page rows also hydrates. Corrupt hit refuses a new ULID.
- `hydrate(id)` returns envelope/body or nil,error; no authority inference.
- `page(recipient,query,cursor)` returns rows,snapshot,keyset cursor as one
  table; unknown unread is explicit, never zero. Snapshot fences read ack.
- `deliver(intent)`, `mark_read(intent,ids,snapshot)`,
  `transition(expected,target,proof)`, `reconcile(operation_id)` return
  `{state="committed",operation_id=...,result=...}`,
  `{state="not_committed",operation_id=...,proof=...}`, or
  `{state="unknown",operation_id=...,reason="unknown_commit"}`.
  Intent has operation_id and immutable payload_hash; changed hash under same
  id is operation_conflict. Receipt and all metadata changes commit atomically.
  Commit exception is unknown; reconcile existing id, never blind retry or
  transport send. Ack only successfully rendered witnessed ids.
- `advance(budget)` returns bounded resumable progress or nil,error. Reuse
  #585 importer, but its skipped/partial/head/count status cannot certify.
  Add full identity/read/resent/metadata validation and atomic cursor staging;
  restart resumes without publishing partial coverage. No replacement importer.
