-- Executable SQL contract; not a production importer. Raw source is staging,
-- never authoritative state. Run only through a disposable mod-owned db.
local M = { max_source_bytes = 32 * 1024 * 1024,
  max_record_bytes = 256 * 1024, max_record_nodes = 8192, page_rows = 64 }

M.create_stage = [[CREATE TEMP TABLE relay_contract_source (
 id TEXT PRIMARY KEY, raw TEXT NOT NULL CHECK(length(CAST(raw AS BLOB)) <= 33554432)
)]]
M.stage = 'INSERT INTO relay_contract_source(id,raw) VALUES (?,?)'
M.root = [[SELECT json_valid(raw) AS valid,
 CASE WHEN json_valid(raw) THEN json_type(raw) ELSE 'invalid' END AS kind
 FROM relay_contract_source WHERE id=?]]
-- Object duplicate keys are unacceptable at ANY depth, including escaped-key
-- aliases. json_tree returns decoded key names. Array indexes are unique.
M.duplicates = [[SELECT count(*) AS duplicates FROM (
 SELECT n.parent,n.key FROM relay_contract_source s,json_tree(s.raw) n
 WHERE s.id=? AND n.parent IS NOT NULL
 GROUP BY n.parent,n.key HAVING count(*)>1)]]
-- Unknown fields are preserved, not rejected. Every known collection keeps
-- its original root type; missing optional fields differ from explicit null.
M.field_errors = [[WITH expected(name,kind) AS (VALUES
 ('since','cursor'),('messages_since','cursor'),
 ('processed_event_ids','array'),('pending_events','object'),
 ('quarantine','array'),('matrix_mail_routes','object'),
 ('matrix_own_events','object'),('matrix_reply_outbox','object'),
 ('matrix_reply_results','object'),('matrix_thread_subscriptions','object'),
 ('matrix_unfollowed_threads','object'),('approvals','object'),
 ('invite_dedupe','object'),('auto_join_timestamps','array'),
 ('typed_line_timestamps','array'))
 SELECT count(*) AS invalid_fields FROM relay_contract_source s,json_each(s.raw) e
 JOIN expected x ON x.name=e.key WHERE s.id=? AND
 NOT(e.type=x.kind OR (x.kind='cursor' AND e.type IN('text','null')))]]
M.root_fields = [[SELECT e.key,e.type FROM relay_contract_source s,json_each(s.raw) e
 WHERE s.id=? ORDER BY CAST(e.key AS BLOB) LIMIT ? OFFSET ?]]
-- Arrow returns original JSON token text. json_each.value/json_extract round
-- large scalar numbers; never use CAST(value AS TEXT) as a preservation path.
-- Size/node checks happen IN SQL before any payload crosses into Lua.
M.items = [[WITH page AS MATERIALIZED (
 SELECT e.key,e.type,e.fullkey,s.id AS source_id
 FROM relay_contract_source s,json_each(s.raw,?) e WHERE s.id=?
 ORDER BY e.key LIMIT ? OFFSET ?
), records AS MATERIALIZED (
 SELECT p.key,p.type,s.raw -> p.fullkey AS raw_record
 FROM page p JOIN relay_contract_source s ON s.id=p.source_id
), budget AS MATERIALIZED (
 SELECT key,type,raw_record,length(CAST(raw_record AS BLOB)) AS payload_bytes,
 CASE WHEN length(CAST(raw_record AS BLOB))<=262144
 THEN (SELECT count(*) FROM json_tree(raw_record)) ELSE -1 END AS payload_nodes
 FROM records
)
 SELECT key,type,payload_bytes,payload_nodes,
 CASE WHEN payload_bytes<=262144 AND payload_nodes<=8192
 THEN raw_record ELSE NULL END AS payload_json FROM budget ORDER BY key]]
M.record_budget = [[SELECT length(CAST(? AS BLOB)) AS bytes,
 (SELECT count(*) FROM json_tree(?)) AS nodes]]

local function query(db, sql, args)
 local rows, why = db:query(sql,args)
 assert(rows,why); return rows
end

function M.verify_native(db)
 assert(db:batch(M.create_stage))
 local raw='{"pending_events":{'..'"a":{"unknown":{"nested":true}},'..
  '"b":{"v":null},"c":{"v":false}}}'
 assert(db:exec(M.stage,{'good',raw})==1)
 local root=query(db,M.root,{'good'})[1]
 assert(root.valid==1 and root.kind=='object','strict object source')
 assert(query(db,M.duplicates,{'good'})[1].duplicates==0,'clean source')
 local rows=query(db,M.items,{'$.pending_events','good',2,0})
 assert(#rows==2 and rows[1].key=='a' and rows[2].key=='b','bounded deterministic page')
 assert(rows[1].payload_json=='{"unknown":{"nested":true}}','unknown field preserved')
 local final=query(db,M.items,{'$.pending_events','good',2,2})
 assert(#final==1 and final[1].key=='c','resume page')
 local bad='{"pending_events":{"x":{"k":1,"\\u006b":2}},"pending_events":{}}'
 assert(db:exec(M.stage,{'duplicate',bad})==1)
 assert(query(db,M.duplicates,{'duplicate'})[1].duplicates==2,'nested/escaped duplicate rejected')
 assert(db:exec(M.stage,{'bad-shape','{"pending_events":[],"since":12}'})==1)
 assert(query(db,M.field_errors,{'bad-shape'})[1].invalid_fields==2,'known field types strict')
 assert(query(db,M.field_errors,{'good'})[1].invalid_fields==0,'unknown nested fields retained')
 local huge='{"processed_event_ids":['..string.rep('"x",',110000)..'"last"]}'
 assert(db:exec(M.stage,{'huge',huge})==1)
 assert(query(db,M.root,{'huge'})[1].valid==1,'over-value source remains SQL-readable')
 local page=query(db,M.items,{'$.processed_event_ids','huge',1,110000})
 assert(#page==1 and page[1].payload_json=='"last"','over-value migration avoids full Lua decode')
 local scalar='{"values":[true,false,null,"quoted",9223372036854775809,0.123456789012345678901]}'
 assert(db:exec(M.stage,{'scalar',scalar})==1)
 local values=query(db,M.items,{'$.values','scalar',6,0})
 for i,want in ipairs({'true','false','null','"quoted"','9223372036854775809','0.123456789012345678901'}) do
  assert(values[i].payload_json==want,'scalar type/precision preserved '..i)
 end
 local oversized='{"values":["'..string.rep('x',M.max_record_bytes+1)..'"]}'
 assert(db:exec(M.stage,{'oversize',oversized})==1)
 local large=query(db,M.items,{'$.values','oversize',1,0})[1]
 assert(large.payload_json==nil and large.payload_bytes>M.max_record_bytes,
  'oversize record blocked before payload crosses into Lua')
 return true
end
return M
