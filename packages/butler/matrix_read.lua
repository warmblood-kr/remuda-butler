-- Short asynchronous read composites over the single Matrix request word.
local matrix = assert(remuda.butler and remuda.butler.matrix, "Matrix request word is not loaded")
local function encode(value)
  return (tostring(value):gsub("([^%w%-%._~])", function(c)
    return string.format("%%%02X", c:byte())
  end))
end
local function done_error(callback, message)
  callback({ error = message })
  return { cancel = function() end }
end
local function room_arg(args)
  local room = args and args.room
  if room == nil or room == "" then return matrix.configured_room() end
  return room
end
local function room_path(room, suffix)
  return "/_matrix/client/v3/rooms/" .. encode(room) .. suffix
end
local function json_get(path, room, callback, extras)
  local request = { method = "GET", path = path, room = room, max_bytes = 1024 * 1024 }
  for k, v in pairs(extras or {}) do request[k] = v end
  return matrix.request_json(request, callback)
end

function matrix.rooms(args, callback)
  return json_get("/_matrix/client/v3/joined_rooms", nil, function(result)
    if result.error then return callback(result) end
    local body = result.json or {}
    callback({ status = result.status, json = { joined_rooms = body.joined_rooms or {} } })
  end)
end

function matrix.status(args, callback)
  local result = { whoami = nil, joined_rooms = nil }
  local first = json_get("/_matrix/client/v3/account/whoami", nil, function(user)
    if user.error then return callback(user) end
    result.whoami = user.json
    json_get("/_matrix/client/v3/joined_rooms", nil, function(rooms)
      if rooms.error then return callback(rooms) end
      result.joined_rooms = (rooms.json or {}).joined_rooms or {}
      result.user_id = result.whoami.user_id
      result.device_id = result.whoami.device_id
      local paths = remuda._butler_matrix_config
      local state_file = paths and paths.config_path and io.open(paths.config_path .. ".since", "rb")
      if state_file then
        local saved = state_file:read("*a")
        state_file:close()
        local state = matrix.decode_json(saved)
        if type(state) == "table" then
          result.sync_cursor = state.since
          result.fallback_cursor = state.messages_since
        end
      end
      result.whoami = nil
      callback({ status = 200, json = result })
    end)
  end)
  return first
end

function matrix.history(args, callback)
  args = args or {}
  local n = args.n == nil and 20 or tonumber(args.n)
  if not n or n ~= n or n == math.huge or n == -math.huge or n % 1 ~= 0 or n < 1 or n > 200 then
    return done_error(callback, "history -n must be an integer from 1 to 200")
  end
  local room, room_error = room_arg(args)
  if not room then return done_error(callback, room_error or "Matrix room is not configured") end
  local path = room_path(room, "/messages?dir=b&limit=" .. n)
  return json_get(path, room, function(result)
    if result.error then return callback(result) end
    local body = result.json or {}
    callback({ status = result.status, json = { room_id = room, chunk = body.chunk or {},
      start = body.start, ["end"] = body["end"] } })
  end)
end

function matrix.event(args, callback)
  args = args or {}
  if type(args.event_id) ~= "string" or args.event_id == "" then
    return done_error(callback, "event requires an event ID")
  end
  local room, room_error = room_arg(args)
  if not room then return done_error(callback, room_error or "Matrix room is not configured") end
  return json_get(room_path(room, "/event/" .. encode(args.event_id)), room, callback)
end

function matrix.thread(args, callback)
  args = args or {}
  if type(args.event_id) ~= "string" or args.event_id == "" then
    return done_error(callback, "thread requires an event ID")
  end
  local room, room_error = room_arg(args)
  if not room then return done_error(callback, room_error or "Matrix room is not configured") end
  local root = args.event_id
  local events, seen, cursor, pages = {}, {}, nil, 0
  local function page()
    if pages >= 1000 then
      return callback({ status = 200, json = { room_id = room, event_id = root,
        chunk = events, next_batch = cursor } })
    end
    pages = pages + 1
    local path = "/_matrix/client/v1/rooms/" .. encode(room) .. "/relations/"
      .. encode(root) .. "/m.thread?dir=b&limit=100"
    if cursor then path = path .. "&from=" .. encode(cursor) end
    return json_get(path, room, function(result)
      if result.error then return callback(result) end
      local body = result.json or {}
      for _, event in ipairs(body.chunk or {}) do events[#events + 1] = event end
      local next_cursor = body.next_batch
      if type(next_cursor) == "string" and next_cursor ~= "" and not seen[next_cursor] then
        seen[next_cursor], cursor = true, next_cursor
        return page()
      end
      callback({ status = result.status, json = {
        room_id = room, event_id = root, chunk = events, next_batch = cursor,
      } })
    end)
  end
  return page()
end

local function absolute(path)
  return type(path) == "string" and (path:sub(1, 1) == "/"
    or path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil)
end
local function mxc_parts(uri)
  if type(uri) ~= "string" then return nil end
  local server, media = uri:match("^mxc://([^/]+)/([^/]+)$")
  if not server or not media or server:find("%s") or media:find("%s") then return nil end
  return server, media
end
local function unrecognized(result)
  if result.status == 404 then return true end
  if type(result.body) ~= "string" then return false end
  local decoded = matrix.decode_json(result.body)
  return type(decoded) == "table" and decoded.errcode == "M_UNRECOGNIZED"
end

function matrix.download(args, callback)
  args = args or {}
  local server, media = mxc_parts(args.mxc)
  if not server then return done_error(callback, "download requires an mxc://server/media URI") end
  if args.output and not absolute(args.output) then
    return done_error(callback, "download -o requires an absolute path")
  end
  local path = "/_matrix/client/v1/media/download/" .. encode(server) .. "/" .. encode(media)
  local function save(result)
    if result.error then return callback(result) end
    local home = os.getenv("HOME")
    if not args.output and (not home or home:sub(1, 1) ~= "/") then
      return callback({ error = "download requires an absolute HOME or -o path" })
    end
    local output = args.output or home .. "/matrix-" .. media
    local file, err = io.open(output, "wb")
    if not file then return callback({ error = "cannot write Matrix media: " .. tostring(err) }) end
    local ok, write_error = file:write(result.body or "")
    local close_ok, close_error = file:close()
    if not ok then return callback({ error = "cannot write Matrix media: " .. tostring(write_error) }) end
    if not close_ok then return callback({ error = "cannot close Matrix media: " .. tostring(close_error) }) end
    local headers = result.headers or {}
    callback({ status = result.status, headers = result.headers, path = output,
      bytes = #(result.body or ""),
      content_type = headers["content-type"] or headers["Content-Type"] or "application/octet-stream",
      mxc = args.mxc })
  end
  local function legacy()
    return matrix.request({ method = "GET",
      path = "/_matrix/media/v3/download/" .. encode(server) .. "/" .. encode(media),
      max_bytes = 20 * 1024 * 1024, timeout = 30, headers = { Accept = "*/*" } }, save)
  end
  return matrix.request({ method = "GET", path = path, max_bytes = 20 * 1024 * 1024,
    timeout = 30, headers = { Accept = "*/*" } }, function(result)
      if result.error and unrecognized(result) then return legacy() end
      return save(result)
    end)
end

return matrix
