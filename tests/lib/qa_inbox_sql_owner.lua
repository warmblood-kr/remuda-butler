local host=getmetatable(_G).__index.remuda
assert(assert(loadfile('tests/lib/isolated_test.lua'))()(host))
return {api='remuda-module-v1',state_version=1,
 initialize=function()
   assert(type(host.db)=='table','REAL_SQL_UNAVAILABLE: cannot skip SQL proof')
   local handle,err=host.db.open('inbox',{migrations=true})
   assert(handle,'native inbox open failed '..tostring(err))
   return {db=handle}
 end,
 start=function(state)
   host._qa_native_inbox_handle=state.db
   host._qa_reopen_inbox=function()
     return host.db.open('inbox',{migrations=true})
   end
   local selected=os.getenv('REMUDA_SQL_TEST_FILE') or 'tests/butler_inbox_progress_contract.lua'
   assert(selected=='tests/butler_inbox_progress_contract.lua' or selected=='tests/butler_inbox_source_advance_contract.lua' or selected=='tests/butler_inbox_store_contract.lua','unexpected SQL test entry')
   return dofile(selected)
 end,
 stop=function(state) pcall(state.db.close,state.db) end}
