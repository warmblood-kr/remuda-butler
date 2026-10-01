-- One command router for the public Matrix CLI vocabulary.
local matrix = assert(remuda.butler and remuda.butler.matrix, "Matrix request word is unavailable")

local USAGE = [[  remuda butler matrix [--json] status
  remuda butler matrix [--json] rooms
  remuda butler matrix [--json] rooms --public [TERM]
  remuda butler matrix [--json] [--room ROOM] [-n N] history
  remuda butler matrix [--json] [--room ROOM] thread EVENT_ID
  remuda butler matrix [--json] [--room ROOM] follow EVENT_ID
  remuda butler matrix [--json] [--room ROOM] unfollow EVENT_ID
  remuda butler matrix [--json] [--room ROOM] event|get EVENT_ID
  remuda butler matrix [--json] [-o PATH] download MXC
  remuda butler matrix [--json] [--room ROOM] send TEXT
  remuda butler matrix [--json] [--room ROOM] reply EVENT_ID TEXT
  remuda butler matrix [--json] [--room ROOM] react EVENT_ID KEY
  remuda butler matrix [--json] [--room ROOM] upload PATH
  remuda butler matrix [--json] [--room ROOM] redact EVENT_ID [--reason TEXT]
  remuda butler matrix [--json] join ROOM (ID, #alias, or public name; operator)
  remuda butler matrix [--json] leave ROOM (operator)
  remuda butler matrix setup [OPTIONS]
  remuda butler matrix [--json] quarantine [--id EVENT_ID] (operator)

Example: remuda butler matrix setup --homeserver https://<homeserver> --owner @<owner>:<server> --bot @<bot>:<server> --password-file <path> --pin <sha256-hex>]]

local VERBS = {
  status = true, rooms = true, history = true, event = true, get = true, quarantine = true,
  thread = true, follow = true, unfollow = true, download = true, send = true, reply = true, react = true,
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
    elseif not positional and verb == "rooms" and value == "--public" then
      options.public = true
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
    follow = true, unfollow = true, reply = true, react = true, upload = true, redact = true }
  if options.room and not room_verbs[method] then return nil end
  if options.n and method ~= "history" then return nil end
  if options.output and method ~= "download" then return nil end
  if options.reason and method ~= "redact" then return nil end
  if options.id and method ~= "quarantine" then return nil end
  if options.public and method ~= "rooms" then return nil end
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
  elseif method == "thread" or method == "event" or method == "follow" or method == "unfollow" then
    if #values ~= 1 then return nil end
    options.event_id = values[1]
  elseif method == "download" then
    if #values ~= 1 then return nil end
    options.mxc = values[1]
  elseif method == "rooms" then
    if options.public then
      if #values > 1 then return nil end
      options.public_term = values[1]
    elseif #values ~= 0 then
      return nil
    end
  elseif method == "quarantine" or method == "status" then
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
local function shell_quote(value)
  return matrix.shell_quote(tostring(value))
end

local function render_human(verb, options, result)
  local data = result.json or result
  if verb == "rooms" then
    if options.public or result.public or data.public then
      local rows, lines = data.public_rooms or {}, {}
      for _, item in ipairs(rows) do
        lines[#lines + 1] = terminal_safe(item.name) .. "  "
          .. terminal_safe(item.alias or "(no alias)") .. "  "
          .. tostring(item.members or 0) .. " members  " .. terminal_safe(item.room_id)
      end
      if #lines == 0 then lines[#lines + 1] = "No public Matrix rooms found" end
      lines[#lines + 1] = options.public_term
        and ("Next: remuda butler matrix join " .. shell_quote(terminal_safe(options.public_term)))
        or "Next: remuda butler matrix join ROOM"
      return table.concat(lines, "\n") .. "\n"
    end
    local rooms, lines, leave_room, safe_rooms, safe_kinds, safe_hows, room_width, kind_width =
      data.rooms or {}, { "Rooms mode: " .. terminal_safe(data.mode or "allowlist") },
      false, {}, {}, {}, 0, 0
    for _, item in ipairs(rooms) do
      local room = terminal_safe(item.room)
      if item.alias then room = room .. " (" .. terminal_safe(item.alias) .. ")" end
      local kind = terminal_safe(item.kind)
      local how = terminal_safe(item.how or "config")
      if item.inviter then how = how .. "; inviter " .. terminal_safe(item.inviter) end
      safe_rooms[#safe_rooms + 1] = room
      safe_kinds[#safe_kinds + 1] = kind
      safe_hows[#safe_hows + 1] = how
      room_width = math.max(room_width, #room)
      kind_width = math.max(kind_width, #kind)
      if item.kind == "joined" then leave_room = true end
    end
    for index, item in ipairs(rooms) do
      lines[#lines + 1] = safe_rooms[index] .. string.rep(" ", room_width - #safe_rooms[index] + 2)
        .. safe_kinds[index] .. string.rep(" ", kind_width - #safe_kinds[index] + 2) .. safe_hows[index]
    end
    for _, deny_line in ipairs(data.deny_lines or {}) do
      lines[#lines + 1] = "Deny: " .. terminal_safe(deny_line)
    end
    if #rooms == 0 then lines[#lines + 1] = "No configured Matrix rooms" end
    if leave_room then
      lines[#lines + 1] = "Next: remuda butler matrix leave ROOM"
    else
      local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
      local conf = type(paths.config_path) == "string" and matrix.read_config(paths.config_path) or nil
      local allowed = {}
      for mxid in pairs(conf and conf.allowed_senders or {}) do
        allowed[#allowed + 1] = terminal_safe(mxid)
      end
      table.sort(allowed)
      local allowlist = #allowed > 0 and table.concat(allowed, ", ") or "none"
      lines[#lines + 1] = "Next: invite " .. terminal_safe(conf and conf.self_mxid or "the Butler")
        .. " to a room from an allowlisted account (" .. allowlist .. ")."
    end
    return table.concat(lines, "\n") .. "\n"
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
    if verb == "join" and (result.ambiguous or data.ambiguous)
      and type(result.matches or data.matches) == "table" then
      local matches = result.matches or data.matches
      local lines = {}
      for _, item in ipairs(matches) do
        lines[#lines + 1] = terminal_safe(item.name) .. "  "
          .. terminal_safe(item.alias or "(no alias)") .. "  "
          .. tostring(item.members or 0) .. " members  " .. terminal_safe(item.display_room_id or item.room_id)
      end
      lines[#lines + 1] = "Next: remuda butler matrix join #alias:server"
      return table.concat(lines, "\n") .. "\n"
    end
    local id = result.room_id or data.room_id
    local room_name, room_alias = result.room_name or data.room_name, result.room_alias or data.room_alias
    local label = verb == "join" and (room_name or room_alias) or room_alias
    label = label or options.room or "the Matrix room"
    label = terminal_safe(label)
    local suffix = id and id ~= label and (" (" .. terminal_safe(id) .. ")") or ""
    local next_line = verb == "join"
      and "Next: write to the Butler in that room, or remuda butler matrix rooms"
      or "Next: remuda butler matrix rooms"
    return (verb == "join" and "Joined " or "Left ") .. label .. suffix .. "\n" .. next_line .. "\n"
  end
  return (matrix.encode_json(result) or "{}") .. "\n"
end

local function finish(reply, cancelled, completed, verb, options, result)
  if cancelled.value or completed.value then return end
  completed.value = true
  if type(result) ~= "table" then result = { error = "Matrix command returned no result" } end
  if result.error then
    local message = tostring(result.error)
    if not message:find("Next:", 1, true) then
      if verb == "join" or verb == "leave" then message = message .. "\nNext: remuda butler matrix rooms" end
      if verb == "rooms" then message = message .. "\nNext: remuda butler matrix setup" end
    end
    return reply:resolve(1, "", message .. "\n")
  end
  if verb == "reply" and result.event_ids and #result.event_ids > 0 then
    local relay = matrix.relay and matrix.relay.instance
    if relay and relay.record_outgoing_reply then
      relay:record_outgoing_reply(options.event_id, result.event_ids[#result.event_ids])
    end
  end
  if verb == "send" and result.event_ids and #result.event_ids > 0 then
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
    local reply = remuda.pending({ timeout = (plan.wizard or plan.prompt_registration_token) and 300 or 90, on_cancel = function()
      cancelled.value = true
      if active and active.cancel then active:cancel() end
    end })
    local function prompt_failure(message, next_line)
      if cancelled.value or completed.value then return end
      completed.value = true
      reply:resolve(1, "", message .. "\nNothing was written.\n"
        .. (next_line or "Next: rerun remuda butler matrix setup.") .. "\n")
    end
    local function prompt_line(label, default, callback)
      if type(reply.prompt_line) ~= "function" then
        return prompt_failure("The Matrix setup wizard needs a Remuda core with prompt_line; upgrade Remuda first.")
      end
      reply:prompt_line({ label = label, default = default, callback = function(line, prompt_error)
        if cancelled.value or completed.value then return end
        if prompt_error then
          local message
          if prompt_error == "not_a_terminal" then
            message = "The Matrix setup wizard needs a terminal."
          elseif prompt_error == "too_long" then
            message = "That answer is too long."
          elseif prompt_error == "cancelled" then
            message = "The Matrix setup wizard was cancelled."
          else
            message = "The Matrix setup prompt was refused."
          end
          return prompt_failure(message)
        end
        callback(line)
      end })
    end
    local execute_setup
    local function begin_wizard()
      prompt_line("Matrix homeserver URL:", nil, function(homeserver)
        local normalized, scheme_or_error = matrix.setup_validate_homeserver(homeserver)
        if not normalized then return prompt_failure(tostring(scheme_or_error)) end
        local flags = { "--homeserver", normalized, "--owner" }
        prompt_line("Your Matrix user ID (for example @alice:example.org):", nil, function(owner)
          local valid_owner, owner_error = matrix.setup_validate_mxid(owner, "--owner")
          if not valid_owner then return prompt_failure(tostring(owner_error)) end
          flags[4] = valid_owner
          flags[5], flags[6] = "--register", "--default"
          local function confirm_setup()
            local wizard_plan, validation_error = matrix.setup_prepare(flags)
            if not wizard_plan then
              local safe_error = terminal_safe(validation_error)
              local next_line = safe_error:find("output file already exists", 1, true)
                and "Next: back up or move the existing Matrix setup files, then rerun remuda butler matrix setup."
                or nil
              return prompt_failure(safe_error, next_line)
            end
            local lines = {
              "Matrix setup will:",
              "  Homeserver: " .. terminal_safe(wizard_plan.homeserver),
              "  Owner: " .. terminal_safe(wizard_plan.owner_mxid),
              "  Account: create a Butler bot (you will need its server registration token)",
              "  Bot: " .. terminal_safe(wizard_plan.bot_mxid),
              "  Save private token and config files in: " .. terminal_safe(wizard_plan.output_dir),
              "  Start the relay for this Butler with this config (replaces its current Matrix relay config)",
            }
            if wizard_plan.pin then
              lines[#lines + 1] = "  HTTPS certificate pin: " .. wizard_plan.pin
            elseif wizard_plan.ca_file then
              lines[#lines + 1] = "  HTTPS CA file: " .. terminal_safe(wizard_plan.ca_file)
            end
            prompt_line(table.concat(lines, "\n") .. "\nContinue? Type Y to continue, or N to cancel [N]:",
              "N", function(answer)
                answer = type(answer) == "string" and answer:lower() or ""
                if answer ~= "y" and answer ~= "yes" then
                  return prompt_failure("Matrix setup was not confirmed.")
                end
                execute_setup(wizard_plan)
              end)
          end
          if scheme_or_error == "https" then
            prompt_line("HTTPS trust: enter a 64-character SHA-256 certificate pin or an absolute CA file path:",
              nil, function(trust)
                if type(trust) ~= "string" then
                  return prompt_failure("The HTTPS trust answer must be a certificate pin or CA file path.")
                end
                if #trust == 64 and trust:match("^%x+$") then
                  flags[#flags + 1] = "--pin"
                  flags[#flags + 1] = trust
                else
                  flags[#flags + 1] = "--ca-file"
                  flags[#flags + 1] = trust
                end
                confirm_setup()
              end)
          else
            confirm_setup()
          end
        end)
      end)
    end
    execute_setup = function(plan)
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
    end
    if plan.wizard then begin_wizard() else execute_setup(plan) end
    return reply
  end
  local ok, verb, options = pcall(parse, args)
  if not ok then
    if type(remuda.fail) == "function" then return remuda.fail(tostring(verb), 2) end
    error(tostring(verb), 0)
  end
  if not verb then
    local candidate
    for _, value in ipairs(args or {}) do
      if value == "follow" or value == "unfollow" then candidate = value end
    end
    if candidate then
      local usage = "  remuda butler matrix [--json] [--room ROOM] " .. candidate .. " EVENT_ID"
      usage = usage .. "\nExample: remuda butler matrix " .. candidate .. " '$EVENT_ID'"
      if type(remuda.pending) == "function" then
        local reply = remuda.pending({ timeout = 1 })
        reply:resolve(2, "", usage .. "\n")
        return reply
      end
      if type(remuda.fail) == "function" then return remuda.fail(usage, 2) end
      return usage
    end
    return USAGE
  end
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
  if verb == "follow" or verb == "unfollow" then
    local function resolve_local(code, stdout, stderr)
      reply:resolve(code, stdout or "", stderr or "")
      return reply
    end
    local relay = matrix.relay and matrix.relay.instance
    if not relay or type(relay.subscribe_thread) ~= "function"
      or type(relay.unsubscribe_thread) ~= "function" or type(relay.route_for_event) ~= "function" then
      local message = 'Matrix relay is not running. Next: remuda butler doctor'
      return resolve_local(1, "", message .. "\n")
    end
    local route = relay:route_for_event(options.event_id)
    local thread = route and route.thread_root or options.event_id
    local room = options.room or (route and route.room_id) or matrix.configured_room()
    if type(room) ~= "string" or room == "" then
      local message = "No Matrix room is configured. Next: remuda butler matrix setup"
      return resolve_local(1, "", message .. "\n")
    end
    local ok, changed = pcall(function()
      if verb == "follow" then return relay:subscribe_thread(room, thread) end
      return relay:unsubscribe_thread(room, thread)
    end)
    if not ok then return resolve_local(1, "", tostring(changed) .. "\n") end
    if verb == "follow" and not changed then
      local message = "Follow limit reached in " .. terminal_safe(room) .. " (50000). Next: remuda butler matrix unfollow "
        .. "EVENT_ID"
      if options.json then
        local encoded, encode_error = matrix.encode_json({ followed = false, room = room, thread = thread })
        if not encoded then return resolve_local(1, "", tostring(encode_error) .. "\n") end
        return resolve_local(1, encoded .. "\n", "")
      end
      return resolve_local(1, "", message .. "\n")
    end
    local followed = verb == "follow"
    local result = followed and { followed = true, room = room, thread = thread }
      or { unfollowed = changed == true, room = room, thread = thread }
    if options.json then
      local encoded, encode_error = matrix.encode_json(result)
      if not encoded then return resolve_local(1, "", tostring(encode_error) .. "\n") end
      return resolve_local(0, encoded .. "\n", "")
    end
    local safe_thread, safe_room = terminal_safe(thread), terminal_safe(room)
    if followed then
      return resolve_local(0, "Following thread " .. safe_thread .. " in " .. safe_room
        .. ".\nNext: remuda butler matrix thread " .. safe_thread .. "\n", "")
    elseif changed then
      return resolve_local(0, "Stopped following thread " .. safe_thread .. " in " .. safe_room
        .. ".\nNext: remuda butler matrix follow " .. safe_thread .. "\n", "")
    end
    return resolve_local(0, "Not following thread " .. safe_thread .. " in " .. safe_room
      .. ".\nNext: remuda butler matrix follow " .. safe_thread .. "\n", "")
  end
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
