-- One command router for the public Matrix CLI vocabulary.
local matrix = assert(remuda.butler and remuda.butler.matrix, "Matrix request word is unavailable")

local USAGE = [[  remuda butler matrix [--json] status
  remuda butler matrix [--json] rooms
  remuda butler matrix [--json] [--room ROOM] [-n N] history
  remuda butler matrix [--json] [--room ROOM] thread EVENT_ID
  remuda butler matrix [--json] [--room ROOM] event|get EVENT_ID
  remuda butler matrix [--json] [-o PATH] download MXC
  remuda butler matrix [--json] [--room ROOM] send TEXT
  remuda butler matrix [--json] [--room ROOM] reply EVENT_ID TEXT
  remuda butler matrix [--json] [--room ROOM] react EVENT_ID KEY
  remuda butler matrix [--json] [--room ROOM] upload PATH
  remuda butler matrix [--json] [--room ROOM] redact EVENT_ID [--reason TEXT]
  remuda butler matrix [--json] join ROOM (operator)
  remuda butler matrix [--json] leave ROOM (operator)
  remuda butler matrix [--json] quarantine [--id EVENT_ID] (operator)]]

local VERBS = {
  status = true, rooms = true, history = true, event = true, get = true, quarantine = true,
  thread = true, download = true, send = true, reply = true, react = true,
  upload = true, redact = true, join = true, leave = true,
}

local function join_words(values, first)
  local words = {}
  for index = first, #values do words[#words + 1] = values[index] end
  return table.concat(words, " ")
end

