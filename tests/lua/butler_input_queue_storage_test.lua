-- Real core storage primitives, disposable harness daemons only. No panes.
T.test('private atomic queue record survives daemon restart and excludes another writer', function()
  local path=assert(os.getenv('REMUDA_LUA_SCRATCH'))..'/queue-probe.json'
  local code=([[
    assert(type(remuda.fs.write_atomic)=='function' and type(remuda.fs.lock)=='function')
    local lock,why=remuda.fs.lock(%q..'.lock');assert(lock,why);_queue_probe_lock=lock
    assert(remuda.fs.write_atomic(%q,'{"id":"probe","state":"queued"}',{private=true}))
    local f=assert(io.open(%q,'rb'));local body=f:read('*a');f:close()
    assert(body=='{"id":"probe","state":"queued"}')
    return 'committed'
  ]]):format(path,path,path)
  T.eq(T.eval(code),'committed')
  local lock,why=remuda.fs.lock(path..'.lock')
  T.eq(lock,nil,'other daemon must not acquire child writer lock');T.eq(why,'held')
  if package.config:sub(1,1)=='/' then
    local mode=remuda.process.run{argv={'stat','-f','%Lp',path},timeout=5}
    if mode.code~=0 or not tostring(mode.stdout):match('^600%s*$') then
      mode=remuda.process.run{argv={'stat','-c','%a',path},timeout=5}
    end
    T.eq(mode.code,0);T.ok(mode.stdout:match('^600%s*$'),'queue file is owner-only')
  end
  local stopped=remuda.process.run{argv={assert(os.getenv('REMUDA_BIN')),'-s',assert(os.getenv('REMUDA_LUA_CHILD_SERVER')),'stop','-f'},timeout=10}
  T.eq(stopped.code,0,'stop only disposable child')
  T.eq(T.eval(([[
    local f=assert(io.open(%q,'rb'));local body=f:read('*a');f:close()
    assert(body=='{"id":"probe","state":"queued"}')
    local lock,why=remuda.fs.lock(%q..'.lock');assert(lock,why)
    assert(remuda.fs.write_atomic(%q,'{"id":"probe","state":"delivered"}',{private=true}))
    local wrote=remuda.fs.write_atomic(%q..'/invalid','bad',{private=true})
    assert(not wrote,'storage failure cannot report accepted')
    local f=assert(io.open(%q,'rb'));local body=f:read('*a');f:close()
    assert(body=='{"id":"probe","state":"delivered"}')
    assert(lock:release());return 'recovered'
  ]]):format(path,path,path,path,path)),'recovered')
  lock,why=remuda.fs.lock(path..'.lock');T.ok(lock,why);T.ok(lock:release())
end)
