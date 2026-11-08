# Store adapters and results v1

Additive to inbox-authority-api.md; certifier/API v1 unchanged. All adapters
return value or nil,{code=string,...}; thrown exceptions are caught/classified.
Adapters are injected in M.open(config), bound to one canonical actual root:

```
config = {
 root = canonical_absolute_root,
 marker = { read=function(root), prepare=function(expected, next),
            finalize=function(expected, next) },
 writer = { claim=function(root) },
 sql = { open=function(root) },
 source = { snapshot=function(root, recipient), recipients=function(root) },
 content = { publish=function(intent), hydrate=function(message_id) },
 importer = existing585_index,
 pump = { schedule=function(callback) },
}
```

Functions in adapter tables use dot invocation. The returned SQL session uses
colon methods. marker.read returns `{state="FILE"|"CUTOVER_PREPARED"|
"SQL_ACTIVE"|"RECOVERY_REQUIRED",format_version=integer,root=string,
epoch=integer,operation_id=string|nil,generation=string|nil}`. Definitive ENOENT
means FILE epoch0 only for a root without transition intent; any other read
failure refuses open. Marker prepare/finalize are atomic compare-and-publish
operations; any ambiguous result demands reread, never assume old state.

writer.claim returns capability `{root,owner=true,guarded=true,release=fn}`
held for Store lifetime. Refusal yields writer_conflict before any importer or
mutation. This covers supported upgraded binaries and cooperating legacy guard
holders at actual root, not arbitrary old programs bypassing the lock.

sql.open returns existing remuda DB handle supporting `exec/query/close`;
exec/query use existing SQL/params bindings and nil,error convention. No new
native SQL API is assumed. M.open owns schema detection/migration, never treats
an empty query or schema error as empty mailbox. Source.snapshot returns
`{deliveries,reads,witness,complete,recipient}` from complete immutable source
view under held writer; source.recipients includes read-only/orphan mailboxes.
Content.publish returns `{message_id,envelope_ref,object_ref,metadata,
content_hash,published=true}` only after successful immutable publication;
failure is unavailable/corrupt/unknown as applicable. Publish does not deliver.
Content.hydrate never changes membership/read state. Existing585_index methods
remain import_all/status/available; advance wraps/reuses that import path,
adding staged exact validation rather than trusting its skipped/head proof.
Pump schedules bounded work during daemon lifecycle; no boot-only starvation.

Open returns Store even in FILE migration state when SQL is unavailable, with
status degraded and file reads only; after any sql_required marker it returns
nil,error on DB failure, retaining marker unchanged. Corrupt/ambiguous marker
returns nil,{code="recovery_required"}; schema-too-new sql_required returns
schema_too_new. No fallback invokes importer or files after sql_required.

Store:status() -> `{authority="file"|"sql_required"|"sql",epoch,schema,
root,writer={owner,guarded},migration={state,cursor,complete},error=...}`.
Store:page(recipient,{limit=positive_integer,unread_only=boolean},cursor) ->
`{rows={...},snapshot={root,recipient,epoch,generation},next_cursor=opaque|nil,
unread=integer|nil,unread_error=code|nil}`. SQL snapshot spans pagination via
stable generation/keyset; stale cursor errors stale_generation. Rows contain
message_id, seq, resent and content refs. Hydration failure never auto-acks.

Intent shape: `{operation_id,payload_hash,message_id,recipients={hex,...},
content=opaque,metadata=canonicalJSON}`; mark_read uses operation_id/payload_hash
and supplied ids/snapshot. Deliver committed result is `{message_id,
recipients={hex,...}}`; mark_read result `{ids={...},snapshot=...}`; transition
result `{authority,epoch,generation}`. Query outcomes include operation_id.
Receipt payload_hash conflict returns nil,{code="operation_conflict"}.

advance({max_bytes,max_statements,max_ms}) -> `{state="backlog"|"ready",
cursor=opaque,complete=boolean,imported_bytes=integer}`. Ready requires every
recipient and exact read/metadata certification. Commit exceptions on writes
return unknown; reconcile(id) only queries durable operation receipt. Missing
receipt alone is NOT not_committed while previous commit remains unresolved;
require recovered exclusive connection plus completed transaction recovery.
SQL unavailable => unknown. No external transport occurs in this module.