local function parse(args)
  if type(args) ~= "table" or args[1] ~= "matrix" then return nil end
  local options, at = {}, 2
  local function option(value)
    if value == "--json" then options.json = true; return 1 end
    if value == "--room" then
      if not args[at + 1] then error("--room requires a room ID", 0) end
      options.room = args[at + 1]; return 2
    end
    if value == "--id" then
      if not args[at + 1] then error("--id requires a Matrix event ID", 0) end
      options.id = args[at + 1]; return 2
    end
    return nil
  end
  while at <= #args do
    if args[at] == "--" then at = at + 1; break end
    local width = option(args[at])
    if not width and args[at] == "-n" then
      if not args[at + 1] then error("-n requires a count", 0) end
      options.n = args[at + 1]; width = 2
    elseif not width and args[at] == "-o" then
      if not args[at + 1] then error("-o requires an absolute path", 0) end
      options.output = args[at + 1]; width = 2
    end
    if not width then break end
    at = at + width
  end
  local verb = args[at]
  if not VERBS[verb] then return nil end
  at = at + 1
  local values, positional = {}, false
  while at <= #args do
    local value = args[at]
    if not positional and value == "--" then
      positional = true
      at = at + 1
    elseif not positional and (value == "--json" or value == "--room" or value == "--id") then
      local width = option(value)
      at = at + width
    elseif not positional and verb == "history" and value == "-n" then
      if not args[at + 1] then error("-n requires a count", 0) end
      options.n = args[at + 1]
      at = at + 2
    elseif not positional and verb == "download" and value == "-o" then
      if not args[at + 1] then error("-o requires an absolute path", 0) end
      options.output = args[at + 1]
      at = at + 2
    elseif verb == "redact" and value == "--reason" then
      if not args[at + 1] then error("--reason requires text", 0) end
      options.reason = args[at + 1]
      at = at + 2
    else
      positional = true
      values[#values + 1] = value
      at = at + 1
    end
  end

  local method = verb == "get" and "event" or verb
  local room_verbs = { history = true, thread = true, event = true, send = true,
    reply = true, react = true, upload = true, redact = true }
  if options.room and not room_verbs[method] then return nil end
  if options.n and method ~= "history" then return nil end
  if options.output and method ~= "download" then return nil end
  if options.reason and method ~= "redact" then return nil end
  if options.id and method ~= "quarantine" then return nil end
  if method == "send" then
    options.text = join_words(values, 1)
    if #values == 0 then return nil end
  elseif method == "reply" then
    if #values < 2 then return nil end
    options.event_id, options.text = values[1], join_words(values, 2)
  elseif method == "react" then
    if #values ~= 2 then return nil end
    options.event_id, options.key = values[1], values[2]
  elseif method == "upload" then
    if #values ~= 1 then return nil end
    options.file = values[1]
  elseif method == "redact" then
    if #values ~= 1 then return nil end
    options.event_id = values[1]
  elseif method == "join" or method == "leave" then
    if #values ~= 1 or options.room then return nil end
    options.room = values[1]
  elseif method == "history" then
    if #values ~= 0 then return nil end
  elseif method == "thread" or method == "event" then
    if #values ~= 1 then return nil end
    options.event_id = values[1]
  elseif method == "download" then
    if #values ~= 1 then return nil end
    options.mxc = values[1]
  elseif method == "quarantine" or method == "status" or method == "rooms" then
    if #values ~= 0 then return nil end
  end
  return method, options
end

local function event_line(event)
  if type(event) ~= "table" then return tostring(event) end
  local sender = event.sender or "unknown sender"
  local content = event.content or {}
  local body = content.body or content.filename
  if type(body) == "string" then return sender .. ": " .. body end
  return sender .. ": " .. (matrix.encode_json(event) or "<event>")
end

local function terminal_safe(value)
  return tostring(value or ""):gsub("[%c]", " "):gsub("\194[\128-\159]", " ")
end

local function render_human(verb, options, result)
  local data = result.json or result
  if verb == "rooms" then
    local rooms = data.joined_rooms or {}
    if #rooms == 0 then return "No joined Matrix rooms\n" end
    return table.concat(rooms, "\n") .. "\n"
  elseif verb == "status" then
    local rooms = data.joined_rooms or {}
    return table.concat({ "User: " .. tostring(data.user_id or "unknown"),
      "Joined rooms: " .. tostring(#rooms) }, "\n") .. "\n"
  elseif verb == "history" or verb == "thread" then
    local events = data.chunk or {}
    local lines = {}
    for _, event in ipairs(events) do lines[#lines + 1] = event_line(event) end
    if #lines == 0 then return "No Matrix events\n" end
    return table.concat(lines, "\n") .. "\n"
  elseif verb == "event" then
    return event_line(data) .. "\n"
  elseif verb == "quarantine" then
    if data.id then
      return table.concat({ "Event: " .. terminal_safe(data.event_id or data.id),
        "Reason: " .. terminal_safe(data.reason), "Sender: " .. terminal_safe(data.sender),
        "Room: " .. terminal_safe(data.room_id), "Time: " .. terminal_safe(data.created_at),
        "Preview: " .. terminal_safe(data.preview) }, "\n") .. "\n"
    end
    local lines = {}
    for _, item in ipairs(data) do
      lines[#lines + 1] = table.concat({
        terminal_safe(item.event_id ~= "" and item.event_id or item.id),
        terminal_safe(item.reason), terminal_safe(item.sender) }, "\t")
    end
    return #lines == 0 and "No quarantined Matrix events\n" or table.concat(lines, "\n") .. "\n"
  elseif verb == "download" then
    return string.format("Downloaded %d bytes to %s\n", result.bytes or 0, result.path or "")
  elseif verb == "send" or verb == "reply" then
    local ids = result.event_ids or {}
    return string.format("Sent %d message(s)%s\n", result.sent or #ids,
      #ids > 0 and (": " .. table.concat(ids, ", ")) or "")
  elseif verb == "react" or verb == "redact" then
    return "Completed Matrix " .. verb .. (result.event_id and (": " .. result.event_id) or "") .. "\n"
  elseif verb == "upload" then
    return "Uploaded as " .. tostring(result.content_uri or "") .. " (" .. tostring(result.event_id or "") .. ")\n"
  elseif verb == "join" or verb == "leave" then
    return (verb == "join" and "Joined " or "Left ") .. tostring(options.room or "the Matrix room") .. "\n"
  end
  return (matrix.encode_json(result) or "{}") .. "\n"
end

local function finish(reply, cancelled, completed, verb, options, result)
  if cancelled.value or completed.value then return end
  completed.value = true
  if type(result) ~= "table" then result = { error = "Matrix command returned no result" } end
  if result.error then
    return reply:resolve(1, "", tostring(result.error) .. "\n")
  end
  if verb == "reply" and result.event_ids and #result.event_ids > 0 then
    local relay = matrix.relay and matrix.relay.instance
    if relay and relay.record_outgoing_reply then
      relay:record_outgoing_reply(options.event_id, result.event_ids[#result.event_ids])
    end
  end
  local stdout, encode_error
  if options.json then stdout, encode_error = matrix.encode_json(result)
  else stdout = render_human(verb, options, result) end
  if not stdout then return reply:resolve(1, "", tostring(encode_error) .. "\n") end
  return reply:resolve(0, stdout .. (options.json and "\n" or ""), "")
end

function matrix.cli_usage()
  return USAGE
end

function matrix.cli(args, agent)
  local ok, verb, options = pcall(parse, args)
  if not ok then
    if type(remuda.fail) == "function" then return remuda.fail(tostring(verb), 2) end
    error(tostring(verb), 0)
  end
  if not verb then return USAGE end
  if type(remuda.pending) ~= "function" then
    local message = "Matrix CLI requires a remuda core with deferred replies (core #213/#239)"
    if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
    error(message, 0)
  end
  if verb == "send" and options.text == "-" then
    local message = "send - stdin is unavailable until core #213"
    if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
    error(message, 0)
  end

  local active, cancelled, completed = nil, { value = false }, { value = false }
  local reply = remuda.pending({ timeout = 90, on_cancel = function()
    cancelled.value = true
    if active and active.cancel then active:cancel() end
  end })
  local callback = function(result) finish(reply, cancelled, completed, verb, options, result) end
  if verb == "reply" and matrix.relay and matrix.relay.instance then
    local relay = matrix.relay.instance
    if relay.can_reply_to and not relay:can_reply_to(options.event_id) then
      finish(reply, cancelled, completed, verb, options,
        { error = "Butler-to-Butler replies are disabled" })
      return reply
    end
    if relay.thread_root_for_event then options.thread_root = relay:thread_root_for_event(options.event_id) end
  end
  local called, handle = pcall(matrix[verb], options, callback, agent)
  if not called then
    finish(reply, cancelled, completed, verb, options, { error = tostring(handle) })
  else
    active = handle
    if cancelled.value and active and active.cancel then active:cancel() end
  end
  return reply
end

return matrix
