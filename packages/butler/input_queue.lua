-- Durable logical plaintext intents. This is not a physical writer or an auth
-- boundary; only the verified owner adapters may accept production requests.
local M = {}
local FINAL = {delivered=true,failed=true,cancelled=true}
local STATES = {queued=true,dispatch_intent=true,uncertain=true,quarantined=true,
 delivered=true,failed=true,cancelled=true}
local LIMIT, PENDING, BYTES, FILE = 256, 32, 2*1024*1024, 3*1024*1024
local function string_ok(v, limit) return type(v)=='string' and #v>0 and #v<=(limit or 512) end
local FIELDS = {'id','route','submission','text','session','agent_id','session_marker','instance_id',
 'owner','event_id','approval_id','approval_nonce','origin_digest'}
local function digest(record, hash)
  local parts={}
  for _,key in ipairs(FIELDS) do
    local v=record[key] or '';parts[#parts+1]=#v..':'..v
  end
  return hash(table.concat(parts))
end
local function valid(record, hash)
  if type(record)~='table' or not string_ok(record.id) or not string_ok(record.text,8192)
      or (record.route~='prepared' and record.route~='owner_line') then return false end
  for _,key in ipairs({'session','agent_id','session_marker','instance_id','owner','event_id'}) do
    if not string_ok(record[key]) then return false end
  end
  if (record.route=='prepared' and record.submission~='composite')
      or (record.route=='owner_line' and record.submission~='composite+RET') then return false end
  for _,key in ipairs(FIELDS)do
    local v=record[key]
    if key~='text' and v~=nil and (type(v)~='string' or #v>512 or v:find('%c')) then return false end
  end
  if type(record.origin_digest)~='string' or #record.origin_digest~=64 or not record.origin_digest:match('^%x+$') then return false end
  if record.route=='prepared' then
    if not string_ok(record.approval_id) or not string_ok(record.approval_nonce) then return false end
  elseif record.text:find('[\r\n]') then return false end
  return record.digest==nil or record.digest==digest(record,hash)
end
local function stream(record)
  local parts={}
  for _,key in ipairs({'session','agent_id','session_marker','instance_id'}) do
    local v=record[key];parts[#parts+1]=#v..':'..v
  end
  return table.concat(parts)
end
local function receipt(record)
  return {id=record.id,status=record.status,sequence=record.sequence,session=record.session,
    instance_id=record.instance_id,reason=record.reason,provider_status=record.provider_status,
    retry_at=record.retry_at,attempts=record.attempts,accepted_at=record.accepted_at,
    resolved_by=record.resolved_by,previous_status=record.previous_status,
    may_have_written=record.dispatch_at~=nil or record.status=='uncertain' or record.status=='dispatch_intent'
      or record.previous_status=='uncertain' or record.previous_status=='dispatch_intent'}
end
local function find(state,id)
  for _,r in ipairs(state.records)do if r.id==id then return r end end
end
function M.open(path)
  local fs, json = remuda.fs, remuda.json
  local hash=remuda.butler and remuda.butler.guard_approval and remuda.butler.guard_approval.sha256
  if not(fs and type(fs.lock)=='function' and type(fs.write_atomic)=='function'
      and type(fs.realpath)=='function' and type(fs.is_symlink)=='function'
      and json and type(hash)=='function') then return nil,'durable_storage_unavailable' end
  if not string_ok(path,4096) then return nil,'invalid_path' end
  local parent, name=path:match('^(.*)[/\\]([^/\\]+)$')
  if not parent then return nil,'invalid_path' end
  local canonical=fs.realpath(parent)
  if not canonical then return nil,'private_parent_unavailable' end
  local system=remuda._butler_system
  if not system or type(system.join_path)~='function'then return nil,'storage_path_unavailable'end
  path=system.join_path(canonical,name)
  local busy=false
  local function load()
    if fs.realpath(parent)~=canonical then return nil,'storage_parent_changed' end
    -- A surviving namespace witness prevents a missing ledger from silently
    -- becoming a fresh queue after an acknowledged request. Removing both is
    -- external data destruction, outside this filesystem durability contract.
    local witness=path..'.initialized'
    local marked,mark_error=fs.is_symlink(witness)
    local missing=marked==nil and mark_error=='not_found'
    if not missing and marked~=false then return nil,'storage_unavailable' end
    if not missing then
      local f=io.open(witness,'rb');if not f then return nil,'storage_unavailable' end
      local content=f:read(64);f:close()
      if content~='input-queue-v1\n' then return nil,'storage_witness_invalid' end
    end
    local link,why=fs.is_symlink(path)
    if link==nil and why=='not_found' then
      if not missing then return nil,'storage_missing' end
      -- Witness first: a failed initial creation safely requires recovery,
      -- rather than allowing later acceptance over an uncertain namespace.
      if fs.write_atomic(witness,'input-queue-v1\n',{private=true})~=true then
        return nil,'storage_uncertain'
      end
      local empty={version=1,sequence=0,records={}}
      if fs.write_atomic(path,'{"version":1,"sequence":0,"records":[]}',{private=true})~=true then
        return nil,'storage_uncertain'
      end
      return empty
    end
    if missing then return nil,'storage_witness_missing' end
    if link~=false then return nil,'storage_unavailable' end
    local f=io.open(path,'rb');if not f then return nil,'storage_unreadable' end
    local body=f:read(FILE+1);f:close()
    if #body>FILE then return nil,'storage_too_large' end
    local ok,state=pcall(json.decode,body)
    if not ok or type(state)~='table' or state.version~=1 or type(state.records)~='table'
        or type(state.sequence)~='number' or state.sequence<0 or #state.records>LIMIT then return nil,'storage_invalid' end
    for key in pairs(state.records)do
      if type(key)~='number' or key%1~=0 or key<1 or key>#state.records then return nil,'storage_invalid' end
    end
    local ids,last={},0
    for _,r in ipairs(state.records)do
      if type(r.digest)~='string' or not valid(r,hash) or not STATES[r.status] or type(r.sequence)~='number'
          or r.sequence<=last or r.sequence>state.sequence or ids[r.id] then return nil,'storage_invalid' end
      ids[r.id],last=true,r.sequence
    end
    return state
  end
  local function transaction(fn)
    if busy then return nil,'storage_busy' end
    busy=true
    local locked,lock,why=pcall(fs.lock,path..'.lock')
    if not locked or not lock then busy=false;return nil,why=='held' and 'storage_busy' or 'storage_unavailable' end
    local ok,result,reason=pcall(function()
      local state,err=load();if not state then return nil,err end
      local value,dirty,err=fn(state)
      if dirty then
        local body=json.encode(state)
        if #body>FILE then return nil,'storage_too_large' end
        local written=fs.write_atomic(path,body,{private=true})
        if written~=true then return nil,'storage_uncertain' end
      end
      return value,err
    end)
    pcall(function()lock:release()end);busy=false
    if not ok then return nil,'storage_uncertain' end
    return result,reason
  end
  local q={}
  function q:accept(request)
    if not valid(request,hash) then return nil,'invalid_request' end
    return transaction(function(state)
      local prior=find(state,request.id)
      if prior then
        if prior.digest~=digest(request,hash) then return nil,false,'request_id_conflict' end
        local result=receipt(prior);result.duplicate=true
        return result,true -- Reaffirm fsync after a lost/uncertain acceptance ACK.
      end
      local total,pending=0,0
      for _,r in ipairs(state.records)do
        total=total+#r.text
        if stream(r)==stream(request) and not FINAL[r.status] then pending=pending+1 end
      end
      if #state.records>=LIMIT or pending>=PENDING or total+#request.text>BYTES then return nil,false,'queue_full' end
      local r={}
      for _,key in ipairs(FIELDS)do r[key]=request[key] or '' end
      state.sequence=state.sequence+1
      r.sequence,r.status,r.accepted_at,r.attempts=state.sequence,'queued',os.time(),0
      r.digest=digest(r,hash);state.records[#state.records+1]=r
      return receipt(r),true
    end)
  end
  function q:get(id)
    return transaction(function(state)return find(state,id),false end)
  end
  function q:records()
    return transaction(function(state)return state.records,false end)
  end
  function q:list()
    return transaction(function(state)
      local out={};for _,r in ipairs(state.records)do out[#out+1]=receipt(r)end;return out,false
    end)
  end
  function q:heads()
    return transaction(function(state)
      local out,seen={},{}
      for _,r in ipairs(state.records)do
        local key=stream(r)
        if not FINAL[r.status] and not seen[key] then
          seen[key]=true
          if r.status=='queued' and (not r.retry_at or r.retry_at<=os.time()) then out[#out+1]=r end
        end
      end
      return out,false
    end)
  end
  function q:defer(id,reason)
    return transaction(function(state)
      local r=find(state,id);if not r or r.status~='queued' then return nil,false,'state_changed' end
      r.attempts=math.min(30,(r.attempts or 0)+1)
      r.retry_at=os.time()+math.min(300,2^math.min(8,r.attempts))
      r.reason=type(reason)=='string' and #reason<=64 and reason:match('^[%w_]+$') and reason or 'admission_unknown';return receipt(r),true
    end)
  end
  function q:begin(id)
    return transaction(function(state)
      local r=find(state,id);if not r or r.status~='queued' then return nil,false,'state_changed' end
      for _,earlier in ipairs(state.records)do
        if earlier.id==r.id then break end
        if stream(earlier)==stream(r) and not FINAL[earlier.status] then return nil,false,'head_blocked' end
      end
      r.status,r.dispatch_at,r.reason='dispatch_intent',os.time(),nil
      return receipt(r),true
    end)
  end
  function q:hold(id,reason)
    return transaction(function(state)
      local r=find(state,id)
      if not r or (r.status~='queued' and r.status~='dispatch_intent') then return nil,false,'state_changed' end
      r.status,r.reason='uncertain',reason
      return receipt(r),true
    end)
  end
  function q:finish(id,status,provider)
    if status~='delivered' and status~='uncertain' then return nil,'invalid_outcome' end
    return transaction(function(state)
      local r=find(state,id)
      if not r or r.status~='dispatch_intent' then return nil,false,'state_changed' end
      r.status,r.provider_status,r.completed_at=status,provider,os.time()
      return receipt(r),true
    end)
  end
  function q:quarantine(id)
    return transaction(function(state)
      local first=find(state,id);if not first then return nil,false,'not_found' end
      for _,r in ipairs(state.records)do
        if stream(r)==stream(first) and not FINAL[r.status] and r.status~='quarantined' then
          r.previous_status,r.status,r.reason=r.status,'quarantined','session_replaced'
        end
      end
      return receipt(first),true
    end)
  end
  function q:resolve(id,disposition,who)
    if not string_ok(who) then return nil,'owner_required' end
    return transaction(function(state)
      local r=find(state,id);if not r then return nil,false,'not_found' end
      if disposition=='cancel' and (r.status=='queued' or (r.status=='quarantined' and r.previous_status=='queued')) then
        r.status='cancelled'
      elseif (r.status=='uncertain' or r.status=='quarantined') and disposition=='not_sent' then r.status='failed'
      elseif (r.status=='uncertain' or r.status=='quarantined') and disposition=='delivered' then r.status='delivered'
      else return nil,false,'resolution_refused' end
      r.resolved_by,r.reason,r.completed_at=who,'owner_resolution_'..disposition,os.time()
      return receipt(r),true
    end)
  end
  local recovered,why=transaction(function(state)
    local changed=false
    for _,r in ipairs(state.records)do
      if r.status=='dispatch_intent' then r.status,r.reason='uncertain','restart_during_dispatch';changed=true end
    end
    return true,changed
  end)
  if not recovered then return nil,why end
  return q
end
remuda._butler_input_queue_module = M
return M
