-- Faithful failed-reload B gate: a real compiled notice generation left from a
-- failed candidate load must be inert, while the restored generation still
-- delivers. Run via tests/lua_tests.sh against a disposable private daemon.
-- Raw core transport and journal/save sinks are spied BEFORE main loads, so the
-- real dialogs/notice/policy/journal code paths run unmodified.
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

T.test("a stale compiled candidate is inert and the restored current delivers", function()
  local result = T.eval([==[
    local path = os.getenv("XDG_DATA_HOME") .. "/remuda/mods/butler/packages/butler/notice.lua"
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    -- Fail a real load AFTER its notice binding published a full candidate
    -- module. Capture that generation's compiled entries directly.
    local modified, injected = source:gsub("\nbind_send_policy%s*%(%s*%)%s*$",
      "\nbind_send_policy()\n"
      .. "remuda._qa_stale_deliver=NOTICE_MODULE.deliver_notice\n"
      .. "remuda._qa_stale_module=NOTICE_MODULE\n"
      .. "remuda._qa_stale_deliver_notices=remuda._butler_deliver_notices\n"
      .. "error('stale-deliver-barrier')")
    assert(injected == 1, "bind barrier not injected")
    file = assert(io.open(path, "w"))
    file:write(modified)
    file:close()
    local ok, why = pcall(remuda._load_extension_command, "butler", "butler", true)
    file = assert(io.open(path, "w"))
    file:write(source)
    file:close()
    assert(not ok and tostring(why):find("stale%-deliver%-barrier", 1),
      "candidate must fail after publishing its notice module")

    local stale = assert(remuda._qa_stale_deliver, "actual compiled candidate fn")
    local stale_module = assert(remuda._qa_stale_module, "actual candidate claim")
    local stale_poll = assert(remuda._qa_stale_deliver_notices, "compiled candidate poll")
    local live_marker = assert(remuda._butler_notice, "restored current module")
    local current = live_marker.deliver_notice
    assert(stale ~= current, "actual stale/current functions must differ")

    local bus = remuda._butler_bus
    local spies = remuda._t_spies
    local function bytes(target)
      local opened = io.open(target, "rb")
      if not opened then return "<absent>" end
      local text = opened:read("*a")
      opened:close()
      return text
    end
    local function hex(value)
      return (value:gsub(".", function(byte)
        return string.format("%02x", string.byte(byte))
      end))
    end
    -- Root instance must be snapshotted before remuda.ls is narrowed below.
    local root_instance
    for _, row in ipairs(remuda.ls()) do
      if row.name == "butler" and row.alive then root_instance = row.instance_id end
    end
    assert(root_instance, "root instance missing")

    -- Seed an unrelated, valid uncertain delivery intent and a nonempty pending
    -- VALUE so the protected parity compares real content, not only keys.
    local journal = assert(remuda._butler_delivery_journal, "delivery journal missing")
    local uncertain = assert(journal.begin({
      protocol = "pty", recipient_id = "fixture_recipient",
      message_ids = { "fixture_message" }, instance = "fixture_instance",
      row_id = "fixture_row", nonce = "fixture_nonce",
      generation = "fixture_generation", body = "fixture body",
    }))
    assert(journal.mark(uncertain, "uncertain", "fixture_uncertain"),
      "journal uncertain seed failed")
    assert(journal.status().uncertain >= 1, "uncertain seed missing")
    bus.pending_tasks = bus.pending_tasks or {}
    bus.pending_tasks["other_member"] = { text = "pending-value", at = 12345 }

    bus.agents.m1 = { id = "m1-id", kind = "codex", instance_id = "inst-1",
      parent = "butler", alias = "m1",
      native = { mode = "native", kind = "codex",
        path = "/private/tmp/t/manifest.json", nonce = string.rep("ab", 16),
        session_token = "row-1", row_id = "row-1", instance = "inst-1" } }
    remuda.ls = function()
      return { { name = "m1", id = "row-1", instance_id = "inst-1",
        alive = true, attached = false } }
    end
    local mail = assert(remuda._butler_mail.queue("butler", "m1",
      "durable stale-first task", "Task"))
    local text = live_marker.mail_notice_text(mail, "from butler", "codex")
    bus.notices.m1 = { count = 1, text = text, kind = "codex",
      message_ids = { [mail.id] = text }, message_order = { mail.id },
      message_times = { [mail.id] = os.time() },
      first_at = os.time(), last_at = os.time() }
    local pending = bus.notices.m1
    assert(pending, "pending seed missing")

    local mail_root = remuda._butler_paths.mail_root
    local recipient_id = assert(mail.to and mail.to[1] and mail.to[1].id,
      "seed recipient id")
    local data = remuda._butler_paths.data_home .. "/remuda/butler"
    local protected_paths = {
      mail_root .. "/inboxes/" .. hex(recipient_id) .. ".jsonl",
      mail_root .. "/messages/" .. mail.id .. ".json",
      mail_root .. "/objects/" .. mail.body.object_id,
      data .. "/agents.jsonl", data .. "/roster.json",
    }
    for _, target in ipairs(protected_paths) do
      assert(bytes(target) ~= "<absent>", "protected fact missing: " .. target)
    end
    local function others()
      local copy = {}
      for name, value in pairs(bus.notices) do
        if name ~= "m1" then copy[name] = value end
      end
      return copy
    end
    local function stable(value)
      if type(value) ~= "table" then return tostring(value) end
      local rows = {}
      for key, item in pairs(value) do
        rows[#rows + 1] = { key = tostring(key), value = stable(item) }
      end
      table.sort(rows, function(a, b) return a.key < b.key end)
      local parts = {}
      for _, row in ipairs(rows) do
        parts[#parts + 1] = row.key .. "=" .. row.value
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    local function protected_parts()
      local parts = { others = stable(others()),
        uncertain = stable(bus.notice_uncertain or {}),
        pending = stable(bus.pending_tasks or {}),
        instance = tostring(root_instance) }
      for index, target in ipairs(protected_paths) do
        parts["file" .. index] = bytes(target)
      end
      return parts
    end
    local function protected()
      local parts, ordered = protected_parts(), {}
      for _, key in ipairs({ "others", "uncertain", "pending", "instance" }) do
        ordered[#ordered + 1] = key .. "=" .. parts[key]
      end
      for index = 1, #protected_paths do
        ordered[#ordered + 1] = "file" .. index .. "=" .. parts["file" .. index]
      end
      return table.concat(ordered, "\n")
    end
    local function throughout()
      return table.concat({ stable(others()),
        stable(bus.notice_uncertain or {}),
        stable(bus.pending_tasks or {}), tostring(root_instance) }, "\n")
    end
    local function changed_parts(before)
      local after, changed = protected_parts(), {}
      for key, value in pairs(before) do
        if after[key] ~= value then changed[#changed + 1] = key end
      end
      table.sort(changed)
      return table.concat(changed, ",")
    end
    local function journal_image()
      local state = journal.status()
      return table.concat({ bytes(journal.path), tostring(state.entries),
        tostring(state.dispatching), tostring(state.uncertain),
        tostring(state.accepted_unread), tostring(state.usable) }, "\n")
    end
    local guarded, guarded_parts, journal_before =
      protected(), protected_parts(), journal_image()
    local throughout_before = throughout()

    local begin = journal.begin
    local begins = 0
    journal.begin = function(...)
      begins = begins + 1
      return begin(...)
    end
    local runs = #spies.runs
    local function inert(label, action)
      local before_runs, before_begins = #spies.runs, begins
      local before_pending = bus.notices.m1
      action()
      assert(#spies.runs == before_runs, label .. ": stale transport")
      assert(begins == before_begins, label .. ": stale journal begin")
      assert(bus.notices.m1 == before_pending, label .. ": stale dequeue")
    end
    local agent = bus.agents.m1
    local now = os.time()

    -- STALE FIRST: the same real pending stays populated.
    inert("stale-deliver", function() stale("m1") end)
    assert(protected() == guarded,
      "stale deliver changed durable facts: " .. changed_parts(guarded_parts))
    assert(journal_image() == journal_before, "stale deliver changed the journal")
    inert("stale-poll", function() stale_poll() end)
    inert("stale-remind", function() stale_module.remind_unread_notices("m1", agent, now) end)
    inert("stale-recovery", function()
      stale_module.complete_notice_recovery("m1", { message_ids = { mail.id } })
    end)
    inert("stale-native", function() stale_module.native_publication("m1") end)
    assert(protected() == guarded,
      "stale entries changed durable facts: " .. changed_parts(guarded_parts))
    assert(journal_image() == journal_before, "stale entries changed the journal")
    assert(#spies.runs == runs, "stale entries dispatched")
    assert(spies.keys == 0 and spies.types == 0, "stale entries typed")

    -- Strict identity: a missing or foreign marker is inert too.
    remuda._butler_notice = nil
    inert("nil-marker", function() stale("m1") end)
    remuda._butler_notice = {}
    inert("foreign-marker", function() stale("m1") end)
    remuda._butler_notice = live_marker
    assert(throughout() == throughout_before,
      "marker probes changed protected facts")
    assert(journal_image() == journal_before, "marker probes changed the journal")

    -- The one chosen route: the restored current generation delivers the same
    -- real pending once (one transport dispatch, one journal attempt-begin).
    local r0, b0 = #spies.runs, begins
    current("m1")
    local current_runs, current_begins = #spies.runs - r0, begins - b0
    assert(current_runs == 1 and current_begins == 1,
      "current same-pending route: " .. current_runs .. "/" .. current_begins)
    assert(bus.notices.m1 == nil, "current same-pending did not settle")

    -- A separate positive proves the restored path is not a global no-op.
    local positive = assert(remuda._butler_mail.queue("butler", "m1",
      "current positive task", "Task"))
    local ptext = live_marker.mail_notice_text(positive, "from butler", "codex")
    bus.notices.m1 = { count = 1, text = ptext, kind = "codex",
      message_ids = { [positive.id] = ptext }, message_order = { positive.id },
      message_times = { [positive.id] = os.time() },
      first_at = os.time(), last_at = os.time() }
    local r1, b1 = #spies.runs, begins
    current("m1")
    assert(#spies.runs - r1 == 1 and begins - b1 == 1 and bus.notices.m1 == nil,
      "restored current new-task positive failed")
    -- The unrelated uncertain intent, pending value and durable mail bytes
    -- survive the whole sequence.
    assert(throughout() == throughout_before,
      "current delivery changed protected facts")
    assert(journal.status().uncertain >= 1, "uncertain intent lost")
    assert(bus.pending_tasks["other_member"].text == "pending-value",
      "pending value lost")

    journal.begin = begin
    return table.concat({ "0", "0", "false", tostring(current_runs),
      tostring(current_begins), "true" }, "|")
  ]==])
  T.eq(result, "0|0|false|1|1|true",
    "stale generation inert, restored current delivers once")
end)
