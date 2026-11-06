-- Real main proof for the new-task mail policy: a known kind receives the full
-- brief as durable Task mail and only a canonical pointer, never the body.
-- Read-only removals: the legacy typed first-task tests it supersedes are gone.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
-- The audited legacy wakeup keeps the original send; spy it before main installs
-- dialogs so the pointer (not the body) is visible without a live model.
T.eval([[
  remuda._task_spy = { legacy = {}, reports = {} }
  remuda.send = function(name, text)
    remuda._task_spy.legacy[#remuda._task_spy.legacy + 1] = { name = name, text = text }
    return true
  end
  remuda._butler_argv = {"sh", "-c", "sleep 60"}
  remuda._butler_skip_relay = true
]])
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
    :match("^%s*true%s*$") ~= nil
end, 5, "Butler root start")

T.eval(string.format([[
  remuda.butler.project_home(%q)
  remuda._butler_agent_builders.codex = function() return { "sleep", "100" } end
  remuda._butler_agent_startup.codex = { ready = function() return true end }
  remuda._butler_notify_policy = function() return true end
  remuda._t = { typed = {} }
  remuda.session = function() return { is_busy = false } end
  remuda.capture = function() return "› " end
  remuda.type_text = function(name, text) remuda._t.typed[name] = text end
]], os.getenv("XDG_DATA_HOME") .. "/projects"))

T.test("known-kind new task is durable mail and only a canonical pointer", function()
  local name = "task-mail-codex"
  local body = "full delegated brief\n" .. string.rep("z", 9000) .. "\nEND-OF-BRIEF"
  T.eval("remuda._butler_bus.pending_tasks.old = true")
  T.eval(string.format("remuda._butler_topic_delegate(%q, %q, nil, 'codex', 'butler')",
    name, body))
  T.wait_until(function()
    return T.eval(string.format("return tostring(remuda._butler_bus.agents[%q] ~= nil)", name))
      :match("^%s*true%s*$") ~= nil
  end, 25, "agent created")
  T.wait_until(function()
    return T.eval(string.format([[
      local n = remuda._butler_bus.notices[%q]
      return tostring(n ~= nil and n.count > 0)
    ]], name)):match("^%s*true%s*$") ~= nil
  end, 10, "task notice queued")
  T.eval(string.format("remuda._butler_notice.deliver_notice(%q)", name))

  T.wait_until(function()
    return T.eval(string.format([[
      for _, row in ipairs(remuda._task_spy.legacy) do
        if row.name == %q and row.text:find("Butler message ", 1, true) then return "true" end
      end
      return "false"
    ]], name)):match("^%s*true%s*$") ~= nil
  end, 10, "canonical pointer")

  local result = T.eval(string.format([=[
    local name = %q
    local body = %q
    local pointer, body_in_pointer, typed = nil, false, remuda._t.typed[name]
    for _, row in ipairs(remuda._task_spy.legacy) do
      if row.name == name and row.text:find("Butler message ", 1, true) then pointer = row.text end
      if row.text:find("END-OF-BRIEF", 1, true) then body_in_pointer = true end
    end
    local inbox = remuda._butler_inbox(name)
    local id = pointer and pointer:match("Butler message (%%S+)")
    local record = remuda._butler_bus.first_task_delivery and remuda._butler_bus.first_task_delivery[name]
    return table.concat({
      "pointer=" .. tostring(pointer ~= nil),
      "id=" .. tostring(id ~= nil and inbox:find(id, 1, true) ~= nil),
      "body=" .. tostring(inbox:find("END-OF-BRIEF", 1, true) ~= nil),
      "exact=" .. tostring(inbox:find(body, 1, true) ~= nil),
      "body_in_pointer=" .. tostring(body_in_pointer),
      "typed=" .. tostring(typed ~= nil),
      "first_record=" .. tostring(record ~= nil),
      "old_pending=" .. tostring(remuda._butler_bus.pending_tasks.old == true),
    }, "|")
  ]=], name, body))
  T.eq(result,
    "pointer=true|id=true|body=true|exact=true|body_in_pointer=false|typed=false|first_record=false|old_pending=true")
end)

