-- L3 Matrix relay: durable state + event delivery over the L1 request word.
-- The relay owns no transport details; request_json is its only HTTP composite.
local matrix = assert(remuda.butler and remuda.butler.matrix,
  "load butler/matrix_request before butler/matrix_relay")
local json = assert(remuda.json, "Matrix requires core remuda.json")
local relay = matrix.relay or {}
matrix.relay = relay
local JSON_ARRAY_MT = getmetatable(json.array({}))

local MAX_PROCESSED = 5000
local MAX_DELIVERY_FAILURES = 5
local MAX_BODY_BYTES = 64 * 1024
local SYNC_PATH = "/_matrix/client/v3/sync"
local MESSAGES_PREFIX = "/_matrix/client/v3/rooms/"
local warning_keys = relay.warning_keys or {}
relay.warning_keys = warning_keys

local function warn_once(kind, key, message)
  local warning_key = kind .. "\0" .. key
  if warning_keys[warning_key] then return end
  warning_keys[warning_key] = true
  pcall(function() io.stderr:write(message .. "\n") end)
end

local function encode(value)
  local ok, result = pcall(json.encode, value)
  if not ok then error("cannot encode Matrix relay state: " .. tostring(result)) end
  return result
end

local function decode(value)
  return json.decode(value)
end

