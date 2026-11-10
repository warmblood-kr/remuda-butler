-- QA owns this file. Runs against product when present, never a fake certifier.
local target = 'packages/butler/inbox_authority.lua'
local file = io.open(target, 'r')
if file then file:close() else target = 'packages/butler/inbox_authority_contract.lua' end
local authority = dofile(target)
local failures, total = {}, 0
local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end
local function snapshot()
  local deliveries = {}
  for index, id in ipairs({'A', 'B', 'C'}) do
    deliveries[index] = { message_id=id, seq=index, envelope_ref='messages/'..id,
      object_ref='objects/'..id, metadata='{"identity":"'..id..'"}' }
  end
  deliveries[1].resent = '{"note":"last"}'
  return { deliveries=deliveries, reads={B=true, LEGACY_ORPHAN=true} }
end
local function context()
  return { root='/private/qa-mail', recipient='726563697069656e74', epoch=2,
    source_before='full-content-generation-1', source_after='full-content-generation-1',
    db_snapshot='sql-snapshot-42', complete=true,
    writer={owner=true,guarded=true,root='/private/qa-mail'} }
end
local function check(condition, message)
  assert(condition, message)
end
local function positive(source, actual, proof)
  local certificate, err = authority.certify(source, actual, proof)
  check(certificate ~= nil, 'exact positive rejected: '..tostring(err and err.code))
  check(err == nil, 'successful certificate has error')
  check(certificate.state == 'match', 'missing match state')
  for _, field in ipairs({'root','recipient','epoch','db_snapshot'}) do
    check(certificate[field] == proof[field], 'wrong certificate '..field)
  end
  check(certificate.source == proof.source_before, 'wrong source witness')
  local reads=0
  for _ in pairs(source.reads) do reads=reads+1 end
  check(certificate.deliveries == #source.deliveries and certificate.reads == reads, 'wrong exact counts including orphan read')
end
local function run(name, fn)
  total=total+1
  local ok, err=pcall(fn)
  if not ok then failures[#failures+1]=name..': '..tostring(err) end
end
local function reject(name, mutation, code, field)
  run(name, function()
    local source, proof=snapshot(), context()
    positive(source,copy(source),proof)
    local actual=copy(source)
    mutation(source,actual,proof)
    local certificate, err=authority.certify(source,actual,proof)
    check(certificate == nil, 'drift certified')
    check(type(err)=='table' and err.code==code, 'expected '..code..', got '..tostring(err and err.code))
    if field then check(err.field==field, 'wrong drift field '..tostring(err.field)) end
  end)
end
run('exact canonical snapshot and orphan reads', function()
  local source=snapshot()
  positive(source,copy(source),context())
end)
run('proven empty differs from unknown',function()
  positive({deliveries={},reads={}},{deliveries={},reads={}},context())
end)
run('nonempty all read remains valid',function()
  local source=snapshot()
  source.reads.A=true; source.reads.C=true
  positive(source,copy(source),context())
end)
run('empty delivered preserves legacy orphan reads',function()
  local source={deliveries={},reads={LEGACY_ORPHAN=true}}
  positive(source,copy(source),context())
end)
reject('actual non-dense seq invalid',function(_,a) a.deliveries[2].seq=9 end,'invalid_snapshot')
reject('actual duplicate identity invalid',function(_,a) a.deliveries[2].message_id='A' end,'invalid_snapshot')
reject('source non-dense seq invalid',function(s) s.deliveries[2].seq=9 end,'invalid_snapshot')
reject('source read false is invalid shape',function(s) s.reads.B=false end,'invalid_snapshot')
reject('actual read false is invalid shape',function(_,a) a.reads.B=false end,'invalid_snapshot')
reject('root missing invalid',function(_,_,c) c.root=nil end,'invalid_snapshot')
reject('recipient not hex invalid',function(_,_,c) c.recipient='not-hex' end,'invalid_snapshot')
reject('fractional epoch invalid',function(_,_,c) c.epoch=1.5 end,'invalid_snapshot')
reject('source hidden nonarray delivery invalid',function(s) s.deliveries.extra={message_id='HIDDEN'} end,'invalid_snapshot')
reject('actual hidden nonarray delivery invalid',function(_,a) a.deliveries.extra={message_id='HIDDEN'} end,'invalid_snapshot')
reject('source sparse delivery hole invalid',function(s) s.deliveries[2]=nil end,'invalid_snapshot')
reject('actual sparse delivery hole invalid',function(_,a) a.deliveries[2]=nil end,'invalid_snapshot')
reject('source zero delivery key invalid',function(s) s.deliveries[0]=s.deliveries[1] end,'invalid_snapshot')
reject('actual fractional delivery key invalid',function(_,a) a.deliveries[1.5]=a.deliveries[1] end,'invalid_snapshot')
reject('blank before witness invalid',function(_,_,c) c.source_before='' end,'invalid_snapshot')
reject('blank after witness invalid',function(_,_,c) c.source_after='' end,'invalid_snapshot')
reject('blank SQL snapshot invalid',function(_,_,c) c.db_snapshot='' end,'invalid_snapshot')
reject('negative epoch invalid',function(_,_,c) c.epoch=-1 end,'invalid_snapshot')
reject('equal count substituted delivery', function(_,a) a.deliveries[2].message_id='X' end, 'parity_mismatch','delivery')
reject('equal count dense reordered rows', function(_,a)
  a.deliveries[1],a.deliveries[2]=a.deliveries[2],a.deliveries[1]
  a.deliveries[1].seq,a.deliveries[2].seq=1,2
end, 'parity_mismatch','delivery')
reject('equal count swapped read membership', function(_,a) a.reads.B=nil; a.reads.A=true end,'parity_mismatch','read')
reject('legacy orphan read cannot disappear', function(_,a) a.reads.LEGACY_ORPHAN=nil end,'parity_mismatch','read')
reject('unexpected orphan read cannot appear', function(_,a) a.reads.EXTRA=true end,'parity_mismatch','read')
reject('last resent lost', function(_,a) a.deliveries[1].resent=nil end,'parity_mismatch','resent')
reject('last resent replaced with old annotation', function(_,a) a.deliveries[1].resent='{"note":"first"}' end,'parity_mismatch','resent')
reject('envelope identity changed', function(_,a) a.deliveries[2].envelope_ref='messages/X' end,'parity_mismatch','refs')
reject('body identity changed', function(_,a) a.deliveries[2].object_ref='objects/X' end,'parity_mismatch','refs')
reject('same length preserved metadata changed', function(_,a) a.deliveries[2].metadata='{"identity":"X"}' end,'parity_mismatch','metadata')
reject('incomplete source cannot certify', function(_,_,c) c.complete=false end,'partial')
reject('unguarded writer', function(_,_,c) c.writer.guarded=false end,'writer_conflict')
reject('nonowner writer', function(_,_,c) c.writer.owner=false end,'writer_conflict')
reject('wrong root writer', function(_,_,c) c.writer.root='/other/root' end,'writer_conflict')
reject('source changed around SQL snapshot', function(_,_,c) c.source_after='different-full-content' end,'stale_generation')
reject('missing witness is invalid', function(_,_,c) c.source_before=nil end,'invalid_snapshot')
reject('invalid wins over partial', function(_,_,c) c.epoch='two'; c.complete=false end,'invalid_snapshot')
reject('partial wins over writer conflict', function(_,_,c) c.complete=false; c.writer.owner=false end,'partial')
reject('writer conflict wins over stale', function(_,_,c) c.writer.owner=false; c.source_after='changed' end,'writer_conflict')
reject('stale wins over row drift', function(_,a,c) c.source_after='changed'; a.deliveries[2].message_id='X' end,'stale_generation')
if #failures>0 then error('authority contract '..#failures..'/'..total..' failed ['..target..']\n'..table.concat(failures,'\n')) end
print('PASS authority contract '..total..' cases ['..target..']')
