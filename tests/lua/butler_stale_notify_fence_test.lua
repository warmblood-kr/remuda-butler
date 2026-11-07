-- Faithful stale _butler_notify probe (QA-verified RED on 2459718/43a89bd:
-- the captured candidate native-notify mutated the restored pending and
-- suppressed the current same-task delivery without any transport). Run via
-- tests/lua_tests.sh; the T harness boots the actual Butler image in a
-- disposable daemon. Raw core sinks are spied BEFORE main loads, so the real
-- dialogs module captures the spy as its originals.send; dialogs/notify/journal
-- themselves stay real.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))

T.eval([==[
  remuda._butler_argv = { "sh", "-c", "sleep 60" }
  remuda._butler_skip_relay = true
  remuda._butler_readiness_timeout = 1
  local spies = { sends = {}, keys = 0, types = 0, runs = {}, events = {},
    outcome = "accepted", journal_fail = false }
  remuda._t_spies = spies
  spies.real = { send = remuda.send, key = remuda.key, type_text = remuda.type_text,
    process_run = remuda.process and remuda.process.run }
  remuda.send = function(name, text)
    spies.sends[#spies.sends + 1] = { name = name, text = text }
    return true
  end
  remuda.key = function() spies.keys = spies.keys + 1; return true end
  remuda.type_text = function() spies.types = spies.types + 1; return true end
  local fs = remuda.fs
  local real_write = fs and fs.write_atomic
  if type(real_write) == "function" then
    fs.write_atomic = function(path, text, options)
      if type(path) == "string" and path:find("delivery%-journal", 1) then
        spies.events[#spies.events + 1] = "journal"
        if spies.journal_fail then return false, "test journal write failure" end
      end
      return real_write(path, text, options)
    end
  end
  remuda.process = remuda.process or {}
  remuda.process.run = function(options)
    spies.runs[#spies.runs + 1] = { argv = options.argv, stdin = options.stdin }
    spies.events[#spies.events + 1] = "run"
    if spies.outcome == "uncertain" then
      return { timed_out = true, code = 124, stdout = "", stderr = "timeout" }
    end
    return { code = 0, stdout = '{"outcome":"accepted_queue"}', stderr = "" }
  end
]==])

T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 10, "Butler root start")

T.test("stale compiled candidate deliver is inert before current",function()
 local result=T.eval([==[
 local path=os.getenv("XDG_DATA_HOME").."/remuda/mods/butler/packages/butler/notice.lua"
 local f=assert(io.open(path,"r"));local source=f:read("*a");f:close()
 local modified,n=source:gsub("\nbind_send_policy%s*%(%s*%)%s*$","\nbind_send_policy()\nremuda._qa_stale_deliver=remuda._butler_notify\nerror('stale-deliver-barrier')")
 assert(n==1,"bind barrier not injected")
 f=assert(io.open(path,"w"));f:write(modified);f:close()
 local ok,why=pcall(remuda._load_extension_command,"butler","butler",true)
 f=assert(io.open(path,"w"));f:write(source);f:close()
 assert(not ok and tostring(why):find("stale%-deliver%-barrier"),"candidate must fail")
 local stale=assert(remuda._qa_stale_deliver,"actual compiled candidate fn")
 local current=remuda._butler_notify
 assert(stale~=current,"actual stale/current functions must differ")
 local bus=remuda._butler_bus;local spies=remuda._t_spies
 bus.agents.m1={id="m1-id",kind="codex",instance_id="inst-1",parent="butler",alias="m1",native={mode="native",kind="codex",path="/private/tmp/t/manifest.json",nonce=string.rep("ab",16),session_token="row-1",row_id="row-1",instance="inst-1"}}
 remuda.ls=function()return{{name="m1",id="row-1",instance_id="inst-1",alive=true,attached=false}}end
 local mail=assert(remuda._butler_mail.queue("butler","m1","durable stale-first task","Task"))
 local text=remuda._butler_notice.mail_notice_text(mail,"from butler","codex")
 bus.notices.m1=nil
 local pending=bus.notices.m1
 local journal=remuda._butler_delivery_journal;local begin=journal.begin;local begins=0
 journal.begin=function(...)begins=begins+1;return begin(...)end
 local runs=#spies.runs
 stale("m1",text,mail.id)
 local stale_runs=#spies.runs-runs;local stale_begins=begins;local stale_dequeue=bus.notices.m1~=pending
 current("m1",text,mail.id)
 local current_runs=#spies.runs-runs-stale_runs;local current_begins=begins-stale_begins
 local positive=assert(remuda._butler_mail.queue("butler","m1","current positive task","Task"))
 local ptext=remuda._butler_notice.mail_notice_text(positive,"from butler","codex")
 bus.notices.m1=nil
 local rbefore=#spies.runs;local bbefore=begins
 current("m1",ptext,positive.id)
 assert(#spies.runs-rbefore==1 and begins-bbefore==1 and bus.notices.m1==nil,"restored old-current newTask positive failed")
 journal.begin=begin
 return table.concat({stale_runs,stale_begins,tostring(stale_dequeue),current_runs,current_begins,tostring(bus.notices.m1==nil)},"|")
 ]==])
 T.eq(result,"0|0|false|1|1|true","stale transport/begin/dequeue then current positive")
end)
