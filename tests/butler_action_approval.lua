-- Focused action_grant reducer tests (#475 slice 0). Run from the repository root:
--   luajit tests/butler_action_approval.lua
-- Pure: fake remuda, injected elapsed clock / generation / UTC / evidence; no filesystem, network, Matrix or daemon.
local random_call = 0
remuda = { json = { null = {}, object = function(value) return value end },
  butler = { matrix = { sanitize_directory_text = function(value) return value end } },
  random_bytes = function(n) random_call = random_call + 1; return string.rep(string.char(96 + random_call % 26), n) end }
local effects = { post = 0, send = 0, typed = 0, handler = 0 }
remuda._butler_send = function() effects.send = effects.send + 1; return true end
remuda.send = function() effects.typed = effects.typed + 1; return true end
local approval = dofile("packages/butler/approval.lua")
local state = { approvals = {} }
local function attach()
  approval.attach(state, function() return true end,
    function(_, _, callback) effects.post = effects.post + 1; callback({ event_id = "$posted" }); return true end)
end
attach()
approval.handler("action_grant", { approve = function() effects.handler = effects.handler + 1; error("must not be called") end,
  deny = function() effects.handler = effects.handler + 1 end, expire = function() effects.handler = effects.handler + 1 end })

local function deep(v) if type(v) ~= "table" then return v end local o = {} for k, x in pairs(v) do o[k] = deep(x) end return o end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function raw(id) return deep(state.approvals[id]) end

-- Injected clock: elapsed ms, daemon generation and UTC display time are independent inputs.
local clock = { t = 1000, gen = "g1", utc = 1700000000000, fail = nil }
local ctx = {
  elapsed_ms = function()
    if clock.fail == "throw" then error("clock unavailable") end
    if clock.fail == "string" then return "1000" end
    if clock.fail == "nan" then return 0 / 0 end
    if clock.fail == "negative" then return -5 end
    return clock.t
  end,
  generation = function() return clock.gen end,
  utc_ms = function() return clock.utc end,
}
local function at(t) clock.t = t end
local ag = approval._action_grant
local function G() assert(type(ag) == "table", "approval._action_grant reducer is absent") return ag end

local function spec(o)
  local s = { requester = { agent_id = "req", launch_marker = "m1" },
    executor = { agent_id = "ex", launch_marker = "m2", instance_id = "i1", instance_binding = 1 },
    action = { tool = "Bash", input = { cmd = "ls" } }, context = { cwd = "/x" }, uid = 501,
    lineage = { root = "r1" }, ttl_s = 60 }
  for k, v in pairs(o or {}) do s[k] = v end
  return s
end
local function new(o, t)
  clock.t, clock.gen, clock.fail = t or 1000, "g1", nil
  local snap, why = G().create(ctx, spec(o))
  assert(snap, "create refused: " .. tostring(why))
  return snap.id
end
local function approve(id, t, event)
  at(t or 2000)
  local snap, why = G().answer(ctx, id, "approve", "@owner:x", event or "$a1")
  assert(snap, "approve refused: " .. tostring(why))
  return snap
end
local function evidence(o)
  local e = { proof_verified = true, live_observed = true, action = spec().action, context = spec().context,
    executor = spec().executor, tool_call_id = "tc1" }
  for k, v in pairs(o or {}) do if v == "nil" then e[k] = nil else e[k] = v end end
  return e
end
local function status(id) return state.approvals[id].status end

local failures, names = {}, {}
local function case(name, fn)
  names[#names + 1] = name
  state.approvals = {}
  local ok, err = pcall(fn)
  if not ok then failures[#failures + 1] = name .. ": " .. tostring(err); print("FAIL " .. name .. ": " .. tostring(err)) end
end

case("state mapping", function()
  local id = new()
  assert(status(id) == "open" and state.approvals[id].kind == "action_grant", "persisted state is open")
  assert(G().snapshot(id).status == "pending", "detached view is pending")
  assert(approve(id).status == "approved" and status(id) == "approved")
  assert(G().consume(ctx, id, evidence()).status == "consumed")
  local d = new(); at(2000)
  assert(G().answer(ctx, d, "deny", "@owner:x", "$d").status == "denied")
  local e = new(); at(61000)
  assert(G().sweep(ctx) == 1 and status(e) == "expired")
  local b = new(); at(1500)
  assert(not G().answer(ctx, b, "consume", "@owner:x", "$z") and status(b) == "open", "no other verdict states")
end)

case("terminal immutability", function()
  local ids = {}
  ids.denied = new(); at(2000); G().answer(ctx, ids.denied, "deny", "@owner:x", "$d")
  ids.expired = new(); at(61000); G().sweep(ctx)
  ids.consumed = new(); approve(ids.consumed, 2000); G().consume(ctx, ids.consumed, evidence())
  for name, id in pairs(ids) do
    assert(status(id) == name, name .. " setup")
    local before_raw, before_snap = raw(id), deep(G().snapshot(id))
    at(3000)
    assert(not G().answer(ctx, id, "approve", "@other:x", "$n1"), name .. " approve")
    assert(not G().answer(ctx, id, "deny", "@other:x", "$n2"), name .. " deny")
    assert(not G().consume(ctx, id, evidence({ tool_call_id = "tc2" })), name .. " consume")
    assert(not G().renew(ctx, id), name .. " renewal in place")
    assert(same(raw(id), before_raw) and same(G().snapshot(id), before_snap), name .. " record changed")
  end
end)

case("deadline equality", function()
  local a = new(); approve(a, 60999)
  assert(G().snapshot(a).deadline_elapsed_ms == 61000)
  local c = new(); approve(c, 2000); at(60999)
  assert(G().consume(ctx, c, evidence()), "consume qualifies at 60999")
  for _, t in ipairs({ 61000, 61001 }) do
    local o = new(); at(t)
    assert(not G().answer(ctx, o, "approve", "@owner:x", "$e") and status(o) == "expired", "approve at " .. t)
    local p = new(); approve(p, 2000); at(t)
    assert(not G().consume(ctx, p, evidence()) and status(p) == "expired", "consume at " .. t)
  end
end)

case("approved-unused expiry", function()
  local id = new(); approve(id, 2000); at(61000)
  assert(G().sweep(ctx) == 1)
  local r = state.approvals[id]
  assert(r.status == "expired" and r.previous_status == "approved" and r.expire_reason, "expired with reason")
  assert(r.answered_by == "@owner:x" and r.answer_event_id == "$a1" and r.answer_verdict == "approve", "answer intact")
  assert(r.consumed_at == nil and r.consumed_elapsed_ms == nil and r.tool_call_id == nil, "no consume fields")
end)

case("no deadline reset", function()
  local id = new(); approve(id, 60999)
  assert(G().snapshot(id).deadline_elapsed_ms == 61000, "approval does not move the deadline")
  at(61000)
  assert(not G().consume(ctx, id, evidence()) and status(id) == "expired")
end)

case("UTC jumps", function()
  local DAY = 86400000
  local id = new(); local base = G().snapshot(id)
  clock.utc = clock.utc - DAY
  approve(id, 30000)
  clock.utc = clock.utc + 2 * DAY
  assert(G().snapshot(id).deadline_elapsed_ms == base.deadline_elapsed_ms, "deadline is elapsed-based")
  at(60999); assert(G().consume(ctx, id, evidence()), "forward UTC jump does not expire")
  clock.utc = 1700000000000
  local o = new(); clock.utc = clock.utc - DAY; at(61000)
  assert(not G().answer(ctx, o, "approve", "@owner:x", "$e") and status(o) == "expired", "backward UTC does not extend")
  clock.utc = 1700000000000
end)

case("clock/generation uncertainty", function()
  for _, mode in ipairs({ "throw", "string", "nan", "negative" }) do
    local o = new(); clock.fail = mode
    assert(not G().answer(ctx, o, "approve", "@owner:x", "$e") and status(o) == "expired", mode .. " open")
    assert(state.approvals[o].expire_reason, mode .. " reason")
    clock.fail = nil
    local a = new(); approve(a, 2000); clock.fail = mode
    assert(not G().consume(ctx, a, evidence()) and status(a) == "expired", mode .. " approved")
    clock.fail = nil
  end
  local b = new(); approve(b, 5000); at(4000)
  assert(not G().consume(ctx, b, evidence()) and status(b) == "expired", "backward elapsed")
  local g = new(); approve(g, 2000); clock.gen = "g2"
  assert(not G().consume(ctx, g, evidence()) and status(g) == "expired", "generation change")
  local g2 = new(); clock.gen = "g2"
  assert(not G().answer(ctx, g2, "approve", "@owner:x", "$e") and status(g2) == "expired", "generation change open")
  -- Same-generation reload retains the origin and the equality boundary; a new generation expires unused records.
  local r = new(); approve(r, 2000); attach(); at(60999)
  assert(G().consume(ctx, r, evidence()), "same-generation reload keeps the record usable")
  local s = new(); approve(s, 2000); attach(); at(61000)
  assert(not G().consume(ctx, s, evidence()) and status(s) == "expired", "reload keeps the equality boundary")
  local n = new(); approve(n, 2000); attach(); clock.gen = "g2"
  assert(G().sweep(ctx) >= 1 and status(n) == "expired", "new generation expires unused")
end)

case("TTL validation", function()
  for _, bad in ipairs({ 0, -1, 0 / 0, math.huge, -math.huge, 1.5, "60", true, {}, 86401 }) do
    clock.t, clock.gen, clock.fail = 1000, "g1", nil
    local snap = G().create(ctx, spec({ ttl_s = bad }))
    assert(snap == nil, "ttl " .. tostring(bad) .. " must refuse")
  end
  assert(G().snapshot(new({ ttl_s = 1 })).deadline_elapsed_ms == 2000)
  assert(G().snapshot(new({ ttl_s = 86400 })).deadline_elapsed_ms == 86401000)
  local s = spec(); s.ttl_s = nil
  clock.t = 1000
  local snap = assert(G().create(ctx, s))
  assert(snap.ttl_s == 1800 and snap.deadline_elapsed_ms == 1801000, "configured default 1800 s")
  approval.ttl_minutes = 0
  assert(G().create(ctx, s) == nil, "invalid configured default refuses")
  approval.ttl_minutes = 1441
  assert(G().create(ctx, s) == nil, "over-cap configured default refuses")
  approval.ttl_minutes = 30
end)

case("immutable binding", function()
  local o = spec(); clock.t, clock.gen = 1000, "g1"
  local snap = assert(G().create(ctx, o)); local id = snap.id
  local before = raw(id)
  o.requester.agent_id, o.executor.instance_id, o.action.tool, o.action.input.cmd = "evil", "i9", "Rm", "rm"
  o.context.cwd, o.lineage.root, o.uid = "/etc", "r9", 0
  snap.executor.instance_id, snap.action.input.cmd, snap.deadline_elapsed_ms, snap.generation = "i9", "rm", 1, "g9"
  local view = G().snapshot(id); view.context.cwd, view.lineage.root = "/etc", "r9"
  assert(same(raw(id), before), "stored record is independent of caller tables")
  approve(id, 2000)
  assert(not G().consume(ctx, id, evidence({ action = { tool = "Bash", input = { cmd = "rm" } } })), "action mismatch")
  assert(not G().consume(ctx, id, evidence({ executor = { agent_id = "ex", launch_marker = "m2", instance_id = "i9", instance_binding = 1 } })),
    "executor mismatch")
  assert(status(id) == "approved")
end)

case("first-answer precedence", function()
  local a = new(); approve(a, 2000, "$first")
  local rev = state.approvals[a].revision
  assert(not G().answer(ctx, a, "deny", "@x:x", "$second") and not G().answer(ctx, a, "approve", "@x:x", "$third"))
  local r = state.approvals[a]
  assert(r.status == "approved" and r.answer_event_id == "$first" and r.answered_by == "@owner:x" and r.revision == rev)
  local d = new(); at(2000); assert(G().answer(ctx, d, "deny", "@owner:x", "$d"))
  assert(not G().answer(ctx, d, "approve", "@owner:x", "$d2") and status(d) == "denied")
  local dup = new(); approve(dup, 2000, "$same"); local r2 = state.approvals[dup].revision
  assert(not G().answer(ctx, dup, "approve", "@owner:x", "$same") and state.approvals[dup].revision == r2, "duplicate no-op")
  at(61000); G().sweep(ctx)
  assert(status(a) == "expired" or status(dup) == "expired", "expiry after approval allowed")
  assert(state.approvals[dup].answer_event_id == "$same" and state.approvals[dup].previous_status == "approved")
end)

case("no automatic application", function()
  local id = new(); approve(id, 2000)
  effects.handler = 0
  assert(approval.reapply_approved() == 0, "recovery never counts or applies this kind")
  attach()
  assert(effects.handler == 0 and status(id) == "approved", "handler never called, still approved")
end)

case("consume preconditions", function()
  local variants = {
    { "proof false", evidence({ proof_verified = false }) }, { "proof missing", evidence({ proof_verified = "nil" }) },
    { "action", evidence({ action = { tool = "Edit", input = { cmd = "ls" } } }) },
    { "context", evidence({ context = { cwd = "/y" } }) },
    { "other instance", evidence({ executor = { agent_id = "ex", launch_marker = "m2", instance_id = "i2", instance_binding = 1 } }) },
    { "legacy executor", evidence({ executor = { agent_id = "ex", launch_marker = "m2" } }) },
    { "not live", evidence({ live_observed = false }) }, { "tool id missing", evidence({ tool_call_id = "nil" }) },
    { "tool id empty", evidence({ tool_call_id = "" }) },
  }
  for _, v in ipairs(variants) do
    local id = new(); approve(id, 2000); local before = raw(id); at(3000)
    assert(not G().consume(ctx, id, v[2]), v[1] .. " must refuse")
    assert(same(raw(id), before), v[1] .. " must not change the record")
  end
  local open = new(); at(3000); assert(not G().consume(ctx, open, evidence()) and status(open) == "open", "state open")
  local gen = new(); approve(gen, 2000); clock.gen = "g2"; assert(not G().consume(ctx, gen, evidence()), "generation")
  local late = new(); approve(late, 2000); clock.gen = "g1"; at(61000); assert(not G().consume(ctx, late, evidence()), "deadline")
  local ok = new(); approve(ok, 2000); local rev = state.approvals[ok].revision; at(3000)
  local snap = G().consume(ctx, ok, evidence())
  assert(snap and snap.status == "consumed" and snap.revision == rev + 1 and snap.tool_call_id == "tc1", "valid consumes once")
end)

case("spent stays spent", function()
  local id = new(); approve(id, 2000); at(3000)
  assert(G().consume(ctx, id, evidence()))
  local before = raw(id)
  assert(not G().consume(ctx, id, evidence()), "repeat (lost result retry)")
  assert(not G().consume(ctx, id, evidence({ tool_call_id = "tc9", action = { tool = "x" } })), "mismatch")
  assert(same(raw(id), before) and status(id) == "consumed")
end)

case("no approval effects", function()
  for k in pairs(effects) do effects[k] = 0 end
  local id = new(); approve(id, 2000)
  assert(status(id) == "approved")
  for k, v in pairs(effects) do assert(v == 0, "effect " .. k .. " fired " .. v .. " times") end
end)

case("helper equality", function()
  assert(type(approval.same_incarnation) == "function", "approval.same_incarnation is absent")
  local base = { agent_id = "ex", launch_marker = "m2", instance_id = "i1", instance_binding = 1 }
  assert(approval.same_incarnation(base, deep(base)) == "same_proven")
  for _, change in ipairs({ { agent_id = "other" }, { launch_marker = "m9" }, { instance_id = "i2" },
      { instance_binding = "nil" }, { instance_binding = 2 }, { instance_id = "nil" }, { instance_id = "" } }) do
    local other = deep(base)
    for k, v in pairs(change) do if v == "nil" then other[k] = nil else other[k] = v end end
    assert(approval.same_incarnation(base, other) ~= "same_proven", "changed " .. next(change))
  end
  for _, bad in ipairs({ "x", 1, false }) do
    assert(approval.same_incarnation(base, bad) == "different" and approval.same_incarnation(bad, bad) == "different")
  end
  assert(approval.same_incarnation(nil, nil) == "different")
end)

case("legacy helper", function()
  local l1 = { agent_id = "ex", launch_marker = "m2" }
  assert(approval.same_incarnation(l1, deep(l1)) == "legacy_advisory", "marker-only equality is advisory")
  local proven = { agent_id = "ex", launch_marker = "m2", instance_id = "i1", instance_binding = 1 }
  assert(approval.same_incarnation(proven, l1) ~= "same_proven" and approval.same_incarnation(l1, proven) ~= "same_proven")
  assert(approval.same_incarnation({ agent_id = "ex", alias = "a", session = "s" }, { agent_id = "ex", alias = "a", session = "s" })
    ~= "same_proven", "alias/session equality alone never qualifies")
  assert(approval.same_incarnation({ agent_id = "ex", launch_marker = "m2" }, { agent_id = "ex", launch_marker = "m3" }) == "different")
end)

case("stale death", function()
  local old = new(); local fresh = new({ executor = { agent_id = "ex", launch_marker = "m3", instance_id = "i2", instance_binding = 1 } })
  at(1500)
  assert(G().on_death(ctx, { agent_id = "ex", launch_marker = "m2", instance_id = "i0", instance_binding = 1 }) == 0, "stale instance")
  assert(G().on_death(ctx, { agent_id = "ex", launch_marker = "m1", instance_id = "i1", instance_binding = 1 }) == 0, "stale launch marker")
  assert(G().on_death(ctx, { agent_id = "ex" }) == 0, "ambiguous exit")
  assert(status(old) == "open" and status(fresh) == "open")
  assert(G().on_death(ctx, { agent_id = "ex", launch_marker = "m2", instance_id = "i1", instance_binding = 1 }) >= 1)
  assert(status(old) == "expired" and state.approvals[old].expire_reason and status(fresh) == "open", "only the matching unused record")
end)

case("public isolation", function()
  local posts, done_id, done_why = effects.post, "unset", nil
  local handle = approval.request({ kind = "action_grant", key = "k", asker = "a", summary = "s", data = {} },
    function(id, why) done_id, done_why = id, why end)
  assert(handle == nil and done_id == nil and done_why, "approval.request refuses action_grant")
  assert(effects.post == posts, "refused request posted nothing")
  for _, rec in pairs(state.approvals) do assert(rec.key ~= "k", "no record created") end
  local id = new()
  for _, verdict in ipairs({ "approve", "deny", "grant" }) do
    local ok = approval.answer(id, verdict, "@owner:x", "$g" .. verdict)
    assert(not ok and status(id) == "open", "generic answer " .. verdict)
  end
  assert(not approval.answer(id, "approve", "operator (terminal)") and status(id) == "open")
  local cli_a, cli_d = approval.cli({ "approve", id }), approval.cli({ "deny", id })
  assert(not tostring(cli_a):find("Approved request", 1, true) and not tostring(cli_d):find("Denied request", 1, true))
  assert(status(id) == "open", "CLI cannot answer")
  assert(not approval.cli({ "approvals" }):find("action_grant", 1, true), "CLI listing hides the kind")
  assert(approval.sweep(clock.utc + 10 ^ 12) == 0 and status(id) == "open", "wall-clock sweep never expires it")
  assert(approval.reapply_approved() == 0)
end)

if #failures > 0 then
  error(#failures .. "/" .. #names .. " cases failed:\n" .. table.concat(failures, "\n"), 0)
end
print("ok - action_grant reducer cases (" .. #names .. ")")
