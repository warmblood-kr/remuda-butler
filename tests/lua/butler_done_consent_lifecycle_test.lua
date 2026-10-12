-- #478: real in-image reload, every stale-mark deletion, and zero close effects.
T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true')
T.eval('return remuda.exec("butler")')
T.wait_until(function()
  return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil') == "true"
end, 5, "Butler root ready")

T.test("real reload retains matching consent and deletes stale and legacy marks", function()
  T.eq(T.eval([=[
    local bus = remuda._butler_bus
    local saved = { agents = bus.agents, done = remuda._butler_done }
    local function agent(name)
      return { id = "fixture-" .. name, alias = name, session_name = name, kind = "codex",
        parent = "butler", session_start_marker = "generation", instance_id = "BOUND",
        instance_binding = 1, token = "fixture-consent-" .. name, children = {} }
    end
    local function mark(a) return { id = a.id, generation = a.session_start_marker, instance_id = a.instance_id } end
    local function normalized(value)
      if type(value) ~= "table" then return value end
      local object = remuda.json.object({})
      for key, item in pairs(value) do object[tostring(key)] = normalized(item) end
      return object
    end
    local function snapshot()
      return remuda.json.encode(normalized { agents = bus.agents, messages = bus.messages,
        objects = bus.objects, inboxes = bus.inboxes, delivered = bus.mail_delivered,
        read = bus.mail_read, next = bus.next })
    end
    bus.agents = { butler = saved.agents.butler, matching = agent("matching"),
      stale = agent("stale"), legacy = agent("legacy") }
    for _, name in ipairs({ "matching", "stale", "legacy" }) do
      local a = bus.agents[name]
      bus.tokens[a.token] = { id = a.id, generation = a.session_start_marker,
        instance_id = a.instance_id, instance_binding = 1 }
    end
    remuda._butler_done = { matching = mark(bus.agents.matching), stale = mark(bus.agents.stale), legacy = true }
    remuda._butler_done.stale.generation = "old"
    local retained = remuda._butler_done
    local previous_tick = remuda._butler_done_tick
    remuda.reload("butler") -- actually reload the installed mod, retaining its bus
    assert(remuda._butler_done == retained, "reload discarded the consent table")
    assert(remuda._butler_done_tick ~= previous_tick, "mod code was not reloaded")
    local close = remuda._butler_close_member
    local closed = {}
    remuda._butler_close_member = function(name, parent, force, internal)
      assert(parent == "butler" and force == false and internal == false)
      closed[#closed + 1] = name
    end
    local ok, err = pcall(function()
      local before = snapshot()
      remuda._butler_done_tick()
      assert(#closed == 1 and closed[1] == "matching", "reload consent closed the wrong member: "
        .. table.concat(closed, ",") .. " matching=" .. tostring(retained.matching ~= nil)
        .. " registered=" .. tostring(bus.agents.matching ~= nil))
      assert(next(retained) == nil, "reload retained a consumed, stale or legacy mark")
      assert(snapshot() == before, "reload tick changed mail or roster outside the close helper")
      closed = {}
      remuda._butler_done_tick()
      assert(#closed == 0, "consent closed twice")
      for _, mismatch in ipairs({ "id", "generation", "instance", "missing", "parentless", "root", "legacy" }) do
        local a, alias = agent("mismatch"), "mismatch"
        bus.agents.mismatch = a
        local consent = mark(a)
        if mismatch == "id" then consent.id = "previous"
        elseif mismatch == "generation" then consent.generation = "previous"
        elseif mismatch == "instance" then consent.instance_id = "previous"
        elseif mismatch == "missing" then bus.agents.mismatch = nil
        elseif mismatch == "parentless" then a.parent = nil
        elseif mismatch == "root" then alias = "butler"; consent = mark(bus.agents.butler)
        elseif mismatch == "legacy" then consent = true end
        retained[alias] = consent
        local unchanged = snapshot()
        remuda._butler_done_tick()
        assert(retained[alias] == nil, mismatch .. " mark not deleted")
        assert(#closed == 0, mismatch .. " reached close helper")
        assert(snapshot() == unchanged, mismatch .. " changed mail or roster")
      end
      -- A valid mark refused by ownership is also dropped with no native close effects.
      bus.agents.refused = agent("refused")
      retained.refused = mark(bus.agents.refused)
      local native_close, effects, attempts = remuda.close, 0, 0
      remuda.close = function() effects = effects + 1 end
      remuda._butler_close_member = function()
        attempts = attempts + 1; error("cannot close fixture: not owned", 0)
      end
      local unchanged = snapshot()
      remuda._butler_done_tick()
      remuda.close = native_close
      assert(attempts == 1 and effects == 0 and retained.refused == nil, "refused close kept consent or closed")
      assert(snapshot() == unchanged, "refused consent changed mail or roster")
    end)
    remuda._butler_close_member = close
    for _, name in ipairs({ "matching", "stale", "legacy" }) do bus.tokens["fixture-consent-" .. name] = nil end
    bus.agents, remuda._butler_done = saved.agents, saved.done
    if not ok then error(err, 0) end
    return "ok"
  ]=]), "ok")
end)

T.test("stale exit preserves current consent and matching exit deletes it", function()
  T.eq(T.eval([=[
    local bus = remuda._butler_bus
    local name = "consent-exit"
    local a = { id = "01M47800000000000000000001", alias = name, session_name = name, kind = "codex",
      parent = "butler", session_start_marker = "generation", instance_id = "CURRENT", instance_binding = 1, children = {} }
    bus.agents[name] = a
    local consent = { id = a.id, generation = a.session_start_marker, instance_id = a.instance_id }
    remuda._butler_done[name] = consent
    local native_close, closes, before_next = remuda.close, 0, bus.next
    local function normalized(value)
      if type(value) ~= "table" then return value end
      local object = remuda.json.object({})
      for key, item in pairs(value) do object[tostring(key)] = normalized(item) end
      return object
    end
    local function snapshot()
      return remuda.json.encode(normalized { agents = bus.agents, messages = bus.messages,
        objects = bus.objects, inboxes = bus.inboxes, read = bus.mail_read,
        delivered = bus.mail_delivered, done = remuda._butler_done })
    end
    remuda.close = function() closes = closes + 1 end
    local ok, err = pcall(function()
      local before = snapshot()
      remuda._butler_session_exited(name, { instance_id = "OLD", reason = "exited" })
      assert(bus.agents[name] == a and remuda._butler_done[name] == consent, "stale exit changed current consent or roster")
      assert(snapshot() == before, "stale exit changed mail, roster or consent")
      assert(closes == 0 and bus.next == before_next, "stale exit closed or sent mail")
      remuda._butler_session_exited(name, { instance_id = "CURRENT", reason = "exited" })
      assert(bus.agents[name] == nil and remuda._butler_done[name] == nil, "matching exit kept roster or consent")
      assert(closes == 0 and bus.next == before_next, "exit handling closed or sent mail")
    end)
    remuda.close = native_close
    bus.agents[name], remuda._butler_done[name] = nil, nil
    if not ok then error(err, 0) end
    return "ok"
  ]=]), "ok")
end)
