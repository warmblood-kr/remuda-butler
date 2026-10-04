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
  remuda butler matrix [--json] [--room ROOM] send TEXT | - | --file PATH
  remuda butler matrix [--json] [--room ROOM] reply EVENT_ID TEXT | - | --file PATH
  remuda butler matrix [--json] [--room ROOM] react EVENT_ID KEY
  remuda butler matrix [--json] [--room ROOM] upload [--thread EVENT_ID] [--caption TEXT] PATH
  remuda butler matrix [--json] [--room ROOM] redact EVENT_ID [--reason TEXT]
  remuda butler matrix [--json] join ROOM (ID, #alias, or public name; operator)
  remuda butler matrix [--json] leave ROOM (operator)
  remuda butler matrix setup [OPTIONS]
  remuda butler matrix [--json] quarantine [--id EVENT_ID] (operator)

Example: remuda butler matrix setup --homeserver https://<homeserver> --owner @<owner>:<server> --bot @<bot>:<server> --password-file <path>
Or end with --password-cmd PROG [ARG...] in place of --password-file to read the bot password from a program.]]

local VERBS = {
  status = true, rooms = true, history = true, event = true, get = true, quarantine = true,
  thread = true, follow = true, unfollow = true, download = true, send = true, reply = true, react = true,
  upload = true, redact = true, join = true, leave = true,
}

local THREAD_CLI_SPEC = {
  name = "remuda butler matrix",
  options = {
    { long = "room", value = "ROOM", help = "Room ID, alias or name (default: the configured room)", global = true },
    { long = "json", help = "Print machine-readable JSON", global = true },
  },
  verbs = {
    thread = {
      about = "Show every reply in a Matrix thread",
      args = { { name = "EVENT_ID", help = "Event that starts the thread, e.g. $abc123, or a Butler mail id (01M...)" } },
      next = "remuda butler matrix reply EVENT_ID TEXT",
    },
  },
}

local THREAD_HELP_TEXT = [[Show every reply in a Matrix thread

Usage: remuda butler matrix thread [OPTIONS] EVENT_ID

Arguments:
  EVENT_ID  Event that starts the thread, e.g. $abc123, or a Butler mail id (01M...)

Options:
      --room ROOM  Room ID, alias or name (default: the configured room)
      --json       Print machine-readable JSON
  -h, --help       Print help

Next: remuda butler matrix reply EVENT_ID TEXT]]

local function terminal_safe(value)
  return tostring(value or ""):gsub("[%c]", " "):gsub("\194[\128-\159]", " ")
end

local function matrix_verb(args)
  if type(args) ~= "table" then return nil end
  local at = 2
  while at <= #args do
    if args[at] == "--json" then
      at = at + 1
    elseif args[at] == "--room" or args[at] == "-n" or args[at] == "-o" or args[at] == "--id" then
      at = at + 2
    elseif args[at] == "--" then
      return nil
    elseif type(args[at]) == "string" and args[at]:sub(1, 1) == "-" then
      at = at + 1
    else
      return args[at]
    end
  end
end

