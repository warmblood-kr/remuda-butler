-- Verified owner adapters for the durable logical queue. No native host API,
-- approval-response RPC, startup key or shell command enters this plaintext FIFO.
local butler=assert(remuda.butler)
local approval, prepared=assert(butler.approval),assert(butler.approve_text)
local M={}
butler.owner_input=M -- Fail closed even if durable storage cannot be opened.
local function hash(text)return assert(butler.guard_approval.sha256)(text)end
local function frame(...)
  local out={};for _,v in ipairs({...})do v=tostring(v);out[#out+1]=#v..':'..v end
  return table.concat(out)
end
local paths=remuda._butler_paths or{}
local path=paths.data_home and(paths.data_home..'/remuda/butler/input-queue.json')
local store,store_error
if path then store,store_error=assert(remuda._butler_input_queue_module).open(path)
else store_error='durable_storage_unavailable' end
local guarded_write
if not butler.dialogs.register_queue_writer(function(write)guarded_write=write end) then
  guarded_write=nil
end
local function unavailable()return store_error or 'durable_storage_unavailable'end
function M.binding(session)
  if not store then return nil,unavailable()end
  if not prepared.target_session_allowed(session) then return nil,'unknown_session'end
  local id,marker=prepared.session_instance(session)
  if type(id)~='string' or type(marker)~='string' then return nil,'instance_binding_unavailable'end
  local ok,rows=pcall(remuda.ls)
  if not ok then return nil,'session_unavailable'end
  for _,row in ipairs(rows)do
    if row.name==session and row.alive and type(row.instance_id)=='string' and row.instance_id~='' then
      return{session=session,agent_id=id,session_marker=marker,instance_id=row.instance_id}
    end
  end
  return nil,'session_not_live'
end
local function same_target(r)
  local target,why=M.binding(r.session)
  if not target then return false,why end
  for _,key in ipairs({'agent_id','session_marker','instance_id'})do
    if r[key]~=target[key] then return false,'session_changed'end
  end
  return true
end
local function admissible(r)
  local cfg=remuda._butler_matrix_live_config or{}
  if not(cfg.allowed_senders and cfg.allowed_senders[r.owner]==true) then return false,'owner_not_allowed'end
  if r.route=='prepared' and cfg.approve_text~=true then return false,'approve_text_off'end
  if r.route=='owner_line' and cfg.typed_lines~=true then return false,'typed_lines_off'end
  local ok,allowed,why=pcall(remuda._butler_approved_text_policy,r.session)
  if not ok or allowed~=true then return false,ok and why or 'input_policy_error'end
  return same_target(r) -- Actual identity after policy/capture can yield.
end
local function approval_key(rec)return 'iq-'..hash(frame('prepared',rec.event_id,rec.nonce))end
local function line_key(event,room)return 'iq-'..hash(frame('owner_line',room,event.event_id))end
local function intact(r,rec)
  local d=type(rec.data)=='table'and rec.data or{}
  return r.route=='prepared' and r.approval_id==rec.id and r.approval_nonce==rec.nonce
    and r.text==d.registered_text and #r.text==tonumber(d.bytes)
    and r.session==d.session and r.agent_id==d.session_id and r.session_marker==d.session_marker
    and r.instance_id==d.core_instance
end
function M.accept_prepared(rec)
  if not store then return nil,unavailable()end
  local d=type(rec.data)=='table'and rec.data or{}
  if rec.kind~='approve_text' or rec.status~='approved' or type(d.registered_text)~='string'
      or #d.registered_text~=tonumber(d.bytes) or d.request_id~=rec.id or rec.delivery_started==true
      or type(rec.event_id)~='string' or type(rec.nonce)~='string' then return nil,'invalid_request'end
  local id=approval_key(rec)
  local old,why=store:get(id)
  if why then return nil,why end
  if old then
    if not intact(old,rec)then return nil,'request_id_conflict'end
    return store:accept(old) -- Same original owner proof even if association ACK was lost.
  end
  local target,why=M.binding(d.session)
  if not target then return nil,why end
  if target.agent_id~=d.session_id or target.session_marker~=d.session_marker
      or target.instance_id~=d.core_instance then return nil,'session_changed'end
  local r={id=id,route='prepared',submission='composite',text=d.registered_text,owner=rec.answered_by,event_id=rec.answer_event_id,
    approval_id=rec.id,approval_nonce=rec.nonce,
    origin_digest=hash(frame(rec.event_id,rec.nonce,d.registered_text,d.core_instance))}
  for key,value in pairs(target)do r[key]=value end
  return store:accept(r)
end
function M.lookup_owner(event,room)
  if not store or type(event)~='table' or type(event.event_id)~='string' then return nil end
  local r=store:get(line_key(event,room))
  if not r then return nil end
  local c=type(event.content)=='table'and event.content or{}
  if r.route~='owner_line' or r.owner~=event.sender or r.origin_digest~=hash(frame(room,event.sender,c.body or'')) then
    return nil,'request_id_conflict'
  end
  return r
end
function M.accept_line(session,text,event,room,live)
  if not store then return nil,unavailable()end
  local cfg=remuda._butler_matrix_live_config or{}
  if live~=true or not prepared.owner_event_allowed(event,{room_id=room,created_ms=event.origin_server_ts},cfg,true,room)
      then return nil,'owner_not_allowed'end
  local old,why=M.lookup_owner(event,room)
  if why then return nil,why end
  if old then return store:accept(old)end
  if not butler.typed_lines.accept({},event,os.time(),cfg) then return nil,'owner_not_allowed'end
  local target,why=M.binding(session);if not target then return nil,why end
  local r={id=line_key(event,room),route='owner_line',submission='composite+RET',text=text,owner=event.sender,event_id=event.event_id,
    origin_digest=hash(frame(room,event.sender,event.content.body))}
  for key,value in pairs(target)do r[key]=value end
  return store:accept(r)
end
local status_map={queued='queued',dispatch_intent='delivery_uncertain',uncertain='delivery_uncertain',
 quarantined='delivery_quarantined',delivered='applied',failed='failed',cancelled='denied'}
local function sync_approvals(records)
  if not store then return false end
  local rows=store:records();if not rows then return false end
  for _,r in ipairs(rows)do
    if r.route=='prepared' then
      local rec=records and records[r.approval_id] or approval.for_id(r.approval_id)
      if rec and intact(r,rec)then
        if rec.delivery_started==true and r.status=='queued' then
          local held=store:hold(r.id,'approval_marker_without_queue_intent')
          if not held then return false end;r.status='uncertain'
        end
        local status=status_map[r.status]
        if rec.status~=status or rec.queue_id~=r.id then
          if not approval.persist_queue_state(rec,status,r.id) then return false end
        end
      end
    end
  end
  return true
end
function M.bind_approval()
  approval.handler('approve_text',{
    approve=function(rec,complete)
      local receipt,why=M.accept_prepared(rec)
      if receipt then
        complete('queued')
        pcall(approval.reply,rec,'Queued prepared text '..receipt.id..'; status '..receipt.status..'.')
      else
        complete('retry',why);pcall(approval.reply,rec,'Not queued: '..tostring(why)..'.')
      end
    end,
    deny=function(rec)pcall(approval.reply,rec,'denied')end,
    expire=function(rec)pcall(approval.reply,rec,'expired before queue acceptance')end,
  })
end
local function deliver(r)
  if not guarded_write then return store:defer(r.id,'provider_identity_unavailable')end
  local matching,why=same_target(r)
  if not matching then
    if why=='session_changed'then return store:quarantine(r.id)end
    return store:defer(r.id,why)
  end
  local marked=false
  local hooks={expected_instance=r.instance_id,recheck=function()return admissible(r)end,identity=function()return same_target(r)end}
  hooks.before=function()
    if admissible(r)~=true then return false end
    local marker=store:begin(r.id);if not marker then return false end
    marked=true
    if r.route=='prepared' then
      local rec=approval.for_id(r.approval_id)
      if not rec or not intact(r,rec) or not approval.begin_delivery(rec)then return false end
    end
    return true
  end
  local ok,reason,_,_,provider=prepared.type_text(r.session,r.text,{owner=r.owner,event_id=r.event_id,
    request_id=r.id,queue_write=function(bytes)return guarded_write('type_text',r.session,hooks,bytes)end})
  if not marked then
    local current=store:get(r.id)
    if current and current.status=='dispatch_intent' then return store:hold(r.id,'marker_outcome_unknown')end
    if current and current.status=='queued' then
      local same,why=same_target(r)
      if not same and why=='session_changed'then return store:quarantine(r.id)end
      return store:defer(r.id,reason or 'writer_guard_refused')
    end
    return
  end
  local matching,changed=same_target(r)
  if not matching and changed=='session_changed' then
    store:finish(r.id,'uncertain','session_changed_after_intent')
    return store:quarantine(r.id)
  end
  if not ok or provider~='submitted' then
    return store:finish(r.id,'uncertain',provider=='late' and 'late' or provider=='unverified' and 'unverified' or 'post_intent_unknown')
  end
  if r.route=='owner_line' then
    -- Preserve this route's separate RET. Failure can never retry the text.
    local checked,result=pcall(guarded_write,'key',r.session,{expected_instance=r.instance_id,before=function()return admissible(r)end,
      recheck=function()return admissible(r)end,identity=function()return same_target(r)end},'RET')
    if not checked or result==false then return store:finish(r.id,'uncertain','separate_return_unknown')end
  end
  return store:finish(r.id,'delivered',r.route=='owner_line'and'submitted+RET'or'submitted')
end
local ticking=false
function M.tick()
  if ticking or not store then return end
  ticking=true
  local heads=store:heads()
  for index,r in ipairs(heads or{})do
    if index>4 then break end
    local ok=pcall(deliver,r)
    if not ok then
      local current=store:get(r.id)
      if current and current.status=='dispatch_intent'then store:hold(r.id,'dispatch_callback_unknown')
      elseif current and current.status=='queued'then store:defer(r.id,'callback_refused')end
    end
  end
  pcall(sync_approvals)
  ticking=false
end
function M.status()if not store then return nil,unavailable()end;return store:list()end
function M.resolve(id,disposition,who)
  if not store then return nil,unavailable()end
  local policy=butler.guard_policy
  local logged=policy and policy.append({session='owner',kind='owner',event='input_queue_resolution',
    tool='',class='other',summary=id..' '..disposition..' by '..who})
  if not logged then return nil,'audit_unavailable'end
  local result,why=store:resolve(id,disposition,who);if result then sync_approvals()end
  return result,why
end
approval.before_sweep('owner_input',sync_approvals)
approval.tick('owner_input',M.tick)
M.bind_approval()
return M
