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

T.test("an active startup control defers only the legacy notice path", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local spies = remuda._t_spies
    local controls = remuda.butler.startup_controls
    local real_schedule, real_cancel = remuda.schedule, remuda.cancel
    local real_capture_styled = remuda.capture_styled
    local real_capture, real_ls = remuda.capture, remuda.ls
    remuda.schedule = function(spec) return { spec = spec } end
    remuda.cancel = function() end
    remuda.capture_styled = nil
    local update_screen = "  Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip\n  3. Skip until next version\n› Ask Codex to do anything"
    local composer_screen = "› Ask Codex to do anything"
    local screen = update_screen
    local m3 = { id = "m3-id", kind = "codex", instance_id = "inst-3",
      parent = "butler", alias = "m3", last_screen = update_screen }
    bus.agents.m3 = m3
    remuda.ls = function()
      return { { name = "m3", id = "row-3", instance_id = "inst-3", alive = true, attached = false } }
    end
    remuda.capture = function() return screen end
    local owned = controls.start({ name = "m3", kind = "codex", parent = "butler",
      agent = m3, model = "gpt", cwd = "/tmp", saved_id = nil, task_supplied = false })
    assert(owned and controls.active("m3", m3) == owned, "control ownership was not registered")
    -- The legacy notice policy must refuse while the update frame is live.
    local sends = #spies.sends
    local captures, checks = 0, 0
    local capture_before = remuda.capture
    remuda.capture = function(...)
      captures = captures + 1
      return capture_before(...)
    end
    local check_before = remuda.butler.dialogs.check
    remuda.butler.dialogs.check = function(...)
      checks = checks + 1
      return check_before(...)
    end
    local allowed = remuda._butler_notify_policy("m3")
    remuda.capture = capture_before
    remuda.butler.dialogs.check = check_before
    assert(allowed == false, "legacy notice policy admitted a live update modal")
    assert(captures == 0 and checks == 0,
      "the legacy policy consumed a controlled frame before refusing it")
    remuda._butler_send("butler", "m3", "legacy while controlled")
    remuda._butler_notice.deliver_notice("m3")
    assert(#spies.sends == sends, "a legacy notice was typed into the unresolved update frame")
    -- The active control owns the pane until it releases it, even after the
    -- dialog cleared: the pointer must not replace the composer first.
    screen = composer_screen
    assert(remuda._butler_notify_policy("m3") == false,
      "the legacy notice policy typed into a controlled startup pane")
    local startup = remuda._butler_agent_startup.codex
    assert(remuda._butler_chooser.known_startup_modal(startup, update_screen) == true,
      "the update frame was not recognised as a live startup modal")
    assert(remuda._butler_chooser.known_startup_modal(startup, composer_screen) == false,
      "an empty composer was misread as a startup modal")
    -- Native bound delivery is not this gate's to defer: the helper runs now.
    local m4 = { id = "m4-id", kind = "codex", instance_id = "inst-4",
      parent = "butler", alias = "m4",
      native = { mode = "native", kind = "codex",
        path = "/private/tmp/t/manifest.json", nonce = string.rep("cd", 16),
        session_token = "row-4", row_id = "row-4", instance = "inst-4" } }
    bus.agents.m4 = m4
    remuda.ls = function()
      return { { name = "m3", id = "row-3", instance_id = "inst-3", alive = true, attached = false },
        { name = "m4", id = "row-4", instance_id = "inst-4", alive = true, attached = false } }
    end
    local owned4 = controls.start({ name = "m4", kind = "codex", parent = "butler",
      agent = m4, model = "gpt", cwd = "/tmp", saved_id = nil, task_supplied = false })
    assert(owned4, "native control ownership was not registered")
    local runs = #spies.runs
    local ok4, result4 = pcall(remuda._butler_send, "butler", "m4", "native while control")
    assert(ok4 and tostring(result4):find("notified m4", 1, true) ~= nil,
      "native delivery was deferred by the legacy gate: " .. tostring(result4))
    assert(#spies.runs == runs + 1, "the native helper did not run under an active control")
    assert(#spies.sends == sends, "the native bypass typed a legacy notice")
    assert(spies.keys == 0 and spies.types == 0, "the native bypass pressed keys or typed")
    local task_id = bus.inboxes["m4-id"][#bus.inboxes["m4-id"]]
    -- The realistic busy case: the native Task was accepted, and the pane is
    -- already working before the controller's first tick. It must release the
    -- timer quietly without replaying the Task or typing anything.
    screen = "esc to interrupt"
    owned4.handle.spec.run()
    assert(controls.active("m4", m4) == nil, "a busy native pane kept startup ownership")
    assert(#spies.runs == runs + 1, "the busy release replayed the native helper")
    assert(#spies.sends == sends, "the busy release typed a legacy notice")
    assert(spies.keys == 0 and spies.types == 0, "the busy release pressed keys or typed")
    assert(bus.inboxes["m4-id"][#bus.inboxes["m4-id"]] == task_id,
      "the busy release queued a new Task")
    assert(controls.take_evidence("m4", m4) == "esc to interrupt",
      "the quiet stop did not preserve its last observed frame")
    assert(controls.take_evidence("m4", m4) == nil,
      "the quiet-stop frame was handed out twice")
    controls.stop("m3", owned)
    controls.stop("m4", owned4)
    -- After ownership is gone the unresolved menu must still refuse the
    -- legacy pointer; only the empty composer admits it.
    bus.notices.m3 = nil
    screen = update_screen
    local after_failure = #spies.sends
    remuda._butler_send("butler", "m3", "after give-up")
    remuda._butler_notice.deliver_notice("m3")
    assert(#spies.sends == after_failure,
      "a released but unresolved update menu received a pointer")
    -- Historical update text above a clear composer is transcript, not a live
    -- choice, and stays admitted.
    screen = "Update available · 0.156.0 → 0.157.1\n› 1. Update now\n  2. Skip\n\n● task finished\n\n● tests passed\n\n╭──────────────╮\n│ ›            │\n╰──────────────╯"
    local sent_auto, auto_why = remuda.butler.dialogs.automatic_notice_send("m3",
      "Butler message 01ARZ3NDEKTSV4RRFFQ69G5FAV arrived. Read it: remuda butler inbox",
      { "01ARZ3NDEKTSV4RRFFQ69G5FAV" })
    assert(sent_auto == true,
      "historical update text blocked a clear composer: " .. tostring(auto_why))
    assert(#spies.sends == after_failure + 1, "the admitted notice did not send")
    screen = composer_screen
    assert(remuda._butler_notify_policy("m3") == true,
      "the legacy notice policy stayed closed after the control stopped")
    bus.notices.m3, bus.agents.m3, bus.agents.m4 = nil, nil, nil
    remuda.schedule, remuda.cancel = real_schedule, real_cancel
    remuda.capture_styled = real_capture_styled
    remuda.capture, remuda.ls = real_capture, real_ls
    return "ok"
  ]==])
  T.eq(out, "ok", "startup control notice composition")
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

T.test("manual changed-instance relaunch still suppresses accepted or uncertain Tasks", function()
  local out = T.eval([==[
    local bus = remuda._butler_bus
    local spies = remuda._t_spies
    local journal = remuda._butler_delivery_journal
    local agent = bus.agents.m1
    local real_ls = remuda.ls
    local inbox = bus.inboxes["m1-id"] or {}
    local accepted, uncertain
    for _, id in ipairs(inbox) do
      local state = journal.state_of("m1-id", id)
      if state == "accepted_unread" then accepted = accepted or id end
      if state == "uncertain" then uncertain = id end
    end
    assert(accepted and uncertain, "the accepted and uncertain journal ids are present")
    local count = #inbox
    local function relaunch_as(instance)
      bus.agents.m1 = { id = "m1-id", kind = "codex", instance_id = instance,
        parent = "butler", alias = "m1",
        native = { mode = "native", kind = "codex",
          path = "/private/tmp/t/manifest.json", nonce = string.rep("ef", 16),
          session_token = "row-1", row_id = "row-1", instance = instance } }
      remuda.ls = function()
        return { { name = "m1", id = "row-1", instance_id = instance,
          alive = true, attached = false } }
      end
    end
    local cases = { { id = accepted, state = "accepted_unread", instance = "inst-a2" },
      { id = uncertain, state = "uncertain", instance = "inst-u2" } }
    for _, case in ipairs(cases) do
      relaunch_as(case.instance)
      assert(bus.agents.m1.id == "m1-id", "the logical recipient id changed")
      local before = #spies.runs
      remuda._butler_notify("m1", "Butler message " .. case.id
        .. " arrived. Read it: MCP butler_inbox (or remuda butler inbox)", case.id, true)
      remuda._butler_notice.deliver_notice("m1")
      assert(#spies.runs == before, "a journaled Task replayed the helper after relaunch")
      assert(journal.state_of("m1-id", case.id) == case.state,
        "the journal state changed across the relaunch")
      assert(journal.suppresses("m1-id", case.id) == true,
        "the same ULID is not suppressed after the relaunch")
      assert(#inbox == count, "a new Task was appended for the same ULID")
    end
    bus.agents.m1 = agent
    remuda.ls = real_ls
    return "ok"
  ]==])
  T.eq(out, "ok", "accepted/uncertain suppression across relaunch")
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
