-- Behavioral contract for the full relay SQLite authority. No implementation,
-- mocks or live runtime operations. Caller supplies a private-database adapter.
-- adapter:fresh() -> {store, inbox, inspect, faults}; inspect exposes only test
-- state, faults wraps the real DB/FS capability at named failure boundaries.
local C = {}
local function equal(a,b,why) assert(a==b,(why or 'equal')..': '..tostring(a)..' ~= '..tostring(b)) end
local function good(value,why) assert(value,why);return value end
local function denied(want,value,why)
 assert(value==nil,'operation unexpectedly succeeded')
 assert(type(why)=='string' and why:find(want,1,true),'expected '..want..', got '..tostring(why))
end
local function writer(s) return good(s:writer()) end
local function event(id) return {event_id=id,room_id='!test:invalid',payload_json='{"body":"keep","future":true}'} end
local function verify_all(store,options)
 for _=1,1000000 do
  local page=good(store:verify_import(options))
  if page.verified==true then return page end
  assert(page.state=='backlog','verification left backlog without a ready certificate')
  assert(type(page.count)=='number' and page.count>=0,'verification count missing')
 end
 error('verification exceeded bounded call count')
end
local function imported(t,fields)
 local store=t.store
 local manifest=t:valid_manifest(fields)
 good(store:import_prepare(manifest))
 good(store:import_source('fixture1',fields))
 local done=false
 for _=1,100000 do
  local page=good(store:import_batch('fixture1',64))
  if page.done then done=true;break end
  assert(page.count>0 or page.phase or page.state or page.ingest_id,'import batch made no progress')
 end
 assert(done,'import fixture exceeded bounded batch count')
 verify_all(store)
 return good(store:activate())
end
local function drive(t,receipt)
 local r=receipt
 while type(r)=='table' and not r.done do r=good(t.store:ingest_step(r.ingest_id)) end
 return r
end
local function refuse_batch(t,want)
 for _=1,100000 do
  local page,why=t.store:import_batch('fixture1',64)
  if not page then assert(why:find(want,1,true),why);return why end
  if page.done then break end
 end
 error('expected refused batch: '..want)
end