T.test("a real storage failure writes nothing, keeps the brief and is visible", function()
  local name = "task-mail-store-fail"
  local body = "unsaved brief\n" .. string.rep("f", 3000)
  -- Make only the shared objects directory read-only. The Task body write is
  -- the commit point, so this fails exactly like a full/unwritable mail store
  -- while the roster, identities and launch directories stay writable. Count
  -- native helper verbs so a fallback body/helper path is visible as nonzero.
  T.eval([[
    remuda._task_spy.helper = 0
    remuda._task_spy.original_run = remuda.process.run
    remuda.process.run = function(spec)
      local verb = type(spec.argv) == "table" and spec.argv[2]
      if verb == "_agent_notice" or verb == "_codex_notice" or verb == "_claude_notice" then
        remuda._task_spy.helper = remuda._task_spy.helper + 1
      end
      return remuda._task_spy.original_run(spec)
    end
    remuda.mkdir(remuda._butler_mail_config.root .. "/objects")
    local ok, why = os.execute("chmod a-w '" .. remuda._butler_mail_config.root .. "/objects'")
    assert(ok, why)
  ]])
  local observed, observe_err = pcall(function()
    T.eval(string.format("remuda._butler_topic_delegate(%q, %q, nil, 'codex', 'butler')",
      name, body))
    -- Keep the injection active until the launch has recorded BOTH the visible
    -- failure and the retained brief; restoring earlier would race the launch.
    T.wait_until(function()
      return T.eval(string.format([[
        local a=remuda._butler_bus.agents[%q]
        local f=remuda._butler_bus.launch_failures and remuda._butler_bus.launch_failures[%q]
        return tostring(a ~= nil and a.task == %q and f ~= nil)
      ]], name, name, body)):match("^%s*true%s*$") ~= nil
    end, 25, "visible storage failure with a retained brief")
  end)
  local restored, restore_err = pcall(function()
    T.eval([[remuda.process.run = remuda._task_spy.original_run
      os.execute("chmod u+w '" .. remuda._butler_mail_config.root .. "/objects'")]])
  end)
  T.ok(observed, "delegate with a failing mail store: " .. tostring(observe_err))
  T.ok(restored, "restore the mail store and process seam: " .. tostring(restore_err))
  local result = T.eval(string.format([=[
    local name=%q
    local body=%q
    local bus=remuda._butler_bus
    local agent=bus.agents[name]
    local failure=bus.launch_failures and bus.launch_failures[name]
    local record=bus.first_task_delivery and bus.first_task_delivery[name]
    local writes=0
    for _,m in pairs(bus.messages or {}) do
      if m.subject=="Task" then
        local obj=bus.objects[(m.body or {}).object_id]
        if obj and tostring(obj.content):find("unsaved brief",1,true) then writes=writes+1 end
      end
    end
    return table.concat({
      "failure=" .. tostring(failure ~= nil
        and tostring(failure.error):find("not saved",1,true) ~= nil),
      "attempts=" .. tostring(failure ~= nil and type(failure.attempts) == "table"),
      "brief=" .. tostring(agent and agent.task == body),
      "writes=" .. tostring(writes),
      "helper=" .. tostring(remuda._task_spy.helper),
      "typed=" .. tostring(remuda._t.typed[name] ~= nil),
      "first=" .. tostring(record ~= nil),
    }, "|")
  ]=], name, body))
  T.eq(result, "failure=true|attempts=true|brief=true|writes=0|helper=0|typed=false|first=false")
end)

T.test("a native binding gets one helper after the journal and one Task mail", function()
  local name = "task-mail-native"
  local body = "native task marker\n" .. string.rep("n", 3000)
  local result = T.eval(string.format([=[
    local name=%q
    local body=%q
    local bus=remuda._butler_bus
    local addr=remuda._butler_identity.mail_address
    local binding={mode="native",kind="opencode",
      path=os.getenv("XDG_DATA_HOME").."/binding.json",nonce=string.rep("a",32),
      row_id="ses_native",instance="instance-native"}
    bus.agents[name]={id="native-id",kind="opencode",parent="butler",
      instance_id="instance-native",native=binding}
    remuda._task_spy.helper, remuda._task_spy.at, remuda._task_spy.task_id = 0, "", nil
    remuda.process={run=function(spec)
      remuda._task_spy.helper=remuda._task_spy.helper+1
      remuda._task_spy.at=remuda._butler_delivery_journal.state_of(
        "native-id", remuda._task_spy.task_id or "?") or "nil"
      return {code=0,stdout=remuda.json.encode({outcome="accepted_queue"}),stderr=""}
    end}
    remuda.ls=function() return {{name=name,alive=true,attached=false,
      id="ses_native",instance_id="instance-native"}} end
    local id,_,info=remuda.butler.native_task.queue({
      queue_message=remuda._butler_mail.queue, mail_address=addr,
      send=remuda._butler_send, trace=function() end,
      notify=function(message,delivered)
        remuda._task_spy.task_id=delivered.id
        local text=remuda._butler_notice.mail_notice_text(delivered,"from butler","opencode")
        remuda._butler_notify(name,text,delivered.id,true)
        return delivered
      end},name,"butler",body)
    local count=0
    for _,m in pairs(bus.messages or {}) do
      if m.subject=="Task" then
        local obj=bus.objects[(m.body or {}).object_id]
        if obj and tostring(obj.content):find("native task marker",1,true) then count=count+1 end
      end
    end
    local before=remuda._task_spy.helper
    remuda._butler_notice.native_publication(name)
    return table.concat({tostring(id~=nil),tostring(info.notice),
      tostring(remuda._task_spy.helper),tostring(remuda._task_spy.at),
      tostring(count),tostring(remuda._task_spy.helper==before),
      tostring(remuda._butler_delivery_journal.state_of("native-id",id) or "nil")},"|")
  ]=], name, body))
  T.eq(result, "true|attempted|1|dispatching|1|true|accepted_unread")
end)


