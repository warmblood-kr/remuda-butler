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

function M.prepare(session, text, request_id)
  if type(session) ~= "string" or session == "" then return nil, "invalid_session" end
  if type(text) ~= "string" or text == "" then return nil, "empty_text" end
  if #text > MAX_BYTES then return nil, "text_too_long" end
  if type(request_id) ~= "string" then request_id = "" end
  return { session = session, bytes = #text, registered_text = text,
    posted_text = text, request_id = request_id,
    display_fingerprint = request_id .. "/" .. tostring(#text) }
end

function M.matches(record)
  if type(record) ~= "table" or type(record.registered_text) ~= "string"
    or type(record.posted_text) ~= "string" then return false end
  return record.registered_text == record.posted_text
    and tonumber(record.bytes) == #record.registered_text
end

local function display_line(line)
  local out, escaped = {}, false
  for i = 1, #line do
    local byte = line:byte(i)
    if byte < 32 or byte == 127 then
      out[#out + 1] = byte == 9 and "\\t" or string.format("\\x%02X", byte)
      escaped = true
    else
      out[#out + 1] = line:sub(i, i)
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
  local note = escaped and "\nControl characters are shown escaped." or ""
  return table.concat(lines, "\n") .. note, escaped
end

local function provenance_text(provenance)
  provenance = type(provenance) == "table" and provenance or {}
  local function field(value)
    return tostring(value or ""):gsub("[%c]", " "):sub(1, 256)
  end
  return "owner=" .. field(provenance.owner) .. " event=" .. field(provenance.event_id)
    .. " request=" .. field(provenance.request_id)
end

function M.type_text(session, exact_bytes, provenance)
  if type(session) ~= "string" or session == "" or type(exact_bytes) ~= "string" then
    return false, "invalid_request"
  end
  local bus = remuda._butler_bus or {}
  if type(bus.pending_tasks) == "table" and bus.pending_tasks[session] then
    return false, "pane_busy"
  end
  if type(remuda._butler_notify_policy) ~= "function" then return false, "pane_busy" end
  local checked, safe = pcall(remuda._butler_notify_policy, session)
  if not checked or not safe then return false, "pane_busy" end
  if type(remuda.type_text) ~= "function" then return false, "type_failed" end
  local typed, result = pcall(remuda.type_text, session, exact_bytes)
  if not typed or result == false then return false, "type_failed" end
  if type(remuda.key) ~= "function" then return false, "return_failed" end
  local pressed, key_result = pcall(remuda.key, session, "RET")
  if not pressed or key_result == false then return false, "return_failed" end
  local trace = remuda._butler_session_trace or _G._butler_session_trace
  if type(trace) == "function" then
    pcall(trace, "matrix_approved_text", "target=" .. session .. " " .. provenance_text(provenance)
      .. " outcome=typed bytes=" .. tostring(#exact_bytes))
  end
  return true
end

local function request(session, text, asker, ttl_s, done)
  done = type(done) == "function" and done or function() end
  if type(asker) ~= "string" or asker == "" then return done(nil, "invalid_asker") end
  local prepared, why = M.prepare(session, text)
  if not prepared then return done(nil, why) end
  request_counter = request_counter + 1
  local key = tostring(os.time()) .. ":" .. tostring(request_counter)
  local requested_id
  local request_data = { text = prepared.registered_text, registered_text = prepared.registered_text, posted_text = prepared.posted_text,
    session = session, bytes = prepared.bytes, owner = nil }
  local bounded_ttl = math.max(1, math.min(MAX_TTL, tonumber(ttl_s) or DEFAULT_TTL))
  local result = approval.request({ kind = "approve_text", key = key,
    asker = asker, summary = "type " .. tostring(prepared.bytes) .. " prepared bytes in " .. session,
    ttl_s = bounded_ttl, data = request_data, rate_limit_per_window = 10,
    rate_window_s = 600,
    on_id = function(id) requested_id = id end,
    render = function(rec)
      local data = rec.data
      local id = tostring(rec.id)
      data.request_id = id
      data.display_fingerprint = id .. "/" .. tostring(data.bytes)
      local shown = M.display(data.posted_text)
      return table.concat({ "Approve prepared text for " .. session,
        "Request " .. id .. " · " .. tostring(data.bytes) .. " bytes",
        "Fingerprint " .. data.display_fingerprint,
        "Asked by " .. tostring(asker), "Reply yes " .. id .. " to approve, or no " .. id .. " to deny.",
        shown }, "\n")
    end,
  }, done)
  return requested_id or result
end

function M.request(session, text, asker, done)
  return request(session, text, asker, nil, done)
end

function M.configure()
  approval.handler("approve_text", {
    approve = function(rec, complete)
      local data = type(rec.data) == "table" and rec.data or {}
      if not M.matches(data) or data.request_id ~= rec.id then
        complete("retry", "text_changed")
        return
      end
      local ok, why = M.type_text(data.session, data.registered_text, {
        owner = rec.answered_by, event_id = rec.answer_event_id, request_id = rec.id,
      })
      if ok then
        approval.reply(rec, "typed")
        complete(true)
      else
        approval.reply(rec, "refused: " .. tostring(why))
        complete("retry", why)
      end
    end,
    deny = function(rec) approval.reply(rec, "denied") end,
    expire = function(rec) approval.reply(rec, "expired") end,
  })
end

M.configure()
return M