local function matrix_cli_failure(text, code)
  text = tostring(text or "")
  local trailing_newline = text:sub(-1) == "\n"
  if trailing_newline then text = text:sub(1, -2) end
  local safe_lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    safe_lines[#safe_lines + 1] = terminal_safe(line)
  end
  text = table.concat(safe_lines, "\n")
  if trailing_newline then text = text .. "\n" end
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  if type(remuda.pending) == "function" then
    local reply = remuda.pending({ timeout = 1 })
    reply:resolve(code or 2, "", text)
    return reply
  end
  if type(remuda.fail) == "function" then return remuda.fail(text, code or 2) end
  error(text, 0)
end

local function verb_distance(left, right)
  local previous = {}
  for at = 0, #right do previous[at] = at end
  for row = 1, #left do
    local current = { [0] = row }
    for column = 1, #right do
      current[column] = math.min(current[column - 1] + 1, previous[column] + 1,
        previous[column - 1] + (left:sub(row, row) == right:sub(column, column) and 0 or 1))
    end
    previous = current
  end
  return previous[#right]
end

local function unknown_matrix_verb(args)
  local word = matrix_verb(args)
  if not word or word == "help" or VERBS[word] then return nil end
  local verbs = {}
  for verb in pairs(VERBS) do verbs[#verbs + 1] = verb end
  table.sort(verbs)
  local suggestion, distance
  for _, verb in ipairs(verbs) do
    local candidate = verb_distance(word, verb)
    if not distance or candidate < distance then suggestion, distance = verb, candidate end
  end
  local safe_word = terminal_safe(word)
  local lines = { "remuda: butler matrix: unknown verb '" .. safe_word .. "'." }
  if suggestion and distance <= math.max(1, math.floor(#word / 3)) then
    lines[1] = lines[1]:sub(1, -2) .. " Did you mean '" .. suggestion .. "'?"
    lines[#lines + 1] = "Usage: remuda butler matrix [--json] [--room ROOM] " .. suggestion .. " EVENT_ID"
    lines[#lines + 1] = "Example: remuda butler matrix " .. suggestion .. " '$EVENT_ID'"
    lines[#lines + 1] = "Next: remuda butler matrix " .. suggestion .. " '$EVENT_ID'"
  else
    lines[#lines + 1] = "Usage: remuda butler matrix <" .. table.concat(verbs, " | ") .. ">"
    lines[#lines + 1] = "Next: remuda butler matrix --help"
  end
  return matrix_cli_failure(table.concat(lines, "\n"), 2)
end

local function join_words(values, first)
  local words = {}
  for index = first, #values do words[#words + 1] = values[index] end
  return table.concat(words, " ")
end

local function parse(args)
  if type(args) ~= "table" or args[1] ~= "matrix" then return nil end
  local options, at, literal = {}, 2, false
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
    if args[at] == "--" then literal = true; at = at + 1; break end
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
      literal = true
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
    elseif verb == "upload" and not positional and (value == "--thread" or value == "--caption") then
      if not args[at + 1] then error(value .. " requires a value", 0) end
      options[value:sub(3)] = args[at + 1]
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
  -- TEXT starts at `first`. A bare `-` reads stdin (core forwards stdin by the same rule: a
  -- `-` argument before any `--`) and `--file PATH` reads a file; after `--` both are literal
  -- text, and any other leading `--word` is refused so a typo never posts.
  local function text_form(first)
    local head = values[first]
    options.text = join_words(values, first)
    if literal then return end
    if head == "-" then
      if #values ~= first then error("stdin message form takes no extra arguments", 0) end
      options.stdin = true
    elseif head == "--file" then
      if #values ~= first + 1 then error("expected one path after --file", 0) end
      options.file_body = values[first + 1]
    elseif head:sub(1, 2) == "--" then
      error("unknown option " .. head:gsub("%c", "?") .. " in the message text\n"
        .. "Next: remuda butler matrix " .. method .. (first == 2 and " EVENT_ID" or "")
        .. " --file PATH, or put -- before text that starts with dashes", 0)
    end
  end
  if method == "send" then
    if #values == 0 then return nil end
    text_form(1)
  elseif method == "reply" then
    if #values < 2 then return nil end
    options.event_id = values[1]
    text_form(2)
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
    if #values > 1 or options.room then return nil end
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

-- At most `limit` bytes; a cut text ends with "..." inside the limit, so the
-- reader can see that it is not complete.
local function shortened(text, limit)
  if #text <= limit then return text end
  return matrix.utf8_prefix(text, limit - 3) .. "..."
end
local function shortened_path(text, limit)
  if #text <= limit then return text end
  local room = limit - 3
  local prefix = matrix.utf8_prefix(text, math.floor(room / 3))
  local suffix_start = #text - (room - #prefix) + 1
  while suffix_start <= #text do
    local byte = text:byte(suffix_start)
    if not byte or byte < 0x80 or byte >= 0xC0 then break end
    suffix_start = suffix_start + 1
  end
  return prefix .. "..." .. text:sub(suffix_start)
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
    local lines = { "Event\tRoom\tReason\tSender" }
    for _, item in ipairs(data) do
      lines[#lines + 1] = table.concat({
        terminal_safe(item.event_id ~= "" and item.event_id or item.id),
        terminal_safe(item.room_id), terminal_safe(item.reason), (terminal_safe(item.sender)) }, "\t")
    end
    return #lines == 1 and "No quarantined Matrix events\n" or table.concat(lines, "\n") .. "\n"
  elseif verb == "download" then
    return string.format("Downloaded %d bytes to %s\n", result.bytes or 0, result.path or "")
  elseif verb == "send" or verb == "reply" then
    local ids = result.event_ids or {}
    local room = options.room or matrix.configured_room()
    return string.format("Sent %d message(s)%s%s\n", result.sent or #ids,
      type(room) == "string" and room ~= "" and (" to " .. terminal_safe(room)) or "",
      #ids > 0 and (": " .. table.concat(ids, ", ")) or "")
  elseif verb == "react" or verb == "redact" then
    return "Completed Matrix " .. verb .. (result.event_id and (": " .. result.event_id) or "") .. "\n"
  elseif verb == "upload" then
    return "Uploaded as " .. tostring(result.content_uri or "") .. " (" .. tostring(result.event_id or "") .. ")\n"
  elseif verb == "join" or verb == "leave" then
    if verb == "join" and result.approval_request_id then
      return "Asked the owner to approve joining " .. terminal_safe(result.approval_label or "the Matrix room")
        .. " (request " .. terminal_safe(result.approval_request_id)
        .. "). You get mail when they answer (expires in 10 min).\nNext: remuda butler inbox\n"
    end
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

-- True when this core's prompt_line takes `preface` (core 416). An older
-- daemon ignores the key silently and core has no capability or version word,
-- so there is nothing to detect directly.
-- ponytail: a proxy. remuda.fs.lock was merged to core main (da874da9) after
-- prompt_line preface (74fc5321), so every core with fs.lock has preface; a
-- core in the narrow window between the two shows the old behaviour, which is
-- safe. Replace it when core has a capability or version word.
function matrix.prompt_preface_supported()
  return type(remuda.fs) == "table" and type(remuda.fs.lock) == "function"
end

function matrix.wrap_prompt_preface(text)
  if type(text) ~= "string" then return "" end
  local lines = {}
  local function wrap_line(source)
    if #source <= 200 then lines[#lines + 1] = source; return end
    if source:match("^%s*$") then lines[#lines + 1] = ""; return end
    -- A wrapped line keeps its indent, on the continuation lines too.
    local indent = source:match("^%s*"):sub(1, 8)
    local room = 200 - #indent
    local line = ""
    local function flush()
      if line ~= "" then lines[#lines + 1] = indent .. line; line = "" end
    end
    for word in source:gmatch("%S+") do
      while #word > room do
        flush()
        local cut = room
        while cut > 0 do
          local byte = word:byte(cut + 1) or 0
          if byte < 0x80 or byte > 0xbf then break end
          cut = cut - 1
        end
        -- No boundary within reach (malformed bytes): split on the byte.
        if cut == 0 then cut = room end
        lines[#lines + 1] = indent .. word:sub(1, cut)
        word = word:sub(cut + 1)
      end
      if line == "" then
        line = word
      elseif #line + 1 + #word <= room then
        line = line .. " " .. word
      else
        flush()
        line = word
      end
    end
    flush()
  end
  local start = 1
  while true do
    local newline = text:find("\n", start, true)
    wrap_line(text:sub(start, newline and newline - 1 or #text))
    if not newline then break end
    start = newline + 1
  end
  if #lines > 32 then
    for index = #lines, 32, -1 do lines[index] = nil end
    lines[32] = "..."
  end
  return table.concat(lines, "\n")
end

function matrix.cli(args, agent, stdin_body, file_body)
  if type(args) == "table" and args[1] == "matrix" and args[2] == "setup" then
    -- Setup reads the files its flags name and sends them to the server named on the same
    -- command line, and rewrites the Butler's Matrix files: refused to agents, as join and leave.
    if agent then
      local message = "matrix setup is operator-only\nNext: run remuda butler matrix setup from your own terminal"
      if type(remuda.fail) == "function" then return remuda.fail(message, 1) end
      error(message, 0)
    end
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
    local function prompt_line(label, default, callback, preface)
      if type(reply.prompt_line) ~= "function" then
        return prompt_failure("The Matrix setup wizard needs a Remuda core with prompt_line; upgrade Remuda first.")
      end
      reply:prompt_line({ label = label, default = default, preface = preface, callback = function(line, prompt_error)
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
      prompt_line("Matrix homeserver URL", nil, function(homeserver)
        local normalized, scheme_or_error = matrix.setup_validate_homeserver(homeserver)
        if not normalized then return prompt_failure(tostring(scheme_or_error)) end
        local flags = { "--homeserver", normalized, "--owner" }
        prompt_line("Your Matrix user ID (for example @alice:example.org)", nil, function(owner)
          local valid_owner, owner_error = matrix.setup_validate_mxid(owner, "--owner")
          if not valid_owner then return prompt_failure(tostring(owner_error)) end
          flags[4] = valid_owner
          flags[5], flags[6], flags[7], flags[8] = "--register", "--default", "--rooms", "open"
          local function confirm_setup()
            local wizard_plan, validation_error = matrix.setup_prepare(flags)
            if not wizard_plan then
              local safe_error = terminal_safe(validation_error)
              local next_line = safe_error:find("output file already exists", 1, true)
                and "Next: back up or move the existing Matrix setup files, then rerun remuda butler matrix setup."
                or nil
              return prompt_failure(safe_error, next_line)
            end
            -- A dynamic value is cut at 150 characters so one long value cannot
            -- crowd the summary; the fixed wording is never cut.
            local function value(text) return shortened(terminal_safe(text), 150) end
            local function path(text) return shortened_path(terminal_safe(text), 150) end
            local lines = {
              "Matrix setup will:",
              "  Homeserver: " .. value(wizard_plan.homeserver),
              "  Owner: " .. value(wizard_plan.owner_mxid),
              "  Rooms: open (anyone can invite this Butler). Restrict: set rooms=allowlist or add deny_room/deny_server in "
                .. path(wizard_plan.config_path) .. ". The sender allowlist still decides whose messages are trusted.",
              "  Account: create a Butler bot (you will need its server registration token)",
              "  Bot: " .. value(wizard_plan.bot_mxid),
              -- Without --dir the files go next to the config file.
              "  Save private token and config files in: "
                .. path(wizard_plan.output_dir or wizard_plan.config_path:match("^(.*)/[^/]+$")),
              "  Start the relay for this Butler with this config (replaces its current Matrix relay config)",
            }
            if wizard_plan.pin then
              lines[#lines + 1] = "  HTTPS certificate pin: " .. wizard_plan.pin
            elseif wizard_plan.ca_file then
              lines[#lines + 1] = "  HTTPS CA file: " .. path(wizard_plan.ca_file)
            elseif scheme_or_error == "https" then
              lines[#lines + 1] = "  HTTPS trust: this system's trusted certificates"
            end
            -- Core shows a label on one line and cuts it at 256 characters, so
            -- the summary goes in the prompt's preface and the label is only
            -- the question (#186). An older core keeps the summary in the label.
            local question = "Continue? Type Y to continue, or N to cancel"
            local label, preface = table.concat(lines, "\n") .. "\n" .. question, nil
            if matrix.prompt_preface_supported() then
              label, preface = question, matrix.wrap_prompt_preface(table.concat(lines, "\n"))
            end
            prompt_line(label, "N", function(answer)
                answer = type(answer) == "string" and answer:lower() or ""
                if answer ~= "y" and answer ~= "yes" then
                  return prompt_failure("Matrix setup was not confirmed.")
                end
                execute_setup(wizard_plan)
              end, preface)
          end
          local function ask_transport_trust()
            if scheme_or_error == "https" then
              prompt_line("HTTPS trust: press Enter to use this system's trusted certificates, "
                .. "or enter a 64-character SHA-256 certificate pin or an absolute CA file path",
                nil, function(trust)
                  if type(trust) ~= "string" then
                    return prompt_failure("The HTTPS trust answer must be Enter (this system's trusted certificates), "
                      .. "a certificate pin or a CA file path.")
                  end
                  if trust == "" then
                    -- Enter: system trust roots, so neither --pin nor --ca-file.
                  elseif #trust == 64 and trust:match("^%x+$") then
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
          end
          if matrix.setup_default_bot(valid_owner) then return ask_transport_trust() end
          local server = valid_owner:match("^@[^:]+:(.+)$")
          prompt_line("Butler bot name (for example butler-mac; it becomes @butler-mac:" .. server .. ")",
            nil, function(bot)
              if type(bot) ~= "string" or bot == "" then
                return prompt_failure("A Butler bot name is required.")
              end
              if bot:sub(1, 1) ~= "@" then bot = "@" .. bot .. ":" .. server end
              local valid_bot, bot_error = matrix.setup_validate_mxid(bot, "--bot")
              if not valid_bot then return prompt_failure((terminal_safe(bot_error))) end
              flags[#flags + 1] = "--bot"
              flags[#flags + 1] = valid_bot
              ask_transport_trust()
            end)
        end)
      end)
    end
    execute_setup = function(plan)
      local prompt_attempts, prompt_notice = 0, nil
      -- prompt_secret has no preface and core cuts a label at 256 characters:
      -- a long homeserver is shortened so the notice and the question still fit.
      local prompt_label = "Registration token for " .. shortened(plan.homeserver, 100)
        .. ", from its admin (hidden). This is not an access token"
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
          if files.password_store then
            lines[#lines + 1] = "Bot account password saved in the OS secure store ("
              .. terminal_safe(files.password_store.backend) .. ") as " .. terminal_safe(files.password_store.name)
          elseif files.password_path then
            lines[#lines + 1] = "Bot account password saved privately: " .. terminal_safe(files.password_path)
            if files.store_fix then
              lines[#lines + 1] = "The OS secure store was not used: " .. shortened((terminal_safe(files.store_fix)), 240)
              lines[#lines + 1] = "Saved to the private file instead: " .. terminal_safe(files.password_path)
            elseif files.store_refused then
              lines[#lines + 1] = "The OS secure store was not used: " .. terminal_safe(files.store_refused)
            end
            if files.password_replaced then lines[#lines + 1] = "The old password file there was replaced." end
          elseif plan.secret_kind == "registration" then
            lines[#lines + 1] = "The password you supplied was not copied."
          end
          if files.old_password_path then
            lines[#lines + 1] = "An old password file was left in place: " .. terminal_safe(files.old_password_path)
              .. " (delete it if you no longer use it)"
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
            local message, next_line
            if prompt_error == "not_a_terminal" then
              message = "The registration token prompt cannot read a hidden answer."
            elseif prompt_error == "too_long" then
              message = "The registration token exceeds 4 KiB."
            elseif prompt_error == "cancelled" or prompt_error == "refused" then
              message = "The registration token prompt was cancelled."
              next_line = "Next: remuda butler matrix setup"
            else
              message = "The registration token prompt was refused."
            end
            return fail_registration_prompt(message, prompt_error == "not_a_terminal", next_line)
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
  local verb, options
  local cli = remuda.cli
  if type(cli) == "table" and type(cli.parse) == "function" and matrix_verb(args) == "thread" then
    local argv = {}
    for at = 2, #args do argv[#argv + 1] = args[at] end
    local report = cli.parse(THREAD_CLI_SPEC, argv)
    if not report.ok then
      if report.kind == "help" then return THREAD_HELP_TEXT end
      local text = report.text:gsub("\nNext: [^\n]*$", "\nNext: remuda butler matrix thread --help")
      return matrix_cli_failure(text, report.code)
    end
    verb = report.verb
    options = {
      event_id = report.values.EVENT_ID,
      room = report.values.room,
      json = report.values.json,
    }
  else
    local ok
    ok, verb, options = pcall(parse, args)
    if not ok then
      if type(remuda.fail) == "function" then return remuda.fail(tostring(verb), 2) end
      error(tostring(verb), 0)
    end
  end
  if not verb then
    if type(cli) == "table" and type(cli.parse) == "function" then
      local unknown = unknown_matrix_verb(args)
      if unknown then return unknown end
    end
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
  if (verb == "follow" or verb == "unfollow")
    and (type(options.event_id) ~= "string" or options.event_id:sub(1, 1) ~= "$"
      or terminal_safe(options.event_id) ~= options.event_id) then
    local usage = "  remuda butler matrix [--json] [--room ROOM] " .. verb .. " EVENT_ID"
      .. "\nExample: remuda butler matrix " .. verb .. " '$EVENT_ID'"
    if type(remuda.pending) == "function" then
      local reply = remuda.pending({ timeout = 1 })
      reply:resolve(2, "", usage .. "\n")
      return reply
    end
    if type(remuda.fail) == "function" then return remuda.fail(usage, 2) end
    return usage
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
  if options.stdin or options.file_body then
    local read, text = false, "no message body received on stdin"
    if options.file_body then
      read, text = false, "no file reader is available"
      if type(file_body) == "function" then read, text = pcall(file_body, options.file_body) end
    elseif type(stdin_body) == "function" then read, text = pcall(stdin_body) end
    if not read then
      if type(remuda.fail) == "function" then return remuda.fail(tostring(text), 1) end
      error(tostring(text), 0)
    end
    options.text = text
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
    if matrix.room_kind(room) == nil then
      return resolve_local(1, "", "room is outside the configured Matrix allowlist\n"
        .. "Next: remuda butler matrix rooms\n")
    end
    local ok, changed = pcall(function()
      if verb == "follow" then return relay:subscribe_thread(room, thread) end
      return relay:unsubscribe_thread(room, thread)
    end)
    if not ok then return resolve_local(1, "", tostring(changed) .. "\n") end
    if verb == "follow" and not changed then
      local next_room = options.room and ("--room " .. shell_quote(options.room) .. " ") or ""
      local message = "Follow limit reached (5000 in total). Next: remuda butler matrix "
        .. next_room .. "unfollow " .. shell_quote(terminal_safe(options.event_id))
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
    local next_room = options.room and ("--room " .. shell_quote(options.room) .. " ") or ""
    if followed then
      return resolve_local(0, "Following thread " .. safe_thread .. " in " .. safe_room
        .. ".\nNext: remuda butler matrix " .. next_room .. "thread " .. shell_quote(safe_thread) .. "\n", "")
    elseif changed then
      return resolve_local(0, "Stopped following thread " .. safe_thread .. " in " .. safe_room
        .. ".\nNext: remuda butler matrix " .. next_room .. "follow " .. shell_quote(safe_thread) .. "\n", "")
    end
    return resolve_local(0, "Not following thread " .. safe_thread .. " in " .. safe_room
      .. ".\nNext: remuda butler matrix " .. next_room .. "follow " .. shell_quote(safe_thread) .. "\n", "")
  end
  -- A reply, or an upload into a thread, answers one verified event.
  local answers = verb == "reply" and options.event_id or (verb == "upload" and options.thread)
  if answers then
    options.event_id = answers
    local relay, relay_error = matrix.reply_relay()
    if not relay then
      finish(reply, cancelled, completed, verb, options,
        { error = relay_error })
      return reply
    end
    if not relay:can_reply_to(options.event_id) then
      finish(reply, cancelled, completed, verb, options,
        { error = "Reply not sent: event " .. terminal_safe(options.event_id)
          .. " was not delivered to this Butler as mail, so its sender cannot be verified.\n"
          .. "Next: remuda butler inbox (you can only reply to events listed there)" })
      return reply
    end
    local route = relay:route_for_event(options.event_id)
    if route then
      options.room = options.room or route.room_id
      options.thread_root = route.thread_root
    else
      options.thread_root = relay:thread_root_for_event(options.event_id)
    end
  elseif verb == "thread" and #options.event_id == 26 and options.event_id:match("^[0-9A-HJKMNP-TV-Z]+$") then
    -- A Butler mail id names its Matrix room and thread root.
    local mail = remuda._butler_mail
    local room, root = nil, "the mail lookup is unavailable"
    if mail and mail.matrix_thread_target then room, root = mail.matrix_thread_target(agent, options.event_id, agent == nil) end
    if room and options.room and options.room ~= room then
      root = "mail " .. terminal_safe(options.event_id) .. " belongs to room " .. terminal_safe(room) .. ", not "
        .. terminal_safe(options.room) .. "\nNext: remuda butler matrix thread " .. terminal_safe(options.event_id)
      room = nil
    end
    if not room then
      finish(reply, cancelled, completed, verb, options, { error = root })
      return reply
    end
    options.room, options.event_id = room, root
  elseif verb == "thread" and not options.room then
    local relay = matrix.relay and matrix.relay.instance
    local route = relay and relay.route_for_event and relay:route_for_event(options.event_id)
    if route and type(route.room_id) == "string" and route.room_id ~= "" then
      options.room = route.room_id
    end
  end
  -- The CLI is where an agent caller arrives: it may upload only a file inside its own
  -- working directory. A missing check refuses, it never lets the path through.
  -- (A relative path is left to matrix.upload, which refuses it before any read.)
  if verb == "upload" and type(options.file) == "string"
      and (options.file:match("^[/\\]") or options.file:match("^%a:[/\\]")) then
    local check = remuda._butler_file_for_caller
    local allowed, refusal = nil, "refused: " .. options.file .. ": the caller check is unavailable"
    if type(check) == "function" then allowed, refusal = check(options.file, "", false) end
    if not allowed then
      finish(reply, cancelled, completed, verb, options, { error = refusal })
      return reply
    end
    options.file = allowed
  end
  -- The same for what download WRITES: -o PATH, or the default name, inside the
  -- agent caller's working directory only.
  if verb == "download" then
    local check = remuda._butler_output_for_caller
    local media = type(options.mxc) == "string" and options.mxc:match("^mxc://[^/]+/([^/%s]+)$")
    local allowed, refusal = nil, "refused: download: the caller check is unavailable"
    if type(check) == "function" then allowed, refusal = check(options.output, media and ("matrix-" .. media)) end
    if refusal then
      finish(reply, cancelled, completed, verb, options, { error = refusal })
      return reply
    end
    options.output = allowed
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
