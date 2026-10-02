-- Owner-approved prepared text. Registration stores the exact bytes; the relay
-- owns the live owner event and this module owns the immutable request data.
local butler = assert(remuda.butler, "load butler/matrix before butler/approve_text")
local approval = assert(butler.approval, "load butler/approval before butler/approve_text")
local M = butler.approve_text or {}
butler.approve_text = M

local MAX_BYTES = 8 * 1024
local DEFAULT_TTL = 60 * 60
local MAX_TTL = 24 * 60 * 60
local request_counter = 0

local function normalized_text(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for i = 1, #text do
    local byte = text:byte(i)
    if byte < 32 and byte ~= 9 and byte ~= 10 then return nil, "control_character" end
    if byte == 127 then return nil, "control_character" end
    if byte == 0xC2 and i < #text then
      local next_byte = text:byte(i + 1)
      if next_byte >= 0x80 and next_byte <= 0x9F then return nil, "control_character" end
    end
  end
  return text
end

function M.prepare(session, text, request_id)
  if type(session) ~= "string" or session == "" then return nil, "invalid_session" end
  if type(text) ~= "string" or text == "" then return nil, "empty_text" end
  local normalized, normalize_error = normalized_text(text)
  if not normalized then return nil, normalize_error end
  text = normalized
  if #text == 0 then return nil, "empty_text" end
  if #text > MAX_BYTES then return nil, "text_too_long" end
  if type(request_id) ~= "string" then request_id = "" end
  return { session = session, bytes = #text, registered_text = text,
    stored_text = text, posted_text = text, request_id = request_id,
    display_fingerprint = request_id .. "/" .. tostring(#text) }
end

function M.matches(record)
  if type(record) ~= "table" or type(record.registered_text) ~= "string"
    or type(record.posted_text) ~= "string" or type(record.stored_text) ~= "string" then return false end
  return record.registered_text == record.stored_text and record.posted_text == record.stored_text
    and tonumber(record.bytes) == #record.registered_text
end

local BIDI_ESCAPES = {
  ["\226\128\142"] = "\\u200E", ["\226\128\143"] = "\\u200F",
  ["\226\128\168"] = "\\u2028", ["\226\128\169"] = "\\u2029",
  ["\226\128\170"] = "\\u202A", ["\226\128\171"] = "\\u202B",
  ["\226\128\172"] = "\\u202C", ["\226\128\173"] = "\\u202D",
  ["\226\128\174"] = "\\u202E", ["\226\129\166"] = "\\u2066",
  ["\226\129\167"] = "\\u2067", ["\226\129\168"] = "\\u2068",
  ["\226\129\169"] = "\\u2069", ["\216\156"] = "\\u061C",
  ["\226\129\170"] = "\\u206A", ["\226\129\171"] = "\\u206B",
  ["\226\129\172"] = "\\u206C", ["\226\129\173"] = "\\u206D",
  ["\226\129\174"] = "\\u206E", ["\226\129\175"] = "\\u206F",
}

local function display_line(line)
  local out, escaped = {}, false
  local i = 1
  while i <= #line do
    local byte = line:byte(i)
    if byte < 32 or byte == 127 then
      out[#out + 1] = byte == 9 and "\\t" or string.format("\\x%02X", byte)
      escaped = true
      i = i + 1
    else
      local special
      for size = 2, 3 do
        local candidate = line:sub(i, i + size - 1)
        if BIDI_ESCAPES[candidate] then special = candidate; break end
      end
      if special then
        out[#out + 1] = BIDI_ESCAPES[special]
        escaped, i = true, i + #special
      elseif byte == 0xC2 and line:byte(i + 1) and line:byte(i + 1) >= 0x80
          and line:byte(i + 1) <= 0x9F then
        out[#out + 1] = string.format("\\u%04X", line:byte(i + 1))
        escaped, i = true, i + 2
      else
        out[#out + 1] = line:sub(i, i)
        i = i + 1
      end
    end
  end
  return table.concat(out), escaped
end

function M.display(text)
  local lines, escaped = {}, false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local shown, line_escaped = display_line(line)
    lines[#lines + 1] = "> " .. shown
    escaped = escaped or line_escaped
  end
  local note = escaped and "\nControl and direction characters are shown escaped." or ""
  return table.concat(lines, "\n") .. note, escaped
end

function M.reply_verdict(body)
  if type(body) ~= "string" then return nil end
  body = body:match("^%s*(.-)%s*$") or ""
  local word, id = body:match("^(%S+)%s+(%w%w%w%w)$")
  if word then body = word end
  body = body:lower()
  local verdict = (body == "yes" or body == "승인") and "approve"
    or (body == "no" or body == "거부") and "deny" or nil
  return verdict, id and id:upper() or nil
end

function M.owner_event_allowed(event, record, cfg, live_sync, room_id)
  cfg = type(cfg) == "table" and cfg or {}
  if live_sync ~= true or type(event) ~= "table" or type(record) ~= "table"
      or (event.type ~= "m.room.message" and event.type ~= "m.reaction")
      or type(event.event_id) ~= "string" or event.event_id == ""
      or type(event.sender) ~= "string" or (cfg.allowed_senders or {})[event.sender] ~= true
      or room_id ~= cfg.home_room then return false end
  local content = type(event.content) == "table" and event.content or {}
  local relation = type(content["m.relates_to"]) == "table" and content["m.relates_to"] or {}
  if content["m.new_content"] ~= nil or relation.rel_type == "m.replace" then
    return false
  end
  if event.sender == cfg.self_mxid or (cfg.butler_senders or {})[event.sender] == true then return false end
  local localpart = event.sender:match("^@([^:]+):.+$")
  if not localpart then return false end
  local normalized = localpart:lower()
  if normalized:sub(1, 6) == "agent-" or normalized:sub(1, 7) == "butler-" then return false end
  local event_ms, created_ms = tonumber(event.origin_server_ts), tonumber(record.created_ms)
  return event_ms ~= nil and created_ms ~= nil and event_ms >= created_ms - 30000
end

local function provenance_text(provenance)
  provenance = type(provenance) == "table" and provenance or {}
  local function field(value)
    return tostring(value or ""):gsub("[%c]", " "):sub(1, 256)
  end
  return "owner=" .. field(provenance.owner) .. " event=" .. field(provenance.event_id)
    .. " request=" .. field(provenance.request_id)
end

local function live_agent(session)
  local bus = remuda._butler_bus or {}
  for id, agent in pairs(bus.agents or {}) do
    if type(agent) == "table" and (agent.session_name or id) == session then return id, agent end
  end
end

function M.session_instance(session)
  if not M.target_session_allowed(session) then return nil end
  local id, agent = live_agent(session)
  if not id or type(agent.id) ~= "string" then return nil end
  return agent.id
end

local function pane_has_human(session)
  if type(remuda.ls) ~= "function" then return true end
  local ok, rows = pcall(remuda.ls)
  if not ok or type(rows) ~= "table" then return true end
  local live = false
  for _, row in ipairs(rows) do
    if type(row) == "table" and row.name == session then
      live = row.alive == true
      if row.attached == true then return true end
    end
  end
  if not live then return true end
  if type(remuda.session) == "function" then
    local checked, current = pcall(remuda.session, session)
    if not checked or not current then return true end
    local read_ok, attached = pcall(function() return current.attached end)
    if not read_ok or attached == true then return true end
  end
  return false
end

function M.type_text(session, exact_bytes, provenance)
  if type(session) ~= "string" or session == "" or type(exact_bytes) ~= "string" then
    return false, "invalid_request"
  end
  local bus = remuda._butler_bus or {}
  if type(bus.pending_tasks) == "table" and bus.pending_tasks[session] then
    return false, "pane_busy"
  end
  if pane_has_human(session) then return false, "human_attached" end
  if type(remuda._butler_notify_policy) ~= "function" then return false, "pane_busy" end
  local checked, safe = pcall(remuda._butler_notify_policy, session)
  if not checked or not safe then return false, "pane_busy" end
  if type(remuda.type_text) ~= "function" then return false, "type_failed" end
  if type(provenance) == "table" and type(provenance.before_write) == "function" then
    local marked, allowed = pcall(provenance.before_write)
    if not marked or allowed ~= true then return false, "delivery_marker_failed" end
  end
  local typed, result = pcall(remuda.type_text, session, exact_bytes)
  if not typed or result == false then return false, "type_failed", true end
  local trace = remuda._butler_session_trace or _G._butler_session_trace
  if type(trace) == "function" then
    pcall(trace, "matrix_approved_text", "target=" .. session .. " " .. provenance_text(provenance)
      .. " outcome=typed bytes=" .. tostring(#exact_bytes))
  end
  return true
end

local function request(session, text, asker, ttl_s, done)
  done = type(done) == "function" and done or function() end
  if type(asker) ~= "string" or asker == "" then
    done(nil, "invalid_asker")
    return nil, "invalid_asker"
  end
  local prepared, why = M.prepare(session, text)
  if not prepared then
    done(nil, why)
    return nil, why
  end
  local session_id = M.session_instance(session)
  if not session_id then
    local failure = "Target is not a live Butler session. Next: choose a live session and retry."
    done(nil, failure)
    return nil, failure
  end
  local live_config = remuda._butler_matrix_live_config or {}
  if live_config.approve_text ~= true then
    local failure = "Prepared text approvals are off. Next: remuda butler approve-text on"
    done(nil, failure)
    return nil, failure
  end
  request_counter = request_counter + 1
  local key = tostring(os.time()) .. ":" .. tostring(request_counter)
  local requested_id, failure
  local request_data = { registered_text = prepared.registered_text, stored_text = prepared.stored_text,
    posted_text = prepared.posted_text, session = session, session_id = session_id, bytes = prepared.bytes }
  local bounded_ttl = math.max(1, math.min(MAX_TTL, tonumber(ttl_s) or DEFAULT_TTL))
  local result = approval.request({ kind = "approve_text", key = key,
    asker = asker, summary = "type " .. tostring(prepared.bytes) .. " prepared bytes in " .. session,
    ttl_s = bounded_ttl, data = request_data, rate_limit_per_window = 10,
    max_open_for_asker = 5,
    rate_window_s = 600,
    on_id = function(id) requested_id = id end,
    render = function(rec)
      local data = rec.data
      local id = tostring(rec.id)
      data.request_id = id
      data.display_fingerprint = id .. "/" .. tostring(data.bytes)
      local shown = M.display(data.posted_text)
      local expires = tonumber(rec.expires_at) or (os.time() * 1000)
      return table.concat({ "Approve prepared text for " .. session,
        "Request " .. id .. " · " .. tostring(data.bytes) .. " bytes",
        "Fingerprint " .. data.display_fingerprint,
        "Expires " .. os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(expires / 1000)),
        "Asked by " .. tostring(asker),
        "React ✅ or reply yes " .. id .. " to approve; ❌ or no " .. id .. " to deny.",
        shown }, "\n")
    end,
  }, function(id, why)
    if not id then failure = why end
    done(id, why)
  end)
  if failure then return nil, failure end
  return requested_id or result, nil
end

function M.request(session, text, asker, done)
  return request(session, text, asker, nil, done)
end

local function fail(message)
  if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
  return nil, message
end

function M.target_session_allowed(session)
  if session == "butler" then return true end
  local bus = remuda._butler_bus or {}
  local agents = bus.agents or {}
  local root = agents.butler or {}
  local root_id = type(root) == "table" and root.id or "butler"
  local function in_tree(id)
    local current, visited = id, {}
    while type(current) == "string" and current ~= "" and not visited[current] do
      if current == root_id or current == "butler" then return true end
      visited[current] = true
      local agent = agents[current]
      current = type(agent) == "table" and agent.parent or nil
    end
    return false
  end
  for id, agent in pairs(agents) do
    if type(agent) == "table" and agent.session_name == session and in_tree(id) then return true end
  end
  return false
end

function M.cli(args, agent, stdin)
  if type(args) ~= "table" or type(args[1]) ~= "string" then return fail("Usage: remuda butler approve-text request SESSION - | on|off") end
  if args[1] == "on" or args[1] == "off" then
    local cli = butler.typed_lines_cli
    if not cli then return fail("Approve text switch is unavailable") end
    return cli.cli({ "approve-text", args[1] }, agent)
  end
  if args[1] ~= "request" or #args ~= 3 or args[3] ~= "-" then
    return fail("Usage: remuda butler approve-text request SESSION - | on|off")
  end
  if not M.target_session_allowed(args[2]) then return fail("Unknown Butler session: " .. tostring(args[2])) end
  local id, why = M.request(args[2], stdin, agent or "operator")
  if not id then return fail(tostring(why or "Could not register prepared text")) end
  return "Registered prepared text request " .. tostring(id)
end

function M.configure()
  approval.handler("approve_text", {
    approve = function(rec, complete)
      local data = type(rec.data) == "table" and rec.data or {}
      if not M.matches(data) or data.request_id ~= rec.id then
        complete(false, "text_changed")
        return
      end
      if not M.target_session_allowed(data.session) or M.session_instance(data.session) ~= data.session_id then
        pcall(approval.reply, rec, "refused: session_changed")
        complete("retry", "session_changed")
        return
      end
      local ok, why = M.type_text(data.session, data.registered_text, {
        owner = rec.answered_by, event_id = rec.answer_event_id, request_id = rec.id,
        before_write = function() return approval.begin_delivery(rec) end,
      })
      if ok then
        pcall(approval.reply, rec, "typed")
        complete(true)
      else
        pcall(approval.reply, rec, "refused: " .. tostring(why))
        if rec.delivery_started == true then complete(false, why)
        else complete("retry", why) end
      end
    end,
    deny = function(rec) pcall(approval.reply, rec, "denied") end,
    expire = function(rec) pcall(approval.reply, rec, "expired") end,
  })
end

M.configure()
return M