-- Main launch/policy wiring with a fake native binding and a fake helper: this
-- proves one Task mail, one journal reservation before the helper act, and no
-- re-publication, not a live native process exchange.
T.test("a real main native-binding launch runs one Task pointer helper after the journal", function()
  local name = "task-mail-native-launch"
  local body = "native launch marker\n" .. string.rep("n", 3000)
  local result = T.eval(string.format([=[
    local name=%q
    local body=%q
    local bus=remuda._butler_bus
    local launcher=remuda._butler_native_launch
    launcher.plan=function(plan_name,kind)
      return { mode="native", kind=kind, name=plan_name,
        binding=os.getenv("XDG_DATA_HOME").."/manifest-"..plan_name..".json",
        binding_dir=os.getenv("XDG_DATA_HOME"), nonce=string.rep("a",32),
        created_at=os.time() }
    end
    launcher.join=function(plan,row,instance,resolve,verify)
      return {mode="native",kind="opencode",path=plan.binding,nonce=plan.nonce,
        row_id=row.id,instance=row.instance_id,session_token=row.id,
        awaiting_publication=true,awaiting_since=plan.created_at}
    end
    remuda._task_spy.helper, remuda._task_spy.calls = 0, {}
    remuda.process={run=function(spec)
      if type(spec.argv) == "table" and spec.argv[2] == "_agent_notice" then
        remuda._task_spy.helper=remuda._task_spy.helper+1
        local ok, request = pcall(remuda.json.decode, spec.stdin or "")
        local ids = ok and type(request) == "table" and request.message_ids or {}
        local hit
        for _,e in ipairs(remuda._butler_delivery_journal.entries or {}) do
          for _,id in ipairs(ids) do
            if (e.message_ids or {})[1] == id then hit=e end
          end
        end
        local pointer = ok and type(request) == "table" and tostring(request.text or "")
        remuda._task_spy.calls[#remuda._task_spy.calls+1] = { ids = ids,
          state = hit and hit.state or "", recipient = hit and hit.recipient_id or "",
          pointer_only = pointer and not pointer:find("native launch marker",1,true) or false }
      end
      return {code=0,stdout=remuda.json.encode({outcome="accepted_queue"}),stderr=""}
    end}
    remuda.ls=function() return {{name=name,alive=true,attached=false,
      id="ses_launch",instance_id="instance-launch"}} end
    remuda._butler_agent_builders.opencode=function() return {"sleep","100"} end
    remuda._butler_agent_startup.opencode={ready=function() return true end}
    remuda._butler_topic_delegate(name, body, nil, "opencode", "butler")
    return "started"
  ]=], name, body))
  T.eq(result, "started")
  T.wait_until(function()
    return T.eval(string.format("return tostring(remuda._task_spy.helper > 0 and remuda._butler_bus.agents[%q] ~= nil)", name))
      :match("^%s*true%s*$") ~= nil
  end, 25, "native helper")
  local result2 = T.eval(string.format([=[
    local name=%q
    local bus=remuda._butler_bus
    local agent=bus.agents[name]
    local count=0
    for _,m in pairs(bus.messages or {}) do
      if m.subject=="Task" then
        local obj=bus.objects[(m.body or {}).object_id]
        if obj and tostring(obj.content):find("native launch marker",1,true) then count=count+1 end
      end
    end
    local task_id
    for _,m in pairs(bus.messages or {}) do
      if m.subject=="Task" then
        local obj=bus.objects[(m.body or {}).object_id]
        if obj and tostring(obj.content):find("native launch marker",1,true) then task_id=m.id end
      end
    end
    local helpers, at_ok, pointer_ok = 0, false, false
    for _,c in ipairs(remuda._task_spy.calls or {}) do
      for _,id in ipairs(c.ids or {}) do
        if id == task_id then
          helpers = helpers + 1
          if c.state == "dispatching" and c.recipient == agent.id then at_ok = true end
          if c.pointer_only then pointer_ok = true end
        end
      end
    end
    local accepted=0
    for _,e in ipairs(remuda._butler_delivery_journal.entries or {}) do
      if e.state=="accepted_unread" and e.recipient_id == agent.id
          and (e.message_ids or {})[1] == task_id then accepted=accepted+1 end
    end
    local before=remuda._task_spy.helper
    remuda._butler_notice.native_publication(name)
    return table.concat({tostring(helpers),tostring(at_ok),tostring(pointer_ok),
      tostring(count),tostring(remuda._task_spy.helper==before),tostring(accepted),
      tostring(remuda._t.typed[name] ~= nil)},"|")
  ]=], name))
  T.eq(result2, "1|true|true|1|true|1|false")
end)
