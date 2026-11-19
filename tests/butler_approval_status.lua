-- Read-only approval status projection. Synthetic records only: no live
-- requests, decisions, sessions, prepared text or Matrix traffic.
local function json_encode(value)
  local kind = type(value)
  if kind == "string" then
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
      if char == '"' or char == '\\' then return '\\' .. char end
      return string.format('\\u%04x', char:byte())
    end) .. '"'
  end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind == "table" then
    if #value > 0 then
      local parts = {}
      for i, item in ipairs(value) do parts[i] = json_encode(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = json_encode(key) .. ":" .. json_encode(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

remuda = {
  json = {
    null = {}, object = function(value) return value end,
    array = function(value) return value end, encode = json_encode,
  },
  butler = { matrix = { sanitize_directory_text = function(value) return value end } },
  cli = { parse = function(_, args)
    local verb = args[1]
    local values = {}
    for i = 2, #args do
      if args[i] == "--json" and verb == "approvals" and not values.json then
        values.json = true
      elseif args[i] == "--help" or args[i] == "-h" then
        return { kind = "help", ok = true, text = "help", values = {} }
      else
        return { ok = false, kind = "error", text = "unexpected argument", values = {} }
      end
    end
    return { ok = true, verb = verb, values = values }
  end },
  fail = function(message) return "FAIL:" .. message end,
}

local approval = dofile("packages/butler/approval.lua")

-- Unattached must never look like an empty list.
assert(approval.list() == nil, "an unattached store is unavailable")
assert(select(2, approval.list()) == "unavailable", "unavailable reason is explicit")
assert(approval.snapshot() == nil, "an unattached store has no snapshot")

local base = math.floor(os.time() * 1000)
local state = { approvals = {} }
local saved = 0
approval.attach(state, function() saved = saved + 1; return true end,
  function() error("the unit test never posts") end)
assert(#approval.list() == 0, "an attached empty store is empty")

local function record(id, kind, status, order, extra)
  local rec = { id = id, kind = kind, status = status, asker = "worker-" .. id,
    summary = "summary " .. id, created_ms = base + order * 1000,
    expires_at = base + 60000, nonce = "SECRET-NONCE-" .. id,
    data = { text = "SECRET-TEXT-" .. id }, event_id = "$event" .. id }
  for key, value in pairs(extra or {}) do rec[key] = value end
  state.approvals[id] = rec
  return rec
end
record("AAAA", "approve_text", "open", 1)
record("BBBB", "approve_text", "approved", 2)
record("CCCC", "approve_text", "approved", 3, { delivery_started = true })
record("DDDD", "approve_text", "queued", 4)
record("EEEE", "approve_text", "delivery_uncertain", 5)
record("FFFF", "approve_text", "delivery_quarantined", 6)
record("GGGG", "dialog_action", "open", 7, { summary = "line one\nline two" })
record("HHHH", "approve_text", "applied", 8)
record("IIII", "dialog_action", "open", 9,
  { data = { session = "target-iiii", instance_id = "instance-iiii" } })
record("JJJJ", "approve_text", "approved", 10,
  { answered_by = "@alice:example.org", answer_event_id = "$answer-jjjj",
    data = { session = "target-jjjj" } })
-- Synthetic: terminal approve is refused today, so "operator" can only appear
-- once terminal rows are listed; this checks the projection mapping itself.
record("KKKK", "approve_text", "approved", 11, { answered_by = "operator (terminal)" })
record("LLLL", "approve_text", "open", 12,
  { data = { session = "target-llll", core_instance = "core-llll" } })
record("MMMM", "approve_text", "open", 13,
  { data = { session = "target-mmmm", session_binding_version = 2, session_marker = "marker-mmmm" } })

local snapshot = assert(approval.snapshot(base + 30000))
assert(snapshot.schema == 1 and snapshot.authority == "butler-local", "snapshot identity")
assert(snapshot.generated_at == base + 30000, "snapshot time is explicit")
assert(#snapshot.records == 12, "open and in-flight records are listed, terminal rows are not")

local rows, order = {}, {}
for _, row in ipairs(snapshot.records) do
  rows[row.id], order[#order + 1] = row, row.id
end
assert(table.concat(order, ",")
  == "AAAA,BBBB,CCCC,DDDD,EEEE,FFFF,GGGG,IIII,JJJJ,KKKK,LLLL,MMMM",
  "oldest request first")
assert(rows.AAAA.status == "open" and rows.AAAA.delivery == "none", "open prepared text is undecided")
assert(rows.BBBB.status == "approved" and rows.BBBB.delivery == "not_started",
  "an approved request is decided but not delivered")
assert(rows.CCCC.delivery == "in_flight", "an approved request already writing is in flight")
assert(rows.DDDD.delivery == "queued", "queue acceptance is visible")
assert(rows.EEEE.delivery == "uncertain", "an uncertain delivery stays explicit")
assert(rows.FFFF.delivery == "quarantined", "a quarantined delivery stays explicit")
assert(rows.GGGG.delivery == "not_applicable", "a dialog action has no prepared-text delivery")
assert(rows.GGGG.summary == "line one line two", "untrusted text cannot break a row")
assert(rows.AAAA.expires_in_s == 30 and rows.AAAA.expires_at == base + 60000, "expiry projection")
assert(rows.AAAA.asker == "worker-AAAA", "the requesting session is identified")
assert(rows.AAAA.target_session == nil and rows.AAAA.instance_bound == nil
  and rows.AAAA.decision_path == nil, "a plain request has no target, binding or decision path")
assert(rows.IIII.target_session == "target-iiii", "the target session is projected")
assert(rows.IIII.instance_bound == true, "an instance id marks the request instance-bound")
assert(rows.IIII.decision_path == nil, "an open request has no decision path")
assert(rows.JJJJ.target_session == "target-jjjj", "the target survives a decided request")
assert(rows.JJJJ.instance_bound == nil, "no instance evidence stays unknown, not false")
assert(rows.JJJJ.decision_path == "owner_matrix", "a Matrix owner answer names its path")
assert(rows.KKKK.target_session == nil and rows.KKKK.instance_bound == nil,
  "a request without target data omits both fields")
assert(rows.KKKK.decision_path == "operator", "a terminal answer names the operator path")
assert(rows.LLLL.instance_bound == true, "a core instance marks the request instance-bound")
assert(rows.MMMM.instance_bound == true, "a session binding marker marks the request instance-bound")

for _, row in ipairs(snapshot.records) do
  assert(row.data == nil and row.nonce == nil and row.event_id == nil and row.text == nil
    and row.registered_text == nil and row.session_marker == nil and row.instance_id == nil,
    "metadata only: no prepared text, nonce or event proof")
end

assert(approval.status_label(state.approvals.AAAA) == "open", "open label")
assert(approval.status_label(state.approvals.CCCC) == "delivering", "delivering label")
assert(approval.status_label(state.approvals.DDDD) == "queued", "queued label")
assert(approval.status_label(state.approvals.EEEE) == "delivery uncertain", "uncertain label")
assert(approval.status_label(state.approvals.FFFF) == "delivery quarantined", "quarantined label")

local encoded = json_encode(snapshot)
assert(not encoded:find("SECRET", 1, true), "prepared text and nonce never reach the projection")
assert(encoded:find('"authority":"butler-local"', 1, true), "authority is labeled local")
assert(encoded:find('"delivery":"uncertain"', 1, true), "delivery is encoded")

-- The text projection names the lifecycle state in the row.
local text = approval.cli({ "approvals" })
assert(text:find("STATUS", 1, true) and text:find("delivery uncertain", 1, true),
  "the operator list shows the lifecycle state: " .. tostring(text))
assert(text:find("worker-EEEE", 1, true), "the operator list names the requesting session")

local json = approval.cli({ "approvals", "--json" })
assert(type(json) == "string" and json:find('"records":[', 1, true), "the JSON list is encoded")
assert(not json:find("SECRET", 1, true), "the JSON list leaks no prepared text")
print("approval status projection: PASS")
