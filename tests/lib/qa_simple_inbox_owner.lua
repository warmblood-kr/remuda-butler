local host=getmetatable(_G).__index.remuda
assert(assert(loadfile('tests/lib/isolated_test.lua'))()(host))
return {api='remuda-module-v1',state_version=1,
 initialize=function()
   local db,err=host.db.open('inbox',{migrations=true})
   assert(db,'native inbox open failed: '..tostring(err))
   return {db=db}
 end,
 start=function(state)
   local index=assert(loadfile('packages/butler/inbox_sqlite_simple.lua'))()
   local root=assert(os.getenv('SIMPLE_MAIL_ROOT'))
   local files={'6161.jsonl'}
   assert(index.import(state.db,root,files,host.json))
   local rows=assert(index.unread(state.db,'6161'))
   assert(#rows==1 and rows[1].message_id=='A' and rows[1].body=='body A')
   local count=assert(state.db:query("SELECT message_id,is_read FROM simple_inbox WHERE recipient=? ORDER BY seq",{'6161'}))
   assert(#count==2 and count[1].message_id=='B' and count[2].message_id=='A','import order')
   assert(index.mark_read(state.db,'6161','A'))
   assert(#assert(index.unread(state.db,'6161'))==0)
   assert(index.deliver(state.db,'6161','C','{"id":"C"}','body C','{"message_id":"C"}'))
   assert(state.db:close())
   state.db=assert(host.db.open('inbox',{migrations=true}))
   assert(index.import(state.db,root,files,host.json))
   rows=assert(index.unread(state.db,'6161'))
   assert(#rows==1 and rows[1].message_id=='C' and rows[1].body=='body C','restart must preserve reads and new mail')
   return 'simple SQLite import and read ok'
 end,
 stop=function(state) pcall(state.db.close,state.db) end}
