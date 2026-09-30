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
  remuda butler matrix setup [OPTIONS]
  remuda butler matrix [--json] quarantine [--id EVENT_ID] (operator)

Example: remuda butler matrix setup --homeserver https://<homeserver> --owner @<owner>:<server> --bot @<bot>:<server> --password-file <path> --pin <sha256-hex>]]

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
  if verb == "send" and result.event_ids and #result.event_ids > 0
    and matrix.room_kind and matrix.room_kind(options.room or matrix.configured_room()) == "all" then
    local relay = matrix.relay and matrix.relay.instance
    if relay and relay.subscribe_thread then
      relay:subscribe_thread(options.room or matrix.configured_room(), result.event_ids[1])
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
  if type(args) == "table" and args[1] == "matrix" and args[2] == "setup" then
    local setup_args = {}
    for index = 3, #args do setup_args[#setup_args + 1] = args[index] end
    local plan, setup_error = matrix.setup_prepare(setup_args)
    if not plan then
      if type(remuda.fail) == "function" then return remuda.fail(setup_error, 2) end
      error(setup_error, 0)
    end
    if plan.help then return plan.usage end
    if type(remuda.pending) ~= "function" then
      local message = "Matrix setup requires a remuda core with deferred replies"
      if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
      error(message, 0)
    end
    local cancelled, completed, active = { value = false }, { value = false }, nil
    local reply = remuda.pending({ timeout = plan.prompt_registration_token and 300 or 90, on_cancel = function()
      cancelled.value = true
      if active and active.cancel then active:cancel() end
    end })
    local prompt_attempts, prompt_notice = 0, nil
    local prompt_label = "Registration token for " .. plan.homeserver
      .. ", from its admin (hidden). This is not an access token:"
    local rejected_registration_token = matrix.REJECTED_REGISTRATION_TOKEN
    local original_bot_mxid = plan.bot_mxid
    local ask_registration_token
    local function fail_registration_prompt(message, needs_terminal, next_line)
      if cancelled.value or completed.value then return end
      completed.value = true
      local lines = {}
      if message and message ~= "" then lines[#lines + 1] = message end
      if needs_terminal then lines[#lines + 1] = "The hidden registration token prompt needs a terminal." end
      lines[#lines + 1] = "Nothing was written."
      lines[#lines + 1] = next_line
        or "Next: rerun with --registration-token-file PATH"
      reply:resolve(1, "", table.concat(lines, "\n") .. "\n")
    end
    local function finish_setup(result)
      if cancelled.value or completed.value then return end
      if plan.prompt_registration_token and type(result) == "table"
        and result.error == rejected_registration_token then
        if prompt_attempts < 3 then
          prompt_notice = rejected_registration_token
          return ask_registration_token()
        end
        return fail_registration_prompt(rejected_registration_token)
      end
      completed.value = true
      if type(result) ~= "table" then result = { error = "Matrix setup returned no result" } end
      if result.error then return reply:resolve(1, "", tostring(result.error) .. "\n") end
      local files, write_error = matrix.setup_write(plan, result)
      if not files then return reply:resolve(1, "", tostring(write_error) .. "\n") end
      local relay_started, relay_error
      if plan.default then
        -- Match main.lua's boot config shape using the resolved paths that
        -- setup just wrote; the relay remains the only live component changed.
        remuda._butler_matrix_config = {
          token_path = files.token_path,
          config_path = files.config_path,
        }
        local relay = matrix.relay
        if relay and type(relay.stop) == "function" and type(relay.start) == "function" then
          pcall(relay.stop)
          local ok, started = pcall(relay.start, remuda._butler_matrix_config)
          relay_started = ok and started == true
          if not relay_started then
            relay_error = ok and (started == false and "relay.start returned false"
              or started == nil and "relay.start returned no result"
              or "relay.start did not return true") or terminal_safe(started)
          end
        else
          relay_error = "Matrix relay start is unavailable"
        end
      end
      active = matrix.status({}, function(status_result)
        if cancelled.value then return end
        if type(status_result) ~= "table" then status_result = { error = "Matrix status returned no result" } end
        local lines = { plan.secret_kind == "registration"
          and ("Created bot account " .. terminal_safe(result.user_id))
          or ("Matrix login verified as " .. terminal_safe(result.user_id)) }
        if result.home_room then lines[#lines + 1] = "HOME room: " .. terminal_safe(result.home_room) end
        if result.all_room then lines[#lines + 1] = "ALL-BUTLERS room: " .. terminal_safe(result.all_room) end
        lines[#lines + 1] = "Token file: " .. terminal_safe(files.token_path)
        if files.password_path then
          lines[#lines + 1] = "Bot account password saved privately: " .. terminal_safe(files.password_path)
        end
        lines[#lines + 1] = "Config file: " .. terminal_safe(files.config_path)
        if status_result.error then
          lines[#lines + 1] = "Status check failed: " .. terminal_safe(status_result.error)
        else
          lines[#lines + 1] = "Status: " .. terminal_safe(render_human("status", {}, status_result):gsub("\n", "; "):gsub("; $", ""))
        end
        if plan.default then
          if relay_started then
            lines[#lines + 1] = "Next: accept the invite in Element; the relay is running, so write to the Butler there."
          else
            lines[#lines + 1] = "Next: Accept the invite in Element, then write in the room."
            lines[#lines + 1] = "Relay failed to start: " .. terminal_safe(relay_error or "unknown relay start error")
            lines[#lines + 1] = "Next: fix the config, then rerun remuda butler matrix setup ... --default --force"
          end
        else
          local function shell_quote(value)
            return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
          end
          lines[#lines + 1] = "Accept the invite in Element before starting this separate Butler."
          lines[#lines + 1] = "Next: REMUDA_BUTLER_TOKEN=" .. shell_quote(files.token_path)
            .. " REMUDA_BUTLER_CONFIG=" .. shell_quote(files.config_path)
            .. " remuda -s matrix-test daemon"
        end
        reply:resolve(0, table.concat(lines, "\n") .. "\n", "")
      end, agent)
    end
    ask_registration_token = function()
      if cancelled.value or completed.value then return end
      if type(reply.prompt_secret) ~= "function" then
        return fail_registration_prompt(nil, false,
          "Next: rerun with --registration-token-file PATH (this remuda core has no hidden prompt; upgrade with remuda upgrade)")
      end
      prompt_attempts = prompt_attempts + 1
      local label = prompt_notice and (prompt_notice .. " " .. prompt_label) or prompt_label
      reply:prompt_secret({ label = label, callback = function(secret, prompt_error)
        if cancelled.value or completed.value then return end
        if prompt_error then
          local message
          if prompt_error == "not_a_terminal" then
            message = "The registration token prompt cannot read a hidden answer."
          elseif prompt_error == "too_long" then
            message = "The registration token exceeds 4 KiB."
          elseif prompt_error == "cancelled" then
            message = "The registration token prompt was cancelled."
          else
            message = "The registration token prompt was refused."
          end
          return fail_registration_prompt(message, prompt_error == "not_a_terminal")
        end
        local token, token_error = matrix.normalize_secret(secret)
        if not token then
          if token_error == "empty" then
            if prompt_attempts < 3 then
              prompt_notice = "The registration token was empty."
              return ask_registration_token()
            end
            return fail_registration_prompt("The registration token was empty.")
          end
          return fail_registration_prompt("The registration token could not be validated.")
        end
        plan.secret = token
        prompt_notice = nil
        plan.bot_mxid = original_bot_mxid
        active = matrix.setup_network(plan, finish_setup)
        if cancelled.value and active and active.cancel then active:cancel() end
      end })
    end
    if plan.prompt_registration_token then
      ask_registration_token()
    else
      active = matrix.setup_network(plan, finish_setup)
    end
    if cancelled.value and active and active.cancel then active:cancel() end
    return reply
  end
  local ok, verb, options = pcall(parse, args)
  if not ok then
    if type(remuda.fail) == "function" then return remuda.fail(tostring(verb), 2) end
    error(tostring(verb), 0)
  end
  if not verb then return USAGE end
  if verb ~= "join" and verb ~= "leave" and type(matrix.configuration_guidance) == "function" then
    local guidance = matrix.configuration_guidance()
    if guidance then
      if type(remuda.fail) == "function" then return remuda.fail(guidance, 1) end
      error(guidance, 0)
    end
  end
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
  if verb == "reply" then
    local relay = matrix.relay and matrix.relay.instance
    if not relay or type(relay.can_reply_to) ~= "function" then
      finish(reply, cancelled, completed, verb, options,
        { error = "Matrix relay is not running; event sender cannot be verified" })
      return reply
    end
    if not relay:can_reply_to(options.event_id) then
      finish(reply, cancelled, completed, verb, options,
        { error = "Butler-to-Butler replies are disabled" })
      return reply
    end
    local route = relay.route_for_event and relay:route_for_event(options.event_id)
    if route then
      options.room = options.room or route.room_id
      options.thread_root = route.thread_root
    elseif relay.thread_root_for_event then
      options.thread_root = relay:thread_root_for_event(options.event_id)
    end
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
