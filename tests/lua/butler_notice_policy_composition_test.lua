-- Real-main notice policy composition (increment 1: boot + durable producer).
-- Run via tests/lua_tests.sh; the T harness boots the actual Butler image in a
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

T.test("real main consumes the native factory and keeps the live notice binding", function()
  local out = T.eval([==[
    local policy = remuda.butler and remuda.butler.send_policy
    local dispatch = remuda.butler and remuda.butler.native_dispatch
    local notice = remuda._butler_notice
    local digits = {}
    digits[#digits + 1] = "install_closed=" .. tostring(dispatch ~= nil and dispatch.install == nil)
    digits[#digits + 1] = "policy_bound=" .. tostring(notice ~= nil and notice._policy_bound == true)
    digits[#digits + 1] = "policy_private=" .. tostring(policy ~= nil
      and policy.construct == nil and policy.observe == nil)
    return table.concat(digits, ",")
  ]==])
  T.eq(out, "install_closed=true,policy_bound=true,policy_private=true",
    "actual main load order: " .. tostring(out))
end)

T.test("actual _butler_send stores durable mail and one legacy raw send uses the real dialogs", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local spies = remuda._t_spies
    bus.agents.m2 = { id = "m2-id", kind = "claude", instance_id = "inst-2",
      parent = "butler", alias = "m2" }
    remuda.ls = function()
      return { { name = "m2", id = "row-2", instance_id = "inst-2",
        alive = true, attached = false } }
    end
    local ok, result = pcall(remuda._butler_send, "butler", "m2", "probe one")
    assert(ok, "send failed: " .. tostring(result))
    assert(tostring(result):find("^queued ") ~= nil, "the producer queued durable mail: "
      .. tostring(result))
    local pending = bus.notices.m2
    assert(pending and pending.message_order and #pending.message_order == 1,
      "one queued notice for the recipient")
    local id = pending.message_order[1]
    assert(type(id) == "string" and id:match("^[0-9A-HJKMNP-TV-Z]+$") and #id == 26,
      "a durable ULID was assigned, got " .. tostring(id))
    local inbox = bus.inboxes and bus.inboxes["m2-id"] or {}
    local listed = false
    for _, delivered in ipairs(inbox) do if delivered == id then listed = true end end
    assert(listed, "the recipient inbox records the durable message")
    local saved = remuda._butler_mail.find_message(id)
    assert(saved and saved.id == id, "the real mail store has the message")
    local object = saved.body and bus.objects[saved.body.object_id]
    assert(object and object.content == "probe one", "the stored body is the original string")
    assert(remuda._butler_notice.deliver_notice("m2") == true, "notice delivery")
    assert(#spies.sends == 1, "exactly one raw legacy send, got " .. #spies.sends)
    assert(spies.sends[1].name == "m2", "the sink names the recipient")
    assert(spies.sends[1].text:find(id, 1, true) ~= nil, "the notice text carries the ULID")
    return "ok:" .. id
  ]==])
  T.expect(out:match("^ok:") ~= nil, "producer proof: " .. tostring(out))
end)

T.test("native Codex: real preflight reserves the journal before the process sink", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local spies = remuda._t_spies
    spies.events = {}
    bus.agents.m1 = { id = "m1-id", kind = "codex", instance_id = "inst-1",
      parent = "butler", alias = "m1",
      native = { mode = "native", kind = "codex",
        path = "/private/tmp/t/manifest.json", nonce = string.rep("ab", 16),
        session_token = "row-1", row_id = "row-1", instance = "inst-1" } }
    remuda.ls = function()
      return { { name = "m1", id = "row-1", instance_id = "inst-1",
        alive = true, attached = false } }
    end
    local before = #spies.runs
    local ok, result = pcall(remuda._butler_send, "butler", "m1", "native probe")
    assert(ok, tostring(result))
    assert(tostring(result):find("notified m1", 1, true) ~= nil,
      "the native producer delivered immediately: " .. tostring(result))
    local inbox = bus.inboxes and bus.inboxes["m1-id"] or {}
    local id = inbox[#inbox]
    assert(type(id) == "string" and #id == 26, "the durable native ULID")
    assert(#spies.runs == before + 1, "one helper invocation from the producer")
    local call = spies.runs[#spies.runs]
    assert(call.argv[2] == "_codex_notice", "the Codex helper verb, got " .. tostring(call.argv[2]))
    local request = remuda.json.decode(call.stdin)
    assert(request.text == "Butler message " .. id .. " arrived. Read it: MCP butler_inbox (or remuda butler inbox)",
      "canonical native text: " .. tostring(request.text))
    assert(request.message_ids[1] == id, "the original ULID is carried")
    assert(type(request.request_id) == "string" and #request.request_id > 0,
      "one frozen request id")
    assert(request.session == "row-1" and request.instance == "inst-1",
      "the frozen row identity is carried")
    local run_at
    for index, event in ipairs(spies.events) do
      if event == "run" then run_at = index end
    end
    assert(run_at and run_at > 1 and spies.events[run_at - 1] == "journal",
      "the real journal reservation writes before the process sink")
    local journal = remuda._butler_delivery_journal
    assert(journal.state_of("m1-id", id) == "accepted_unread",
      "the journal records the accepted native delivery")
    assert(spies.keys == 0 and spies.types == 0, "no key/type on the native path")
    return "ok"
  ]==])
  T.eq(out, "ok", "native composition")
end)

T.test("journal write failure: zero native process sink", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local spies = remuda._t_spies
    spies.journal_fail = true
    spies.events = {}
    local before = #spies.runs
    local ok, result = pcall(remuda._butler_send, "butler", "m1", "failing journal")
    assert(ok, tostring(result))
    local id = bus.notices.m1.message_order[1]
    remuda._butler_notice.deliver_notice("m1")
    assert(#spies.runs == before, "no helper without a journal reservation")
    assert(remuda._butler_delivery_journal.state_of("m1-id", id) == nil,
      "no journal entry was written")
    spies.journal_fail = false
    return "ok"
  ]==])
  T.eq(out, "ok", "journal failure is pre-write")
