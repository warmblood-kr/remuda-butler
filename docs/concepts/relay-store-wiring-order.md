# Relay store caller wiring order (design, 2026-11-08)

Frozen store candidate: `850eeb7`. This is the integration order after that
slice; it is NOT implemented and does NOT authorize live activation. The store
stays standalone until every reader/writer below is switched.

## 1. Boot / capability (main.lua)

`main.lua` currently loads `relay_receipts`, then `matrix_request`, then
`matrix`, then extends `matrix.relay` in `matrix_relay.lua`. Insert the store
capability after `matrix_request` and before `butler/matrix_relay`:

1. Capture `remuda.db.open`, `remuda.fs`, marker path
   (`<config dir>/authority.json`), anchors metadata, root owner registry and
   process-exclusion proof outside replaceable `matrix`/`relay` globals.
2. `relay_store.open(opts)`; keep the returned store on the staged matrix
   generation. Never call `load_state` or read `.since` first.
3. If `phase ~= 'active'` or owner/epoch/marker check fails, the relay stays
   inert: no poll, no send, no legacy fallback. Expose the typed reason.
4. Existing `relay_receipts` remains shadow-only; do not let it decide
   authority after cutover.

## 2. Relay construction (matrix_relay.lua)

Replace `load_state`/`save_state`/`relay.new` state ownership:

1. `relay.new(options)` receives the active store; refuse without it.
2. Delete `state_path`, `ack_path`, `load_state`, `save_state`, `.bak`
   restore, and `relay.json_budget` full-state encoding.
3. `persist()` becomes store transactions; every mutation takes
   `store:writer()` and the current `operation_id`.
4. `relay.owner_proven()` reports the same store/owner/epoch used by mutations.
5. `quarantine_list`, `quarantine_get`, mail-route lookup, and `metadata` read
   store pages; no `.since` file path remains.

## 3. Sync reader

For each sync/messages response:

1. Build bounded event deltas with the stable key
   `account|room|event|butler` (store/epoch/process/device independent) and a
   frozen payload snapshot.
2. `accept_batch(writer,{operation_id,expected_cursor=cursor.since,
   next_cursor=response.next_batch,events})`. Cursor equality only; opaque.
3. Apply policy/filter dispositions in the same batch or as explicit records;
   never advance past an unrecorded event.
4. On unknown commit, stop and `resolve_operation`; never resend or legacy-read.

## 4. Pending worker / inbox bridge

1. `dispatch_page(limit<=64)` returns pending events.
2. Fetch/persist thread context and freeze the delivery payload before the
   first inbox call.
3. Call the shared inbox owner API `accept_external(source_key,payload)`; same
   key/payload after a crash must return the same mail id, changed payload is a
   conflict. This is the matrix-thread-code boundary; relay does not implement
   inbox files or a competing writer.
4. Only after the receipt, `complete_dispatch(writer,event_id,receipt,
   {operation_id,route=...})` atomically records delivered, route/subscription
   changes, and processed disposition. No `.acks` append/delete at runtime;
   `.acks`/`.acks.drain` are import-only evidence.
5. Filtered/dead-letter dispositions are explicit store states; no silent drop.

## 5. Outbound queue

1. `queue_mail_reply` writes a prepared intent (txn/payload/route) first.
2. Immediately before POST, `claim_reply` checks owner/epoch and CASes the
   intent. Success commits receipt + sent claim before returning; unknown HTTP
   or commit becomes uncertain/save-only. Never resend uncertain.
3. Imported outbox rows stay `imported=1,state='uncertain'` and are excluded
   from `reply_dispatch_page`; the old two uncertain replies remain untouched.
4. Remove reply retry state from Lua maps; timers may trigger a store page but
   cannot replay an imported/runtime-uncertain intent.

## 6. Readers / status / CLI

1. `matrix_read.status` and `doctor` read `store:status()` and cursor; no
   `.since` `load_state`.
2. `matrix_cli` quarantine/routes/outbox reads use bounded store pages.
3. `main.lua` `matrix.quarantine_list` no longer saves `.since`; remove that
   second writer.
4. Any store/marker/DB error is `blocked`, never a file fallback.

## 7. Lifecycle and activation

1. `init.start_matrix_relay` acquires the store/writer before `relay.start`;
   stop releases only after verified stop. `relay.stop` closes the store lease.
2. Import/verify/activate is an offline owner maintenance path; activation
   publishes the marker only after DB commit. Live activation remains an owner
   decision, not this wiring.
3. Full reader/writer replacement, not a standalone-store claim, is completion.
