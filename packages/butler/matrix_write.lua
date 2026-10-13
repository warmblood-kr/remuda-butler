-- L2 Matrix write composites over remuda.butler.matrix.request.
local matrix = assert(remuda.butler and remuda.butler.matrix, "Matrix request word is unavailable")
local approval = assert(remuda.butler.approval, "load butler/approval before butler/matrix_write")

local MAX_CHUNK_BYTES = 4000
local MAX_HTML_BYTES = 30000 -- an event is capped at 65536 bytes; markup can expand a chunk ~9x
local MAX_UPLOAD_BYTES = 20 * 1024 * 1024
local txn_counter = 0
local function random_tag()
  local bytes
  if type(remuda.random_bytes) == "function" then
    local ok, random_bytes = pcall(remuda.random_bytes, 16)
    if ok and type(random_bytes) == "string" and #random_bytes >= 16 then
      bytes = random_bytes:sub(1, 16)
    end
  end
  if not bytes then
    local opened, file = pcall(io.open, "/dev/urandom", "rb")
    if opened and file then
      local read_ok, value = pcall(file.read, file, 16)
      if read_ok and type(value) == "string" and #value >= 16 then bytes = value:sub(1, 16) end
      pcall(file.close, file)
    end
  end
  if not bytes then error("secure random source unavailable for Matrix transaction IDs", 0) end
  local hex = {}
  for i = 1, #bytes do hex[i] = string.format("%02x", bytes:byte(i)) end
  return table.concat(hex)
end
local process_tag = random_tag()
local once = matrix.once
local path_component = matrix.path_component

local function error_result(callback, message)
  callback({ error = message })
  return { cancel = function() end }
end

local function terminal_safe(value)
  return tostring(value or ""):gsub("[%c]", " "):gsub("\194[\128-\159]", " ")
end

local function configured_room(opts, callback)
  local room = opts and opts.room
  if not room or room == "" then room = matrix.configured_room() end
  if not room then
    callback({ error = "Matrix is not configured with an allowlisted room" })
    return nil
  end
  return room
end

local function next_txn()
  txn_counter = txn_counter + 1
  return "t" .. tostring(os.time()) .. "_" .. process_tag .. "_" .. tostring(txn_counter)
end

