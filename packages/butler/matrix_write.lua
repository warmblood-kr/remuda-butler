-- L2 Matrix write composites over remuda.butler.matrix.request.
local matrix = assert(remuda.butler and remuda.butler.matrix, "Matrix request word is unavailable")
-- Trust words are bound at load (main.lua execs matrix_request before
-- this file), so a later redefinition of the public entry cannot change them.
local is_agent_mxid = matrix.is_agent_mxid

local MAX_CHUNK_BYTES = 4000
local MAX_UPLOAD_BYTES = 20 * 1024 * 1024
local txn_counter = 0
local function random_tag()
  local file = io.open("/dev/urandom", "rb")
  local bytes = file and file:read(16)
  if file then file:close() end
  if not bytes or #bytes < 16 then
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    local out = {}
    for i = 1, 16 do out[i] = string.char(math.random(0, 255)) end
    bytes = table.concat(out)
  end
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

local function mentions_agent(text)
  if type(text) ~= "string" or type(is_agent_mxid) ~= "function" then return false end
  for mentioned in text:gmatch("@[%w._=/%-]+:[%w.%-]+") do
    if is_agent_mxid(mentioned) then return true end
  end
  return false
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

local function send_chunks(room, text, relation, on_done, txn_prefix)
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
      event_ids[#event_ids + 1] = result.json and result.json.event_id or ""
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
  if mentions_agent(opts.text) then return error_result(done, "Butler-to-Butler sends are disabled") end
  return send_chunks(room, opts.text, nil, done)
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

function matrix.reply(opts, on_done)
  opts = opts or {}
  local done = once(on_done)
  local room = configured_room(opts, done)
  if not room then return { cancel = function() end } end
  if type(opts.text) ~= "string" or opts.text == "" then
    return error_result(done, "message text must not be empty")
  end
  if mentions_agent(opts.text) then return error_result(done, "Butler-to-Butler sends are disabled") end
  local relay = matrix.relay and matrix.relay.instance
  if not relay or type(relay.can_reply_to) ~= "function" then
    return error_result(done, "Matrix relay is not running; event sender cannot be verified")
  end
  if not relay:can_reply_to(opts.event_id) then
    return error_result(done, "Butler-to-Butler replies are disabled")
  end
  return same_room_then(room, opts.event_id, done, function(reply_done)
    local root = type(opts.thread_root) == "string" and opts.thread_root ~= ""
      and opts.thread_root or opts.event_id
    local relation = { rel_type = "m.thread", event_id = root,
      ["m.in_reply_to"] = { event_id = opts.event_id } }
    return send_chunks(room, opts.text, relation, reply_done, opts.txn_id)
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

function matrix.upload(opts, on_done)
  opts = opts or {}
  local done = once(on_done)
  local room = configured_room(opts, done)
  if not room then return { cancel = function() end } end
  if type(opts.file) ~= "string" or opts.file == "" or not absolute(opts.file) then
    return error_result(done, "use an absolute path (the daemon does not know your cwd)")
  end
  local file, open_error = io.open(opts.file, "rb")
  if not file then return error_result(done, "cannot read upload file: " .. tostring(open_error)) end
  local ok, data, read_error = pcall(function() return file:read(MAX_UPLOAD_BYTES + 1) end)
  file:close()
  if not ok then return error_result(done, "upload path is not a readable regular file") end
  if read_error then return error_result(done, "upload path is not a readable regular file: " .. tostring(read_error)) end
  if not data or #data == 0 then return error_result(done, "upload file must not be empty") end
  if #data > MAX_UPLOAD_BYTES then return error_result(done, "upload exceeds 20 MiB limit") end
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
    local body, encode_error = matrix.encode_json({ msgtype = msgtype, body = filename,
      url = content_uri, info = { mimetype = mime, size = #data } })
    if not body then return done({ error = encode_error }) end
    current = matrix.request_json({ method = "PUT",
      path = "/_matrix/client/v3/rooms/" .. path_component(room)
        .. "/send/" .. msgtype .. "/" .. next_txn(),
      room = room, body = body, headers = { ["Content-Type"] = "application/json" },
    }, function(result)
      if result.error then return done(result) end
      done({ event_id = result.json and result.json.event_id or "", content_uri = content_uri })
    end)
  end)
  return handle
end

local function operator_room(verb, opts, agent, callback)
  if agent then
    callback({ error = "matrix " .. verb .. " is operator-only (advisory at the same UID until core #218)" })
    return nil
  end
  if not opts.room or opts.room == "" then
    callback({ error = verb .. " requires room" })
    return nil
  end
  return opts.room
end

function matrix.join(opts, on_done, agent)
  opts = opts or {}
  local done = once(on_done)
  local room = operator_room("join", opts, agent, done)
  if not room then return { cancel = function() end } end
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  local config_path = paths.config_path
  if type(config_path) ~= "string" or config_path == "" then
    return error_result(done, "Matrix config path is unavailable")
  end
  local conf, config_error = matrix.read_config(config_path)
  if not conf then return error_result(done, config_error) end
  local added = false
  if conf.rooms[room] ~= "home" and conf.rooms[room] ~= "all" then
    local ok, wrote_or_error = matrix.config_add_room(config_path, room, "operator")
    local add_error = not ok and wrote_or_error or nil
    if not ok then return error_result(done, add_error) end
    added = wrote_or_error == true
  end
  return matrix.request_json({ method = "POST",
    path = "/_matrix/client/v3/rooms/" .. path_component(room) .. "/join",
    room = room, body = "{}", headers = { ["Content-Type"] = "application/json" },
  }, function(result)
    if result.error and added then
      local removed, remove_error = matrix.config_remove_room(config_path, room)
      if not removed then
        result.error = tostring(result.error) .. "; config rollback failed: " .. tostring(remove_error)
      end
    end
    if result.error and result.error:find("(M_FORBIDDEN)", 1, true) then
      local next_line = "Next: invite the bot (" .. conf.self_mxid .. ") to " .. room
        .. " from Element, then retry."
      local replaced
      result.error, replaced = result.error:gsub("Next:[^\r\n]*", function() return next_line end)
      if replaced == 0 then result.error = result.error .. "\n" .. next_line end
    end
    done(result)
  end)
end

function matrix.leave(opts, on_done, agent)
  opts = opts or {}
  local done = once(on_done)
  local room = operator_room("leave", opts, agent, done)
  if not room then return { cancel = function() end } end
  local paths = remuda._butler_matrix_config or remuda._butler_matrix_paths or {}
  local config_path = paths.config_path
  if type(config_path) ~= "string" or config_path == "" then
    return error_result(done, "Matrix config path is unavailable")
  end
  local conf, config_error = matrix.read_config(config_path)
  if not conf then return error_result(done, config_error) end
  if conf.rooms[room] == "home" or conf.rooms[room] == "all" then
    return error_result(done,
      "HOME and ALL rooms can't be left.\nNext: remuda butler matrix setup (to change HOME or ALL).")
  end
  if conf.rooms[room] == nil then
    return error_result(done, room .. " is not a configured Matrix room.")
  end
  return matrix.request_json({ method = "POST",
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
    done(result)
  end)
end

return matrix