local function percent_encode(value)
  return (tostring(value):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

local function query(path, params)
  local parts = {}
  local order
  if params.from ~= nil then order = { "from", "dir", "limit" }
  elseif params.since ~= nil then order = { "since", "timeout" }
  else order = { "timeout", "dir", "limit" } end
  for _, key in ipairs(order) do
    local value = params[key]
    if value ~= nil then
      parts[#parts + 1] = percent_encode(key) .. "=" .. percent_encode(value)
    end
  end
  if #parts == 0 then return path end
  return path .. "?" .. table.concat(parts, "&")
end

local function cap_body(body)
  body = tostring(body or "")
  if #body <= MAX_BODY_BYTES then return body end
  local keep = MAX_BODY_BYTES
  while keep > 0 do
    local next_byte = body:byte(keep + 1)
    if not next_byte or next_byte < 0x80 or next_byte >= 0xc0 then break end
    keep = keep - 1
  end
  local prefix = body:sub(1, keep)
  local suffix = "[truncated " .. tostring(#body - #prefix) .. " bytes]"
  while #prefix + #suffix > MAX_BODY_BYTES do
    keep = keep - 1
    while keep > 0 do
      local next_byte = body:byte(keep + 1)
      if not next_byte or next_byte < 0x80 or next_byte >= 0xc0 then break end
      keep = keep - 1
    end
    prefix = body:sub(1, keep)
    suffix = "[truncated " .. tostring(#body - #prefix) .. " bytes]"
  end
  return prefix .. suffix
end

local function timestamp(event)
  local ms = event and tonumber(event.origin_server_ts)
  if ms and ms >= 0 and ms < 253402300800000 then
    return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(ms / 1000))
  end
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function relation_fields(content)
  local rel = content and content["m.relates_to"]
  if type(rel) ~= "table" then return nil, nil end
  local root = rel.rel_type == "m.thread" and rel.event_id or nil
  local reply = type(rel["m.in_reply_to"]) == "table" and rel["m.in_reply_to"].event_id or nil
  return root, reply
end

local function media_uri(content)
  if type(content) ~= "table" then return nil end
  if type(content.url) == "string" then return content.url end
  if type(content.file) == "table" and type(content.file.url) == "string" then return content.file.url end
end

local function add_processed(state, id)
  if not id or id == "" then return end
  if state.processed[id] then
    for i, existing in ipairs(state.processed_order) do
      if existing == id then table.remove(state.processed_order, i); break end
    end
  end
  state.processed[id] = true
  state.processed_order[#state.processed_order + 1] = id
  while #state.processed_order > MAX_PROCESSED do
    state.processed[table.remove(state.processed_order, 1)] = nil
  end
end

local function empty_state()
  return { since = nil, messages_since = nil, processed = {}, processed_order = {}, pending = json.object({}) }
end

local function load_state(path)
  local file = io.open(path, "rb")
  local backup = path .. ".bak"
  local recovered = false
  if not file then
    file = io.open(backup, "rb")
    recovered = file ~= nil
  end
  if not file then return empty_state() end
  local text = file:read("*a")
  file:close()
  if recovered then os.rename(backup, path) end
  local value, err = decode(text)
  if type(value) ~= "table" or value == json.null or getmetatable(value) == JSON_ARRAY_MT then
    return empty_state(), err or "invalid state root"
  end
  local since, messages_since = value.since, value.messages_since
  if since == json.null then since = nil end
  if messages_since == json.null then messages_since = nil end
  local processed_ids = value.processed_event_ids
  if processed_ids == nil then processed_ids = json.array({}) end
  local pending = value.pending_events or json.object({})
  if (since ~= nil and type(since) ~= "string")
    or (messages_since ~= nil and type(messages_since) ~= "string")
    or type(processed_ids) ~= "table" or processed_ids == json.null
    or getmetatable(processed_ids) ~= JSON_ARRAY_MT
    or type(pending) ~= "table" or pending == json.null
    or getmetatable(pending) == JSON_ARRAY_MT then
    return empty_state(), "invalid Matrix relay state fields"
  end
  local state = empty_state()
  state.since, state.messages_since = since, messages_since
  for _, id in ipairs(processed_ids) do
    if type(id) ~= "string" then return empty_state(), "invalid processed event ID" end
    if id ~= "" then add_processed(state, id) end
  end
  for id, event in pairs(pending) do
    if type(id) == "string" and type(event) == "table"
      and type(event.sender) == "string" and type(event.room_id) == "string"
      and type(event.created_at) == "string" and type(event.body) == "string" then
      event.event_id = event.event_id or id
      state.pending[id] = event
    end
  end
  return state
end

local function save_state(path, state)
  local processed = json.array(state.processed_order)
  local json = encode({ since = state.since, processed_event_ids = processed,
    messages_since = state.messages_since, pending_events = state.pending })
  local temp = path .. ".tmp"
  local file, err = io.open(temp, "wb")
  if not file then return nil, err end
  local ok, write_err = file:write(json)
  local closed, close_err = file:close()
  if not ok or not closed then os.remove(temp); return nil, write_err or close_err end
  local renamed, rename_err = os.rename(temp, path)
  if renamed then
    os.remove(path .. ".bak")
    return true
  end
  -- Windows rename does not replace an existing destination. Keep a recoverable
  -- old state around the replace window; load_state restores it after a crash.
  local backup = path .. ".bak"
  os.remove(backup)
  local moved_old, move_err = os.rename(path, backup)
  if not moved_old then os.remove(temp); return nil, move_err or rename_err end
  renamed, rename_err = os.rename(temp, path)
  if not renamed then
    os.rename(backup, path)
    os.remove(temp)
    return nil, rename_err
  end
  os.remove(backup)
  return true
end

function relay.new(options)
  options = options or {}
  local config_path = assert(options.config_path, "Matrix relay requires config_path")
  local api = assert(options.matrix or matrix, "Matrix relay requires the L1 matrix client")
  local deliver = assert(options.deliver, "Matrix relay requires a delivery function")
  local cfg, config_error = matrix.read_config(config_path)
  if not cfg then error(config_error, 0) end
  local state_path, ack_path = config_path .. ".since", config_path .. ".acks"
  local state, state_error = load_state(state_path)
  if state_error then
    warn_once("state", state_path .. "\0" .. state_error,
      "butler invalid Matrix relay state; starting from a fresh baseline: " .. tostring(state_error))
  end
  local active, request_handle, retry_timer, backfill_timer = false, nil, nil, nil
  local delivery_retry_waiting, delivery_retry_timers = {}, {}
  local failures = 0
  local instance = {}
  local function persist()
    local ok, err = save_state(state_path, state)
    if not ok then error("cannot save Matrix relay state: " .. tostring(err), 0) end
  end

  local function reconcile_acks()
    local drain = ack_path .. ".drain"
    local function apply(path)
      local file = io.open(path, "rb")
      if not file then return end
      local changed = false
      for id in file:lines() do
        if state.pending[id] then
          add_processed(state, id)
          state.pending[id] = nil
          changed = true
        end
      end
      file:close()
      if changed then persist() end
      os.remove(path)
    end
    apply(drain)
    local ack = io.open(ack_path, "rb")
    if ack then
      ack:close()
      os.remove(drain)
      local moved = os.rename(ack_path, drain)
      if moved then apply(drain) end
    end
  end

  local function append_ack(id)
    local file, err = io.open(ack_path, "ab")
    if not file then error("cannot append Matrix relay ack: " .. tostring(err), 0) end
    assert(file:write(id, "\n"))
    assert(file:close())
  end

  local deliver_pending
  local function schedule_delivery_retry(id, delay)
    local elapsed = 0
    local timer
    timer = remuda.schedule({ every = 1, run = function()
      if delivery_retry_timers[id] ~= timer then return end
      elapsed = elapsed + 1
      if elapsed < delay then return end
      remuda.cancel(timer)
      delivery_retry_timers[id] = nil
      delivery_retry_waiting[id] = nil
      if active then deliver_pending({ id }) end
    end })
    delivery_retry_timers[id] = timer
  end

  deliver_pending = function(only)
    local ids = only or state.pending_order
    if not ids then
      ids = {}
      for id in pairs(state.pending) do ids[#ids + 1] = id end
      table.sort(ids)
    end
    for _, id in ipairs(ids) do
      local event = state.pending[id]
      if event and not delivery_retry_waiting[id] then
        local ok, result = pcall(deliver, event)
        if ok and result ~= nil then
          append_ack(id)
        elseif not ok then
          local attempts = (tonumber(event._relay_failures) or 0) + 1
          event._relay_failures = attempts
          if attempts >= MAX_DELIVERY_FAILURES then
            add_processed(state, id)
            state.pending[id] = nil
            persist()
            pcall(function()
              io.stderr:write("butler Matrix delivery dead-lettered " .. tostring(id)
                .. " after " .. tostring(attempts) .. " failed attempts: " .. tostring(result) .. "\n")
            end)
          else
            persist()
            delivery_retry_waiting[id] = true
            schedule_delivery_retry(id, math.min(16, 2 ^ (attempts - 1)))
            pcall(function()
              io.stderr:write("butler Matrix delivery failed for " .. tostring(id) .. ": " .. tostring(result) .. "\n")
            end)
          end
        end
      end
    end
    reconcile_acks()
  end

  local function schedule(delay, key, callback)
    local old
    if key == "retry" then old = retry_timer else old = backfill_timer end
    if old then pcall(remuda.cancel, old) end
    local handle
    handle = remuda.schedule({ every = 1, run = function()
      if (key == "retry" and retry_timer ~= handle)
        or (key == "backfill" and backfill_timer ~= handle) then return end
      delay = delay - 1
      if delay > 0 then return end
      remuda.cancel(handle)
      if key == "retry" then retry_timer = nil else backfill_timer = nil end
      callback()
    end })
    if key == "retry" then retry_timer = handle else backfill_timer = handle end
  end

  local poll
  local function failed()
    failures = failures + 1
    local delay = math.min(60, 2 ^ math.min(6, failures - 1))
    schedule(delay, "retry", function() if active then poll() end end)
  end

  local function accept_events(events, cursor)
    local added = {}
    for _, ev in ipairs(type(events) == "table" and events or {}) do
      if ev.type == "m.room.message" and type(ev.event_id) == "string" and ev.event_id ~= ""
        and not state.processed[ev.event_id] and not state.pending[ev.event_id]
        and type(ev.sender) == "string" and ev.sender ~= cfg.self_mxid and cfg.allowed_senders[ev.sender] then
        local content = type(ev.content) == "table" and ev.content or {}
        if content.msgtype == "m.text" or content.msgtype == "m.notice" or content.msgtype == "m.emote" then
          local thread_root, in_reply_to = relation_fields(content)
          state.pending[ev.event_id] = {
            sender = ev.sender, room_id = cfg.room, event_id = ev.event_id,
            created_at = timestamp(ev), body = cap_body(content.body),
            thread_root = thread_root, in_reply_to = in_reply_to, mxc = media_uri(content),
          }
          added[#added + 1] = ev.event_id
          if cursor then state.since = cursor end
          persist()
        end
      end
    end
    return added
  end

  local function begin_request(path, params, timeout)
    if not active then return end
    local args = { method = "GET", path = query(path, params), room = cfg.room,
      timeout = timeout, max_bytes = 1024 * 1024 }
    local callback_seen = false
    local handle = api.request_json(args, function(result)
      callback_seen = true
      request_handle = nil
      if not active then return end
      if type(result) ~= "table" or result.error or type(result.json) ~= "table" then
        if type(result) == "table" and type(result.error) == "string" then
          if result.error:find("outside the configured Matrix allowlist", 1, true) then
            warn_once("allowlist", result.error,
              "butler Matrix relay request refused by configured allowlist: " .. result.error)
          elseif result.error == "Matrix token is empty"
              or result.error:find("^HTTPS Matrix homeserver requires ca_file=PATH or pin_sha256=HEX") then
            warn_once("config", result.error, "butler Matrix relay misconfigured: " .. result.error)
          end
        end
        failed(); return
      end
      failures = 0
      local ok = pcall(function() instance._response(result.json, path) end)
      if not ok and active then failed() end
    end)
    if not callback_seen then request_handle = handle end
  end

  function instance._response(response, path)
    if path == SYNC_PATH and state.since == nil then
      if type(response.next_batch) ~= "string" then failed(); return end
      state.since = response.next_batch
      persist()
      deliver_pending()
      poll()
      return
    end
    if path == SYNC_PATH then
      local room = response.rooms and response.rooms.join and response.rooms.join[cfg.room]
      local events = room and room.timeline and room.timeline.events or {}
      local added = accept_events(events)
      if type(response.next_batch) == "string" then state.since = response.next_batch end
      persist()
      deliver_pending(added)
      poll()
      return
    end
    if state.messages_since == nil then
      state.messages_since = response.start or response["end"]
      for _, event in ipairs(response.chunk or {}) do
        if type(event.event_id) == "string" then add_processed(state, event.event_id) end
      end
      persist()
      deliver_pending()
      schedule(3, "backfill", function() if active then poll() end end)
      return
    end
    local added = accept_events(response.chunk)
    state.messages_since = response["end"] or state.messages_since
    persist()
    deliver_pending(added)
    schedule(3, "backfill", function() if active then poll() end end)
  end

  poll = function()
    if not active then return end
    reconcile_acks()
    deliver_pending()
    if cfg.use_messages then
      local path = MESSAGES_PREFIX .. percent_encode(cfg.room) .. "/messages"
      if state.messages_since == nil then
        begin_request(path, { dir = "b", limit = "1" }, 15)
      else
        begin_request(path, { from = state.messages_since, dir = "f", limit = "100" }, 15)
      end
    elseif state.since == nil then
      begin_request(SYNC_PATH, { timeout = "0" }, 10)
    else
      begin_request(SYNC_PATH, { since = state.since, timeout = tostring(cfg.timeout_ms) }, cfg.timeout_ms / 1000 + 10)
    end
  end

  function instance:start()
    if active then return false end
    active = true
    poll()
    return true
  end

  function instance:stop()
    active = false
    if request_handle and request_handle.cancel then pcall(function() request_handle:cancel() end) end
    request_handle = nil
    if retry_timer then pcall(remuda.cancel, retry_timer) end
    if backfill_timer then pcall(remuda.cancel, backfill_timer) end
    for _, timer in pairs(delivery_retry_timers) do pcall(remuda.cancel, timer) end
    delivery_retry_timers, delivery_retry_waiting = {}, {}
    retry_timer, backfill_timer = nil, nil
    return true
  end

  function instance:state()
    return state
  end

  function instance:metadata()
    return { config = cfg, path = state_path, ack_path = ack_path }
  end

  return instance
end

function relay.start(config)
  if relay.instance then return false end
  if not config or not config.config_path then return false end
  relay.instance = relay.new({ config_path = config.config_path, matrix = matrix,
    deliver = function(event)
      local delivered = remuda.emit_until_success("butler/deliver", {
        from = { host = "matrix", id = "", alias = event.sender, session = event.sender,
          kind = "matrix", leader = "" },
        to = "butler", text = event.body, subject = "Matrix message from " .. event.sender,
        matrix = { sender = event.sender, room_id = event.room_id, event_id = event.event_id,
          created_at = event.created_at, thread_root = event.thread_root,
          in_reply_to = event.in_reply_to, mxc = event.mxc },
      })
      if type(delivered) == "table" and delivered.__butler_delivery_hook_error then
        error(delivered.__butler_delivery_hook_error, 0)
      end
      return delivered
    end,
  })
  return relay.instance:start()
end

function relay.stop()
  if not relay.instance then return false end
  relay.instance:stop()
  relay.instance = nil
  return true
end

return relay