C.cases = {
 {'opaque_cursor_and_duplicate_batch',function(t)
  local s=t.store;local w=imported(t,'{"since":"z:opaque","pending_events":{}}')
  good(s:accept_batch(w,{operation_id='b1',expected_cursor='z:opaque',next_cursor='a:opaque',events={event('$1')}}))
  equal(good(s:cursor()).since,'a:opaque','cursor is opaque, no ordering')
  good(s:accept_batch(w,{operation_id='b1',expected_cursor='z:opaque',next_cursor='a:opaque',events={event('$1')}}))
  equal(#good(s:dispatch_page(10)),1,'retry is idempotent')
 end},
 {'operation_id_input_conflict',function(t)
  local s=t.store;local w=imported(t,'{"since":"s1"}')
  good(s:accept_batch(w,{operation_id='same',expected_cursor='s1',next_cursor='s2',events={event('$1')}}))
  denied('operation_conflict',s:accept_batch(w,{operation_id='same',expected_cursor='s1',next_cursor='different',events={event('$2')}}))
  equal(good(s:cursor()).since,'s2');equal(#good(s:dispatch_page(10)),1)
 end},
 {'cursor_conflict_no_partial_rows',function(t)
  local s=t.store;local w=imported(t,'{"since":"s1"}')
  denied('cursor_conflict',s:accept_batch(w,{operation_id='bad',expected_cursor='wrong',next_cursor='s2',events={event('$bad')}}))
  equal(good(s:cursor()).since,'s1');equal(#good(s:dispatch_page(10)),0)
 end},
 {'atomic_pending_cursor_failure',function(t)
  local s=t.store;local w=imported(t,'{"since":"s1"}')
  t.faults:once('before_commit','full')
  denied('full',s:accept_batch(w,{operation_id='full',expected_cursor='s1',next_cursor='s2',events={event('$full')}}))
  equal(good(s:cursor()).since,'s1');equal(#good(s:dispatch_page(10)),0)
 end},
 {'unknown_commit_requires_resolution',function(t)
  local s=t.store;local w=imported(t,'{"since":"s1"}')
  t.faults:once('commit_reply_after_commit','unknown_commit')
  denied('unknown_commit',s:accept_batch(w,{operation_id='unknown',expected_cursor='s1',next_cursor='s2',events={event('$u')}}))
  denied('blocked',s:accept_batch(w,{operation_id='next',expected_cursor='s2',next_cursor='s3',events={}}))
  local resolved=good(s:resolve_operation('unknown'))
  equal(resolved.status,'committed');equal(#good(s:dispatch_page(10)),1)
 end},
 {'dispatch_crash_cross_database_idempotence',function(t)
  local s=t.store;local w=imported(t,'{"since":"s1"}')
  good(s:accept_batch(w,{operation_id='batch',expected_cursor='s1',next_cursor='s2',events={event('$x')}}))
  local d=good(s:dispatch_page(1))[1]
  local r=good(t.inbox:accept_external(d.source_key,d.payload_json))
  -- Crash after inbox commit, before relay completion: same stable key/payload.
  t:reopen();s=t.store;w=writer(s);d=good(s:dispatch_page(1))[1]
  local same=good(t.inbox:accept_external(d.source_key,d.payload_json))
  equal(same.mail_id,r.mail_id,'one inbox mail across relay retry')
  good(s:complete_dispatch(w,d.event_id,same,{operation_id='done',route={future=true}}))
  equal(#good(s:dispatch_page(1)),0);equal(t.inspect:inbox_count(),1)
 end},
 {'external_payload_conflict_blocks',function(t)
  local s=t.store;local w=imported(t,'{"since":"s1"}')
  good(s:accept_batch(w,{operation_id='batch',expected_cursor='s1',next_cursor='s2',events={event('$x')}}))
  local d=good(s:dispatch_page(1))[1]
  good(t.inbox:accept_external(d.source_key,'{"different":true}'))
  denied('payload_conflict',t.inbox:accept_external(d.source_key,d.payload_json))
  equal(#good(s:dispatch_page(1)),1,'relay does not ack conflict')
 end},
 {'owner_epoch_fences_every_mutation',function(t)
  local s=t.store;local old=imported(t,'{"since":"s1"}')
  local fresh=good(t:replace_owner_after_verified_stop())
  denied('stale_writer',s:accept_batch(old,{operation_id='stale',expected_cursor='s1',next_cursor='s2',events={event('$old')}}))
  denied('stale_writer',s:put(old,'approvals','a','{"x":1}','stale-put'))
  denied('stale_writer',s:delete(old,'approvals','a','stale-delete'))
  denied('stale_writer',s:complete_dispatch(old,'$old',{mail_id='m'},{operation_id='stale-done'}))
  equal(good(s:cursor()).since,'s1');assert(fresh.epoch>old.epoch)
 end},
 {'legacy_owner_unknown_blocks_prepare',function(t)
  denied('legacy_owner_unknown',t:open_with_unknown_legacy_owner())
  equal(t.inspect:authority(),'unprepared');equal(t.inspect:network_calls(),0)
 end},
 {'no_file_fallback_after_promotion',function(t)
  local s=t.store;imported(t,'{"since":"s1"}')
  t.faults:once('open','corrupt');t:reopen()
  denied('blocked',t.store:cursor());equal(t.inspect:legacy_reads_after_promotion(),0)
 end},
 {'all_legacy_fields_unknown_members_preserved',function(t)
  local raw=[[{"since":"s","messages_since":"m","processed_event_ids":["$p"],"pending_events":{"$e":{"future":{"x":1}}},"quarantine":[{"future":2}],"matrix_mail_routes":{"mail":{"future":3}},"matrix_own_events":{"!r":[{"future":4}]},"matrix_reply_outbox":{"r":{"attempts":1,"status":"in_flight","future":5}},"matrix_reply_results":{"done":{"future":6}},"matrix_thread_subscriptions":{"!r":{"$t":{"future":7}}},"matrix_unfollowed_threads":{"!r":{"$u":{"future":8}}},"approvals":{"a":{"future":9}},"invite_dedupe":{"i":{"future":10}},"auto_join_timestamps":[{"future":11}],"typed_line_timestamps":[12],"unknown_root":{"deep":[true,false,null]}}]]
  imported(t,raw)
  equal(t.inspect:semantic_source_equal(raw),true,'every source path/value retained')
  equal(t.inspect:legacy_writes_after_promotion(),0)
 end},
 {'uncertain_outbox_never_dispatches',function(t)
  imported(t,'{"matrix_reply_outbox":{"old1":{"status":"in_flight","attempts":1},"old2":{"status":"pending"}}}')
  equal(#good(t.store:reply_dispatch_page(10)),0,'unknown/missing attempt evidence uncertain')
  equal(t.inspect:uncertain_count(),2);equal(t.inspect:network_calls(),0)
 end},
 {'legacy_ack_bridge_and_crash',function(t)
  local s=t.store;good(s:import_prepare(t:valid_manifest()))
  good(s:import_source('fixture1','{"pending_events":{"$acked":{"future":1},"$keep":{"future":2}}}'))
  while not good(s:import_batch('fixture1',64)).done do end
  drive(t,good(s:import_acks('acks-fixture','$acked\n$acked\n','acks-source-stamp')))
  t:reopen();s=t.store
  -- Reprocessing the immutable sidecar after a crash is harmless.
  drive(t,good(s:import_acks('acks-fixture','$acked\n$acked\n','acks-source-stamp')))
  verify_all(s);good(s:activate())
  local pending=good(s:dispatch_page(10))
  equal(#pending,1);equal(pending[1].event_id,'$keep')
  equal(t.inspect:legacy_sidecar_delete_calls(),0,'store never deletes originals')
 end},
 {'primary_backup_never_implicitly_merges',function(t)
  local manifest=t:valid_manifest()
  manifest.sources={{id='fixture1',role='primary',stamp='p1'},
   {id='backup1',role='backup_evidence',stamp='b1'}}
  good(t.store:import_prepare(manifest))
  good(t.store:import_source('fixture1','{"since":"primary","future":1}'))
  drive(t,good(t.store:import_source('backup1','{"since":"backup","future":2}')))
  while not good(t.store:import_batch('fixture1',64)).done do end
  verify_all(t.store);good(t.store:activate())
  equal(good(t.store:cursor()).since,'primary')
  equal(t.inspect:backup_evidence_retained(),true)
 end},
 {'duplicate_keys_any_depth_refuse',function(t)
  good(t.store:import_prepare(t:valid_manifest()))
  good(t.store:import_source('fixture1','{"pending_events":{"a":{"k":1,"\\u006b":2}}}'))
  refuse_batch(t,'duplicate_key')
  assert(t.store:activate()==nil)
 end},
 {'wrong_root_shape_refuses',function(t)
  good(t.store:import_prepare(t:valid_manifest()))
  good(t.store:import_source('fixture1','{"pending_events":[]}'))
  refuse_batch(t,'field_type')
 end},
 {'over_value_source_imports_without_core_decode',function(t)
  local raw='{"processed_event_ids":['..string.rep('"x",',110000)..'"last"]}'
  imported(t,raw)
  equal(t.inspect:source_core_decode_calls(),0)
  equal(t.inspect:semantic_source_equal(raw),true)
 end},
 {'source_change_and_oversize_never_skip',function(t)
  good(t.store:import_prepare(t:valid_manifest()))
  good(t.store:import_source('fixture1','{"future":1}'))
  denied('source_changed',t.store:import_source('fixture1','{"future":2}'))
  assert(t.store:activate()==nil)
 end},
 {'import_commit_before_marker_is_import_only',function(t)
  good(t.store:import_prepare(t:valid_manifest()))
  good(t.store:import_source('fixture1','{"since":"s"}'))
  while not good(t.store:import_batch('fixture1',64)).done do end
  verify_all(t.store)
  t.faults:once('active_marker_publish','io')
  denied('marker_publish',t.store:activate())
  denied('not_active',t.store:dispatch_page(1))
  t:reopen();denied('not_active',t.store:dispatch_page(1))
  equal(t.inspect:legacy_reads_after_promotion(),0)
 end},
}

function C.run(adapter)
 local failures={}
 for _,case in ipairs(C.cases) do
  local t=adapter:fresh()
  local ok,err=pcall(case[2],t)
  local closed,why=pcall(t.close,t)
  if not ok or not closed then failures[#failures+1]=case[1]..': '..tostring(ok and why or err) end
 end
 return #failures==0,failures
end
return C