end)

T.test("timeout is uncertain, persisted, and a second delivery is suppressed", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local spies = remuda._t_spies
    spies.outcome = "uncertain"
    spies.events = {}
    local before = #spies.runs
    local ok, result = pcall(remuda._butler_send, "butler", "m1", "timeout probe")
    assert(ok, tostring(result))
    local inbox = bus.inboxes and bus.inboxes["m1-id"] or {}
    local id = inbox[#inbox]
    assert(type(id) == "string" and #id == 26, "the durable ULID for the uncertain attempt")
    assert(#spies.runs == before + 1, "the uncertain attempt ran once")
    local journal = remuda._butler_delivery_journal
    assert(journal.state_of("m1-id", id) == "uncertain",
      "the journal persists uncertain, got " .. tostring(journal.state_of("m1-id", id)))
    -- Re-queue the same ID as a re-show; the persisted uncertain record must
    -- suppress it so the helper is never run twice for one attempt.
    assert(journal.suppresses("m1-id", id) == true,
      "the persisted uncertain record suppresses the same id")
    pcall(remuda._butler_notify, "m1", "Butler message " .. id
      .. " arrived. Read it: MCP butler_inbox (or remuda butler inbox)", id, true)
    local after = #spies.runs
    remuda._butler_notice.deliver_notice("m1")
    assert(#spies.runs == after, "an uncertain attempt is never retried automatically")
    assert(journal.state_of("m1-id", id) == "uncertain", "the uncertain record survives re-entry")
    spies.outcome = "accepted"
    return "ok"
  ]==])
  T.eq(out, "ok", "uncertain persistence and suppression")
end)

T.test("_butler_report keeps the original string and returns the durable ULID", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local before = {}
    for id in pairs(bus.notices.butler and bus.notices.butler.message_ids or {}) do before[id] = true end
    local ok, result = pcall(remuda._butler_report, "m2", "report body", false)
    assert(ok, tostring(result))
    assert(tostring(result):find("^queued ") ~= nil, "report queued durable mail: " .. tostring(result))
    local pending = bus.notices.butler
    assert(pending and pending.message_order, "the report notice is queued for the parent")
    local id
    for _, candidate in ipairs(pending.message_order) do
      if not before[candidate] then id = candidate end
    end
    assert(id and #id == 26, "a new ULID was queued")
    local message = remuda._butler_mail.find_message(id)
    local object = message and message.body and bus.objects[message.body.object_id]
    assert(object and object.content == "report body", "the report body is the original string")
    return "ok"
  ]==])
  T.eq(out, "ok", "report producer")
end)

T.test("schedule facade: the real tick sends the original string and one durable ULID", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local schedule = remuda.butler.schedule
    local env = remuda._butler_schedule_env
    assert(schedule and env and env.path, "the real schedule facade is wired")
    local now = os.time()
    local clock = os.date("*t", now)
    local list = {}
    assert(schedule.add(list, {
      name = "probe-once", spec = string.format("%d %d * * *", clock.min, clock.hour),
      target = "m2", text = "schedule probe", enabled = true,
      last_fired = math.floor(now / 60) - 1, created_by = "butler",
      created_at = "test" }))
    assert(schedule.save(env.path, list), "the schedule store is written")
    local before = {}
    for id in pairs(bus.notices.m2 and bus.notices.m2.message_ids or {}) do before[id] = true end
    local trace = {}
    env.trace = function(event, detail) trace[#trace + 1] = event .. " " .. tostring(detail) end
    remuda._butler_schedule_tick()
    local pending = bus.notices.m2
    assert(pending and pending.message_order, "the tick queued a notice: "
      .. table.concat(trace, ";"))
    local id
    for _, candidate in ipairs(pending.message_order) do
      if not before[candidate] then id = candidate end
    end
    assert(id and #id == 26, "one new durable ULID from the schedule send")
    local message = remuda._butler_mail.find_message(id)
    local object = message and message.body and bus.objects[message.body.object_id]
    assert(object and object.content:find("schedule probe", 1, true) ~= nil,
      "the original schedule text survives into the durable message")
    return "ok"
  ]==])
  T.eq(out, "ok", "schedule producer")
end)
