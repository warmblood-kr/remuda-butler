-- Read-only approval list/status through the real CLI front door. Synthetic
-- records only: no decisions, delivery, Matrix traffic or live sessions.
local started

local function start_butler()
  if started then return end
  started = true
  T.install_mod("butler", assert(os.getenv("REMUDA_LUA_REPO")))
  T.eval('remuda._butler_argv = {"sh", "-c", "sleep 60"}; remuda._butler_skip_relay = true; remuda._butler_readiness_timeout = 1')
  T.eval('return remuda.exec("butler")')
  T.wait_until(function()
    return T.eval('return remuda._butler_bus ~= nil and remuda._butler_bus.agents.butler ~= nil')
      :match("^%s*true%s*$") ~= nil
  end, 10, "Butler root start")
end

local function run(args)
  local words = {}
  for i, word in ipairs(args) do words[i] = string.format("%q", word) end
  return T.eval("return remuda._butler_command_run('approvals', {"
    .. table.concat(words, ",") .. "}, { kind = 'outside' })")
end

T.test("an unattached approval store is unavailable, never an empty list", function()
  start_butler()
  -- With the relay skipped, no store is attached.
  local ok, value = pcall(run, { "approvals" })
  local text = tostring(value)
  T.ok(not ok and text:find("Approval store unavailable", 1, true),
    "unavailable list must say so: ok=" .. tostring(ok) .. " value=" .. text)
  local json_ok, json_value = pcall(run, { "approvals", "--json" })
  T.ok(not json_ok and tostring(json_value):find("this is not an empty list", 1, true),
    "unavailable JSON must not look empty: " .. tostring(json_value))
end)

T.test("open, decided and uncertain rows are distinguishable and metadata only", function()
  start_butler()
  T.eval([[
    remuda._t_state = { approvals = remuda.json.object({}) }
    remuda.butler.approval.attach(remuda._t_state, function() return true end, function() return {} end)
    local base = os.time() * 1000
    local function add(id, status, extra)
      local rec = { id = id, kind = "approve_text", status = status, asker = "worker-" .. id,
        summary = "synthetic " .. id, created_ms = base, expires_at = base + 3600000,
        nonce = "SECRET-NONCE", data = { text = "SECRET-TEXT" }, event_id = "$e" .. id }
      for key, value in pairs(extra or {}) do rec[key] = value end
      remuda._t_state.approvals[id] = rec
    end
    add("AAAA", "open", { data = { text = "SECRET-TEXT", session = "target-a", instance_id = "instance-a" } })
    add("EEEE", "delivery_uncertain")
    add("ZZZZ", "approved", { answered_by = "@alice:example.org", answer_event_id = "$answer" })
    add("TTTT", "applied")
    return "ok"
  ]])
  local text = run({ "approvals" })
  T.expect(text:find("ID  KIND  SUMMARY  ASKER  STATUS  EXPIRES-IN", 1, true), "status header: " .. text)
  T.expect(text:find("AAAA", 1, true) and text:find("worker-AAAA", 1, true), "requesting session: " .. text)
  T.expect(text:find("delivery uncertain", 1, true), "uncertain delivery is explicit: " .. text)
  T.expect(not text:find("SECRET", 1, true), "no prepared text in the list: " .. text)

  local raw = run({ "approvals", "--json" })
  T.expect(not raw:find("SECRET", 1, true), "no prepared text or nonce in JSON: " .. raw)
  local fields = T.eval([[
    local out = ]] .. string.format("%q", raw) .. [[
    local decoded = assert(remuda.json.decode(out))
    return table.concat({ tostring(decoded.authority), tostring(decoded.schema),
      tostring(#decoded.records), tostring(decoded.records[1].status),
      tostring(decoded.records[2].delivery),
      tostring(decoded.records[1].data == nil and decoded.records[1].nonce == nil),
      tostring(decoded.records[1].expires_in_s > 0),
      tostring(decoded.records[1].target_session),
      tostring(decoded.records[1].instance_bound),
      tostring(decoded.records[3].decision_path) }, "|")
  ]])
  T.eq(fields, "butler-local|1|3|open|uncertain|true|true|target-a|true|owner_matrix",
    "JSON projection fields: " .. fields .. " raw=" .. raw)

  T.eval('remuda._t_state.approvals = remuda.json.object({})')
  T.eq(run({ "approvals" }),
    "No open approval requests.\nNext: nothing to do; agent requests appear here.",
    "an attached empty store is empty")
  local empty = run({ "approvals", "--json" })
  T.expect(empty:find('"records":[]', 1, true), "empty JSON records are an array: " .. empty)
end)
