# Source progress backend records: progress v2

Companion: inbox-source-progress.md. This is the transaction backend for
#585 staging in the SAME inbox SQLite handle/schema, not another store. All methods DOT calls, return value or nil,{code,...}. Every call
binds root+recipient+generation; never shares recipient cursors implicitly.

progress.load(root,recipient) -> `{revision=integer,cursor=cursor}` or nil,
{code="not_found"}. Cursor is BOUNDED:
`{protocol_version=2,generation=string,phase="logs1"|"files1"|"logs2"|"files2"|"ready"|"invalid",
log="inbox"|"read"|nil,offset=integer,parse_offset=integer,
line_tail=string,after_key=string|nil,chain=64hex,first_chain=64hex|nil,
next_seq=integer,complete=boolean,witness=string|nil}`.
line_tail is bounded by config.max_line_bytes (default1MiB); exceeding returns
source_oversize preserving original. Fixed64KiB chunk parse_offset permits
record-budget stopping inside chunk; checkpoint never skips unparsed bytes.
No task/read/delivery sets in cursor. Versionless/v1 cursors refuse v2 resume
and ready; seed/token must be source-progress-v2. Synchronous source-v1 stays
separate. Root/recipient are explicit.

progress.commit(root,recipient,expected_revision,next_state,delta) ->
`{revision=expected_revision+1}` or nil,error. next_state is ONLY bounded cursor;
delta is dense array <=config.max_stage_records (default256). First creation
expects revision0+new generation, absence checked atomically. Existing creation
must not overwrite. Transaction atomically applies entire delta and cursor.
Revision mismatch => stale_generation. A commit throw/unknown returns
unknown_commit; reload state before retry, caller retains expected revision
and generation to classify committed vs not_committed. Unavailable stays unknown.
No reapplication just because a timeout returned. Generation change must be
explicit create-new; old incomplete rows remain quarantined/unpublished.

Exact semantic operations (no physical table/SQL names mandated):
- `{op="delivery",message_id,seq,resent=canonicalJSON|nil}` inserts first id at
  seq; existing id keeps seq; resent nil retains existing, present replaces.
- `{op="read",message_id}` inserts exact set member, duplicates no-op.
- `{op="metadata",message_id,envelope_ref,object_ref,metadata}` replaces complete
  validated canonical fields on already staged delivery.
- `{op="dependency",owner=message_id,role="envelope"|"body"|"note",path=relative}`
  upserts (owner,role), replacing prior path; each owned role has one current
  path. Shared physical paths are deduplicated when enumerating file tasks.
- `{op="fileproof",pass=1|2,path,present=boolean,bytes=integer,sha256=64hex}`
  writes exact dependency proof once; conflicting same-pass value refuses with
  stale_generation. Absent log proof uses bytes0+digest of empty bytes.
- `{op="chunkproof",pass=1|2,path,offset,bytes,sha256=64hex,eof=boolean}`
  records fixed log-chunk commitment; same-key conflict => stale_generation.
- `{op="ready",witness,first_chain,second_chain}` permits ready only when
  chains equal and phase2 exhausted, every delivery has metadata and dependency
  proofs match across passes. Sets cursor.complete=true in same transaction.
  It certifies SOURCE completeness only, not SQL authority/cutover.
- `{op="invalid",reason=code}` marks generation unusable, never deletes source.
Unknown op/invalid shape => invalid_snapshot and atomic no-change.

progress.scan(root,recipient,generation,kind,after_key,limit) ->
`{rows={...},next_key=string|nil,complete=boolean}`. limit1..256, keyset stable
under this held writer/generation. kind: deliveries (seq order, full certifier
rows); reads (message_id order, `{message_id}`); dependencies (distinct path
order, `{path}`); fileproofs (pass,path); chunkproofs (pass,path,offset).
Internal opaque row key in next_key; terminal complete=true ONLY at end of that
kind, NOT source completeness. Missing generation => source_unreadable; query
error never empty. progress.get(root,recipient,generation,kind,key) -> row or
`{state="absent"}`; kind delivery key message_id, dependency key `{owner,role}`,
fileproof key `{pass,path}`, chunkproof key `{pass,path,offset}`. Only proven
query absence produces absent. This supports duplicate ranks/last resent and
same-pass retries without scanning whole generation.

Source discovery follows delivery seq, role envelope/body/note, first-seen
shared path once per pass; scan dependencies path order is NOT witness order.
One bounded discovery page per unit checkpoints after_key. Ready assembles
deliveries+reads by pages; a large result table is allowed, never one DB JSON.
Query failure returns error, not partial snapshot. Store certifies SQL/source;
no promotion here. Independent recipient cursors avoid cross-talk. Lifecycle
pump owns round-robin fairness; this adapter alone schedules nothing.
