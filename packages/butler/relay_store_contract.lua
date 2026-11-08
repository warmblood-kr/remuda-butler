-- Executable ABSTRACT factory for design/QA binding. This is not relay_store,
-- registers nothing and never opens SQL, publishes a marker or touches files.
-- Trusted root-owned providers supply capabilities; caller booleans are not
-- proof. All authority methods deliberately return not_implemented (QA RED).
local M = {}
M.version = 1
M.limits = {source_bytes=32*1024*1024,record_bytes=256*1024,
 record_nodes=8192,page_rows=64,marker_bytes=4096,digest_chunk_bytes=65536,
 db_bytes=256*1024*1024,sql_timeout_ms=2000}
M.methods = {'import_prepare','import_source','import_batch','import_acks',
 'verify_import','activate','writer','cursor','accept_batch','dispatch_page',
 'complete_dispatch','get','put','delete','page','resolve_operation',
 'reply_dispatch_page','claim_reply','complete_reply','fail_reply','status'}
local requirements = {
 db={'acquire'},marker={'read','publish'},anchors={'inspect'},
 owner={'acquire','check','describe','release'},
 json={'decode_record','encode_record'},digest={'sha256'},
}
local function error_result(code,detail) return nil,code..': '..detail end
local function invoke(fn,...)
 local ok,value,why=pcall(fn,...)
 if not ok then return nil,'provider_error: '..tostring(value) end
 return value,why
end
local function identifier(value)
 return type(value)=='string' and #value>0 and #value<=256
  and not value:find('[%c]')
end
local function validate(opts)
 if type(opts)~='table' then return error_result('options','table required') end
 for provider,names in pairs(requirements) do
  if type(opts[provider])~='table' then return error_result('options','missing '..provider) end
  for _,name in ipairs(names) do
   if type(opts[provider][name])~='function' then
    return error_result('options','missing '..provider..'.'..name)
   end
  end
 end
 local identity=opts.identity
 if type(identity)~='table' then return error_result('identity','table required') end
 for _,name in ipairs({'root_id','account_id','device_id','relay_id'}) do
  if not identifier(identity[name]) then return error_result('identity','invalid '..name) end
 end
 if opts.limits~=nil and type(opts.limits)~='table' then
  return error_result('limits','table required')
 end
 if opts.faults~=nil and type(opts.faults)~='function' then
  return error_result('options','faults must be function or nil')
 end
 for name,ceiling in pairs(M.limits) do
  local v=opts.limits and opts.limits[name] or ceiling
  if type(v)~='number' or v<1 or v>ceiling or v%1~=0 then
   return error_result('limits','invalid '..name)
  end
 end
 return true
end

function M.open(opts)
 local valid,why=validate(opts);if not valid then return nil,why end
 -- No fabricated quiescence flags accepted: only root provider's capability.
 local cap,reason=invoke(opts.owner.acquire,opts.identity)
 if not cap then return error_result('blocked',reason or 'legacy_owner_unknown') end
 local closed=false
 local function release(disposition)
  if closed then return true end
  closed=true
  return invoke(opts.owner.release,cap,disposition)
 end
 local checked,check_error=invoke(opts.owner.check,cap,'open',opts.identity)
 if not checked then release('refused');return error_result('blocked',check_error or 'owner_fence') end
 local proof,proof_error=invoke(opts.owner.describe,cap)
 if type(proof)~='table' or proof.root_id~=opts.identity.root_id
  or not identifier(proof.owner_id) or type(proof.epoch)~='number'
  or proof.epoch<1 or proof.epoch%1~=0 then
  release('refused');return error_result('blocked',proof_error or 'owner_identity')
 end
 -- The abstract object does not interpret marker/anchor data or claim to be
 -- active. Native adapter binds the exact opts to the eventual implementation.
 local store={abstract=true,contract_version=1}
 for _,method in ipairs(M.methods) do
  local name=method
  store[name]=function()
   if closed then return error_result('closed','store lease released') end
   return error_result('not_implemented',name)
  end
 end
 function store:close() return release('closed') end
 return store
end
return M