local function split_utf8(text)
  local chunks, chunk, bytes = {}, {}, 0
  local at = 1
  while at <= #text do
    local first = text:byte(at)
    local width = first < 0x80 and 1 or (first < 0xe0 and 2 or (first < 0xf0 and 3 or 4))
    if at + width - 1 > #text then width = 1 end
    if bytes > 0 and bytes + width > MAX_CHUNK_BYTES then
      chunks[#chunks + 1] = table.concat(chunk)
      chunk, bytes = {}, 0
    end
    chunk[#chunk + 1] = text:sub(at, at + width - 1)
    bytes = bytes + width
    at = at + width
  end
  if #chunk > 0 then chunks[#chunks + 1] = table.concat(chunk) end
  return chunks
end

local function send_chunks(room, text, relation, on_done, txn_prefix, plain)
  local done = once(on_done)
  if type(text) ~= "string" or text == "" then
    return error_result(done, "message text must not be empty")
  end
  -- CLI parsing may reserve '-' for stdin; this async word sends it literally.
  local chunks, event_ids, index, current, cancelled = split_utf8(text), {}, 1, nil, false
  local handle = { cancel = function()
    cancelled = true
    if current then current:cancel() end
  end }
  local function step()
    if cancelled then return done({ error = "Matrix send cancelled" }) end
    if index > #chunks then
      return done({ sent = #event_ids, event_ids = event_ids })
    end
    local content = { msgtype = "m.text", body = chunks[index] }
    -- Converter is looked up at call time so it stays advisable (#166); on any
    -- failure the chunk goes out plain.
    if not plain then
      local ok, html = pcall(function() return remuda.butler.md2html.convert(chunks[index]) end)
      if ok and type(html) == "string" and html ~= "" and #html <= MAX_HTML_BYTES then
        content.format, content.formatted_body = "org.matrix.custom.html", html
      end
    end
    if relation then content["m.relates_to"] = relation end
    local body, encode_error = matrix.encode_json(content)
    if not body then return done({ error = encode_error }) end
    local txn = txn_prefix and (txn_prefix .. "_" .. tostring(index)) or next_txn()
    current = matrix.request_json({ method = "PUT",
      path = "/_matrix/client/v3/rooms/" .. path_component(room)
        .. "/send/m.room.message/" .. path_component(txn),
      room = room, body = body, headers = { ["Content-Type"] = "application/json" },
    }, function(result)
      if result.error then return done(result) end
      local event_id = result.json and result.json.event_id or ""
      event_ids[#event_ids + 1] = event_id
      local relay = matrix.relay and matrix.relay.instance
      if relay and type(relay.record_own_event) == "function" then
        local thread_root = relation and relation.rel_type == "m.thread" and relation.event_id or event_id
        pcall(relay.record_own_event, relay, room, event_id, thread_root)
      end
      index = index + 1
      step()
    end)
  end
  step()
  return handle
end

function matrix.send(opts, on_done)
  opts = opts or {}
  local done = once(on_done)
  local room = configured_room(opts, done)
  if not room then return { cancel = function() end } end
  if type(opts.text) ~= "string" or opts.text == "" then
    return error_result(done, "message text must not be empty")
  end
  local slot, slot_error = matrix.take_post_slot()
  if not slot then return error_result(done, slot_error) end
  return send_chunks(room, opts.text, nil, done, nil, opts.plain == true)
end

local function same_room_then(room, event_id, on_done, action)
  local done = once(on_done)
  if type(event_id) ~= "string" or event_id == "" then
    return error_result(done, "event_id is required")
  end
  local current
  current = matrix.same_room(room, event_id, function(result)
    if type(result) == "table" and result.error then return done(result) end
    if result ~= true then return done({ error = "event is outside the configured Matrix room" }) end
    current = action(done)
  end)
  return { cancel = function() if current then current:cancel() end end }
end

function matrix.reply_relay()
  local relay = matrix.relay and matrix.relay.instance
  local required_relay_methods = {
    "can_reply_to", "route_for_event", "thread_root_for_event", "b2b_stopped",
    "b2b_turn_limit", "note_own_turn", "post_cap_hit",
  }
  if type(relay) == "table" then
    for _, method in ipairs(required_relay_methods) do
      if type(relay[method]) ~= "function" then relay = nil; break end
    end
  else
    relay = nil
  end
  if relay then return relay end
  return nil, "Matrix relay is not running or is from an older load; event sender cannot be verified"
end

-- The reply-to refusal shared by reply and upload --thread: an event that never arrived as
-- mail has no verified sender.
local function unverified_event_error(relay, event_id)
  if relay:can_reply_to(event_id) then return nil end
  return "Reply not sent: event " .. terminal_safe(event_id)
    .. " was not delivered to this Butler as mail, so its sender cannot be verified.\n"
    .. "Next: remuda butler inbox (you can only reply to events listed there)"
end

-- The m.thread relation of a post that answers opts.event_id inside opts.thread_root.
local function thread_relation(opts)
  local root = type(opts.thread_root) == "string" and opts.thread_root ~= ""
    and opts.thread_root or opts.event_id
  return { rel_type = "m.thread", event_id = root, ["m.in_reply_to"] = { event_id = opts.event_id } }
end

function matrix.reply(opts, on_done)
  opts = opts or {}
  local done = once(on_done)
  local relay, relay_error = matrix.reply_relay()
  if not relay then return error_result(done, relay_error) end
  local room = configured_room(opts, done)
  if not room then return { cancel = function() end } end
  if type(opts.text) ~= "string" or opts.text == "" then
    return error_result(done, "message text must not be empty")
  end
  local unverified = unverified_event_error(relay, opts.event_id)
  if unverified then return error_result(done, unverified) end
  local route = relay:route_for_event(opts.event_id)
  local allowlisted_human_reply = route ~= nil and route.allowlisted_human == true
  local root = relay:thread_root_for_event(opts.event_id)
  local safe_room = terminal_safe(room)
  local shown_root = matrix.shown_event_id(root or opts.event_id)
  local root_is_shown = shown_root ~= "(id not shown)"
  local function stopped_error()
    local next_step = "Next: remuda butler matrix --room " .. matrix.shell_quote(safe_room)
      .. (root_is_shown and (" thread " .. matrix.shell_quote(shown_root)) or " history")
    return "Reply not sent: stopped replying in thread " .. shown_root .. " (" .. safe_room .. "): "
      .. tostring(relay:b2b_turn_limit())
      .. " Butler-only turns. A reply in that thread from a person on the allowlist resumes it.\n"
      .. next_step
  end
  if not opts.from_outbox and relay:b2b_stopped(room, root) then
    return error_result(done, stopped_error())
  end
  return same_room_then(room, opts.event_id, done, function(reply_done)
    if not opts.from_outbox then
      if not allowlisted_human_reply then
        local slot, slot_error = matrix.take_post_slot()
        if not slot then return error_result(reply_done, slot_error) end
      end
      relay:note_own_turn(room, root)
    end
    return send_chunks(room, opts.text, thread_relation(opts), reply_done, opts.txn_id)
  end)
end

function matrix.react(opts, on_done)
  opts = opts or {}
  local done = once(on_done)
  local room = configured_room(opts, done)
  if not room then return { cancel = function() end } end
  if type(opts.key) ~= "string" or opts.key == "" then
    return error_result(done, "reaction key must not be empty")
  end
  return same_room_then(room, opts.event_id, done, function(action_done)
    local body, encode_error = matrix.encode_json({ ["m.relates_to"] = {
      rel_type = "m.annotation", event_id = opts.event_id, key = opts.key,
    } })
    if not body then return action_done({ error = encode_error }) end
    return matrix.request_json({ method = "PUT",
      path = "/_matrix/client/v3/rooms/" .. path_component(room)
        .. "/send/m.reaction/" .. next_txn(),
      room = room, body = body, headers = { ["Content-Type"] = "application/json" },
    }, function(result)
      if result.error then return action_done(result) end
      action_done({ event_id = result.json and result.json.event_id or "" })
    end)
  end)
end

function matrix.redact(opts, on_done)
  opts = opts or {}
  local done = once(on_done)
  local room = configured_room(opts, done)
  if not room then return { cancel = function() end } end
  if type(opts.event_id) ~= "string" or opts.event_id == "" then
    return error_result(done, "event_id is required")
  end
  local content = {}
  if opts.reason ~= nil then content.reason = opts.reason end
  local body, encode_error = matrix.encode_json(content)
  if not body then return error_result(done, encode_error) end
  return matrix.request_json({ method = "PUT",
    path = "/_matrix/client/v3/rooms/" .. path_component(room) .. "/redact/"
      .. path_component(opts.event_id) .. "/" .. next_txn(),
    room = room, body = body, headers = { ["Content-Type"] = "application/json" },
  }, function(result)
    if result.error then return done(result) end
    done({ event_id = result.json and result.json.event_id or "" })
  end)
end

local function absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

local function media_type(name)
  local extension = name:match("%.([^%.]+)$")
  extension = extension and extension:lower()
  local types = { png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
    gif = "image/gif", webp = "image/webp", bmp = "image/bmp" }
  return types[extension] or "application/octet-stream"
end

-- A file is read, uploaded, then sent as an m.image or m.file event, in a thread when
-- `relation` is set.
local function read_upload(opts)
  if type(opts.file) ~= "string" or opts.file == "" or not absolute(opts.file) then
    return nil, "use an absolute path (the daemon does not know your cwd)"
  end
  local file, open_error = io.open(opts.file, "rb")
  if not file then return nil, "cannot read upload file: " .. tostring(open_error) end
  local ok, data, read_error = pcall(function() return file:read(MAX_UPLOAD_BYTES + 1) end)
  file:close()
  if not ok then return nil, "upload path is not a readable regular file" end
  if read_error then return nil, "upload path is not a readable regular file: " .. tostring(read_error) end
  if not data or #data == 0 then return nil, "upload file must not be empty" end
  if #data > MAX_UPLOAD_BYTES then return nil, "upload exceeds 20 MiB limit" end
  return data
end

-- `data` is the file already read: a threaded upload reads before it waits on the homeserver,
-- so the bytes are those of the path the caller was checked against.
local function upload_file(opts, done, room, relation, data)
  if not data then
    local read_error
    data, read_error = read_upload(opts)
    if not data then return error_result(done, read_error) end
  end
  local filename = opts.file:match("([^/\\]+)$") or opts.file
  local mime = media_type(filename)
  local content_uri
  local current, cancelled = nil, false
  local handle = { cancel = function()
    cancelled = true
    if current then current:cancel() end
  end }
  local query = "filename=" .. path_component(filename)
  current = matrix.request({ method = "POST", path = "/_matrix/media/v3/upload?" .. query,
    room = room, body = data, headers = { ["Content-Type"] = mime }, max_bytes = 1024 * 1024,
    timeout = 60,
  }, function(upload_result)
    if cancelled then return done({ error = "Matrix upload cancelled" }) end
    if upload_result.error then return done(upload_result) end
    local uploaded, decode_error = matrix.decode_json(upload_result.body or "")
    if not uploaded or not uploaded.content_uri then
      return done({ error = "Matrix media upload response omitted content_uri"
        .. (decode_error and (": " .. decode_error) or "") })
    end
    content_uri = uploaded.content_uri
    local msgtype = mime:sub(1, 6) == "image/" and "m.image" or "m.file"
    -- With a caption, `body` is the caption and `filename` the file name (Matrix 1.10).
    local caption = type(opts.caption) == "string" and opts.caption ~= "" and opts.caption or nil
    local content = { msgtype = msgtype, body = caption or filename, url = content_uri,
      info = { mimetype = mime, size = #data } }
    if caption then content.filename = filename end
    if relation then content["m.relates_to"] = relation end
    local body, encode_error = matrix.encode_json(content)
    if not body then return done({ error = encode_error }) end
    current = matrix.request_json({ method = "PUT",
      path = "/_matrix/client/v3/rooms/" .. path_component(room)
        .. "/send/m.room.message/" .. next_txn(),
      room = room, body = body, headers = { ["Content-Type"] = "application/json" },
    }, function(result)
      if result.error then return done(result) end
      local event_id = result.json and result.json.event_id or ""
      local relay = matrix.relay and matrix.relay.instance
      if event_id ~= "" and relay and type(relay.record_own_event) == "function" then
        pcall(relay.record_own_event, relay, room, event_id, relation and relation.event_id or event_id)
      end
      done({ event_id = event_id, content_uri = content_uri })
    end)
  end)
  return handle
end

-- With opts.event_id the file is posted into that event's thread, after the checks reply
-- makes: the event reached this Butler as mail (or is its own), in the configured room.
function matrix.upload(opts, on_done)
  opts = opts or {}
  local done = once(on_done)
  local room = configured_room(opts, done)
  if not room then return { cancel = function() end } end
  if opts.event_id == nil then return upload_file(opts, done, room, nil) end
  local relay, relay_error = matrix.reply_relay()
  if not relay then return error_result(done, relay_error) end
  local unverified = unverified_event_error(relay, opts.event_id)
  if unverified then return error_result(done, unverified) end
  local data, read_error = read_upload(opts)
  if not data then return error_result(done, read_error) end
  return same_room_then(room, opts.event_id, done, function(thread_done)
    return upload_file(opts, thread_done, room, thread_relation(opts), data)
  end)
end

local function operator_room(verb, opts, agent, callback)
  if agent then
    if verb ~= "join" then
      callback({ error = "matrix " .. verb .. " is operator-only"
        .. "\nNext: ask the owner to run remuda butler matrix " .. verb .. " ROOM from their terminal" })
      return nil
    end
  end
  if not opts.room or opts.room == "" then
    local example = verb == "join" and "remuda butler matrix join #alias:server"
      or ("remuda butler matrix " .. verb .. " '!room:server'")
    callback({ error = "matrix " .. verb .. " requires ROOM.\nNext: " .. example })
    return nil
  end
  return opts.room
end

local sanitize_directory_text = matrix.sanitize_directory_text

local function room_id_valid(room)
  return type(matrix.valid_room_id) == "function" and matrix.valid_room_id(room)
    or type(room) == "string" and room:match("^!%S+:%S+$") ~= nil
end

local function room_alias_valid(alias)
  return type(matrix.valid_room_alias) == "function" and matrix.valid_room_alias(alias)
    and sanitize_directory_text(alias) == alias
end

local function public_room_record(item)
  if type(item) ~= "table" or not room_id_valid(item.room_id)
    or sanitize_directory_text(item.room_id) ~= item.room_id then return nil end
  local alias = room_alias_valid(item.canonical_alias) and item.canonical_alias or nil
  local name = sanitize_directory_text(item.name)
  local localpart = alias and alias:match("^#([^:]+):") or nil
  local members = tonumber(item.num_joined_members)
  if not members or members < 0 or members ~= math.floor(members) then members = 0 end
  return { room_id = item.room_id, display_room_id = sanitize_directory_text(item.room_id), name = name,
    alias = alias and sanitize_directory_text(alias) or nil, alias_localpart = localpart,
    members = members, topic = sanitize_directory_text(item.topic) }
end

local function homeserver_name(base)
  local authority = type(base) == "string" and base:match("^https?://([^/%?#]+)") or "the homeserver"
  return sanitize_directory_text(authority or "the homeserver")
end

local function resolve_alias(alias, base, callback)
  if not room_alias_valid(alias) then
    callback({ error = "invalid Matrix room alias: expected #localpart:server (no whitespace or slash; max 255 bytes)" })
    return { cancel = function() end }
  end
  return matrix.request_json({ method = "GET",
    path = "/_matrix/client/v3/directory/room/" .. path_component(alias),
  }, function(result)
    if result.error then
      if result.status == 404 or tostring(result.error):find("M_NOT_FOUND", 1, true) then
        local server = sanitize_directory_text(alias:match("^#[^:]+:(.+)$") or homeserver_name(base))
        return callback({ error = "No room " .. alias .. " on " .. server
          .. ".\nNext: check the spelling, or ask the room admin for an invite." })
      end
      return callback(result)
    end
    local room = result.json and result.json.room_id
    if not room_id_valid(room) or sanitize_directory_text(room) ~= room then
      return callback({ error = "invalid Matrix room ID in room directory response" })
    end
    callback({ room_id = room, alias = alias })
  end)
end

local function find_public_matches(name, base, callback)
  local body, encode_error = matrix.encode_json({ filter = { generic_search_term = name }, limit = 20 })
  if not body then callback({ error = encode_error }); return { cancel = function() end } end
  return matrix.request_json({ method = "POST", path = "/_matrix/client/v3/publicRooms",
    body = body, headers = { ["Content-Type"] = "application/json" },
  }, function(result)
    if result.error then return callback(result) end
    local rows, by_id = {}, {}
    for _, item in ipairs(type(result.json) == "table" and result.json.chunk or {}) do
      local record = public_room_record(item)
      if record and (record.name == name or record.alias_localpart == name) and not by_id[record.room_id] then
        by_id[record.room_id] = true
        rows[#rows + 1] = record
      end
    end
    table.sort(rows, function(a, b)
      if a.name == b.name then return a.room_id < b.room_id end
      return a.name < b.name
    end)
    if #rows == 0 then
      return callback({ error = "No public room named " .. sanitize_directory_text(name)
        .. " on " .. homeserver_name(base)
        .. ".\nNext: remuda butler matrix rooms --public " .. matrix.shell_quote(sanitize_directory_text(name))
        .. ", or ask for an invite." })
    end
    local has_next_page = type(result.json) == "table"
      and type(result.json.next_batch) == "string" and result.json.next_batch ~= ""
    if #rows > 1 or has_next_page then return callback({ matches = rows, ambiguous = true }) end
    callback({ room_id = rows[1].room_id, alias = rows[1].alias, name = rows[1].name,
      public = true, members = rows[1].members })
  end)
end

local function utf8_length(text)
  local count, at = 0, 1
  while at <= #text do
    local byte = text:byte(at)
    at = at + (byte < 0x80 and 1 or (byte < 0xe0 and 2 or (byte < 0xf0 and 3 or 4)))
    count = count + 1
  end
  return count
end

local function approval_summary(room, alias, display_name, is_public, members)
  local clean = sanitize_directory_text
  local room_id = clean(room)
  local target = clean(alias or display_name or room)
  local prefix = "join " .. target
  if display_name then
    local name = clean(display_name)
    local detail = ' ("' .. name .. '"'
    if is_public then detail = detail .. ", public, " .. tostring(tonumber(members) or 0) .. " members" end
    prefix = prefix .. detail .. ")"
  end
  if not alias and not display_name then return clean(prefix, 128) end
  local suffix = " (" .. room_id .. ")"
  local room_chars = utf8_length(suffix)
  local head = clean(prefix, math.max(1, 128 - room_chars))
  return head .. clean(suffix, math.max(1, 128 - utf8_length(head)))
end

local function file_request(room, alias, display_name, is_public, members, asker, callback)
  local summary = approval_summary(room, alias, display_name, is_public, members)
  local label = sanitize_directory_text(alias or display_name or room)
  return approval.request({ kind = "join", key = room, summary = summary, asker = tostring(asker),
    ttl_s = approval.default_ttl_s(), data = { room_id = room, alias = alias, name = display_name } }, function(id, why)
      if not id then return callback({ error = why or "Could not file approval request" }) end
      callback({ approval_request_id = id, room_id = room, room_alias = alias,
        room_name = display_name, approval_label = label })
    end)
end

local function approval_label(rec)
  local data = type(rec.data) == "table" and rec.data or {}
  return sanitize_directory_text(data.alias or data.name or data.room_id or "the Matrix room")
end

local function approval_mail(rec, text)
  if type(remuda._butler_send) == "function" then
    pcall(remuda._butler_send, "butler", rec.asker, text)
  end
end

local function approval_thread(rec, text)
  pcall(approval.reply, rec, text)
end

local function approval_join_failed(rec, err, done)
  err = tostring(err or "unknown Matrix error")
  local data = type(rec.data) == "table" and rec.data or {}
  local room = sanitize_directory_text(data.room_id or "unknown room")
  approval_mail(rec, "Approved, but the join failed: " .. err
    .. " (request " .. tostring(rec.id) .. ", " .. room
    .. "). Next: ask the owner to invite the bot, then run the join again.")
  approval_thread(rec, "Approved by " .. tostring(rec.answered_by or "the owner") .. "; join failed: " .. err)
  done(false, err)
end

local function join_as(config_path, conf, room, how, alias, display_name, callback)
  local added = false
  if conf.rooms[room] ~= "home" and conf.rooms[room] ~= "all" then
    local ok, wrote_or_error = matrix.config_add_room(config_path, room, how, alias)
    if not ok then return error_result(callback, wrote_or_error) end
    added = wrote_or_error == true
  end
  return matrix.request_json({ method = "POST",
    path = "/_matrix/client/v3/rooms/" .. path_component(room) .. "/join",
    room = room, body = "{}", headers = { ["Content-Type"] = "application/json" },
  }, function(result)
    if type(result) ~= "table" or result.error then
      local failure = type(result) == "table" and result.error or "Matrix join returned no result"
      if added then
        local removed, remove_error = matrix.config_remove_room(config_path, room)
        if not removed then
          failure = tostring(failure) .. "; config rollback failed: " .. tostring(remove_error)
        end
      end
      if failure:find("(M_FORBIDDEN)", 1, true) then
        local next_line = "Next: invite the bot (" .. conf.self_mxid .. ") to " .. room
          .. " from Element, then retry."
        local replaced
        failure, replaced = failure:gsub("Next:[^\r\n]*", function() return next_line end)
        if replaced == 0 then failure = failure .. "\n" .. next_line end
      end
      return callback({ error = failure })
    end
    result.room_id = room
    result.room_alias = alias and sanitize_directory_text(alias) or nil
    result.room_name = display_name and sanitize_directory_text(display_name) or nil
    callback(result)
  end)
end

local function join_approved(rec, done)
  local data = type(rec.data) == "table" and rec.data or {}
  local room, alias = data.room_id, data.alias
  if not room_id_valid(room) then return approval_join_failed(rec, "invalid stored room ID", done) end
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  local config_path = paths.config_path
  if type(config_path) ~= "string" or config_path == "" then
    return approval_join_failed(rec, "Matrix config path is unavailable", done)
  end
  local conf, config_error = matrix.read_config(config_path)
  if not conf then return approval_join_failed(rec, config_error, done) end
  return join_as(config_path, conf, room, "approved", alias, data.name, function(result)
    if result.error then return approval_join_failed(rec, result.error, done) end
    local label = approval_label(rec)
    approval_mail(rec, "Approved; joined " .. label .. " (request "
      .. tostring(rec.id) .. ", " .. room .. ").")
    approval_thread(rec, "Approved by " .. tostring(rec.answered_by or "the owner") .. "; joined.")
    done(true)
  end)
end

approval.handler("join", {
  approve = join_approved,
  deny = function(rec)
    local data = type(rec.data) == "table" and rec.data or {}
    local room = sanitize_directory_text(data.room_id or "unknown room")
    approval_mail(rec, "Denied by the owner (request " .. tostring(rec.id) .. ", " .. room
      .. "). Next: ask the owner in the request room why, or pick another room.")
    approval_thread(rec, "Denied by " .. tostring(rec.answered_by or "the owner") .. ".")
  end,
  expire = function(rec)
    local data = type(rec.data) == "table" and rec.data or {}
    local room = sanitize_directory_text(data.room_id or "unknown room")
    approval_mail(rec, "No answer in 10 minutes; not joined (request " .. tostring(rec.id)
      .. ", " .. room .. "). Next: run the join again to re-ask.")
    approval_thread(rec, "Expired.")
  end,
})

function matrix.join(opts, on_done, agent)
  opts = opts or {}
  local done = once(on_done)
  local requested = operator_room("join", opts, agent, done)
  if not requested then return { cancel = function() end } end
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  local config_path = paths.config_path
  if type(config_path) ~= "string" or config_path == "" then
    return error_result(done, "Matrix config path is unavailable")
  end
  local conf, config_error = matrix.read_config(config_path)
  if not conf then return error_result(done, config_error) end
  local current
  local function join_room(room, alias, display_name, is_public, members)
    if not room_id_valid(room) then
      return error_result(done, "invalid Matrix room ID: room IDs start with ! (Element: Room settings > Advanced tab (not General) > Internal room ID. Element X may not show it; use the #alias instead.).")
    end
    if agent then
      current = file_request(room, alias, display_name, is_public, members, agent, done)
      return current
    end
    current = join_as(config_path, conf, room, "operator", alias, display_name, done)
    return current
  end
  if requested:sub(1, 1) == "#" then
    current = resolve_alias(requested, conf.base, function(resolved)
      if resolved.error then return done(resolved) end
      join_room(resolved.room_id, resolved.alias)
    end)
  elseif requested:sub(1, 1) == "!" then
    join_room(requested)
  else
    if requested == "" or requested:find("[%c]") then
      return error_result(done, "public room name must not be empty or contain control characters")
    end
    current = find_public_matches(requested, conf.base, function(found)
      if found.error or found.ambiguous then return done(found) end
      join_room(found.room_id, found.alias, found.name, found.public, found.members)
    end)
  end
  return { cancel = function() if current and current.cancel then current:cancel() end end }
end

-- Operator-only: mark a joined room as ALL-BUTLERS in the config. Takes effect on a reload.
function matrix.mark_all(opts, on_done, agent)
  opts = opts or {}
  local done = once(on_done)
  local room = operator_room("mark-all", opts, agent, done)
  if not room then return { cancel = function() end } end
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  if type(paths.config_path) ~= "string" or paths.config_path == "" then
    error_result(done, "Matrix config path is unavailable")
    return { cancel = function() end }
  end
  local ok, mark_error = matrix.config_mark_all(paths.config_path, room)
  if not ok then error_result(done, mark_error) else done({ room_id = room }) end
  return { cancel = function() end }
end

function matrix.leave(opts, on_done, agent)
  opts = opts or {}
  local done = once(on_done)
  local requested = operator_room("leave", opts, agent, done)
  if not requested then return { cancel = function() end } end
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  local config_path = paths.config_path
  if type(config_path) ~= "string" or config_path == "" then
    return error_result(done, "Matrix config path is unavailable")
  end
  local conf, config_error = matrix.read_config(config_path)
  if not conf then return error_result(done, config_error) end
  local current
  local function leave_room(room)
    if conf.rooms[room] == "home" or conf.rooms[room] == "all" then
      return error_result(done,
        "HOME and ALL rooms can't be left.\nNext: remuda butler matrix setup (to change HOME or ALL).")
    end
    if conf.rooms[room] == nil then
      return error_result(done, room .. " is not a configured Matrix room.")
    end
    current = matrix.request_json({ method = "POST",
      path = "/_matrix/client/v3/rooms/" .. path_component(room) .. "/leave",
      room = room, body = "{}", headers = { ["Content-Type"] = "application/json" },
    }, function(result)
      local removed, remove_error = matrix.config_remove_room(config_path, room)
      if not removed then
        local detail = result.error and (tostring(result.error) .. "; ") or ""
        result.error = detail .. "could not remove Matrix room config line: " .. tostring(remove_error)
      elseif result.error then
        local base = tostring(result.error):gsub("\n?Next:[^\r\n]*", "")
        result.error = base .. "; the room was removed from the local config.\nNext: remuda butler matrix rooms"
      end
      if not result.error then
        result.room_id = room
        result.room_alias = requested:sub(1, 1) == "#" and sanitize_directory_text(requested) or nil
      end
      done(result)
    end)
  end
  if requested:sub(1, 1) == "#" then
    local labeled = {}
    for room, alias in pairs(conf.room_aliases or {}) do
      if alias == requested and conf.rooms[room] then labeled[#labeled + 1] = room end
    end
    table.sort(labeled)
    if #labeled > 1 then
      return error_result(done, "more than one configured Matrix room uses " .. sanitize_directory_text(requested)
        .. ".\nNext: run remuda butler matrix rooms and choose a room ID.")
    elseif #labeled == 1 then
      leave_room(labeled[1])
    else
      current = resolve_alias(requested, conf.base, function(resolved)
        if resolved.error then return done(resolved) end
        leave_room(resolved.room_id)
      end)
    end
  else
    leave_room(requested)
  end
  return { cancel = function() if current and current.cancel then current:cancel() end end }
end

return matrix
