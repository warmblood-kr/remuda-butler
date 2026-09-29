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
local MAX_QUARANTINE_ITEMS = 200
local MAX_QUARANTINE_PREVIEW_BYTES = 1024
local QUARANTINE_TTL_SECONDS = 30 * 24 * 60 * 60
local MAX_MAIL_ROUTES = 5000
local MAX_REPLY_OUTBOX = 1000
local MAX_REPLY_RESULTS = 5000
local MAX_MAIL_REPLY_BYTES = 64 * 1024
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

local function quarantine_preview(value)
  if type(value) ~= "string" then return "" end
  if #value <= MAX_QUARANTINE_PREVIEW_BYTES then return value end
  local keep = MAX_QUARANTINE_PREVIEW_BYTES - 14
  while keep > 0 do
    local next_byte = value:byte(keep + 1)
    if not next_byte or next_byte < 0x80 or next_byte >= 0xc0 then break end
    keep = keep - 1
  end
  return value:sub(1, keep) .. " [truncated]"
end

local function cap_field(value, limit)
  if type(value) ~= "string" then return "" end
  return #value <= limit and value or value:sub(1, limit)
end

local function relation_fields(content)
  local rel = content and content["m.relates_to"]
  if type(rel) ~= "table" then return nil, nil end
  local root = rel.rel_type == "m.thread" and rel.event_id or nil
  local reply = type(rel["m.in_reply_to"]) == "table" and rel["m.in_reply_to"].event_id or nil
  return root, reply
end

local function mentions(content, body, mxid)
  local mentions = content and content["m.mentions"]
  if type(mentions) == "table" and type(mentions.user_ids) == "table" then
    for _, user in ipairs(mentions.user_ids) do if user == mxid then return true end end
  end
  return type(body) == "string" and body:find(mxid, 1, true) ~= nil
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

local function trim_map(map, maximum, time_field)
  local count = 0
  for _ in pairs(map) do count = count + 1 end
  while count > maximum do
    local oldest_id, oldest_time
    for id, item in pairs(map) do
      local item_time = type(item) == "table" and item[time_field] or nil
      item_time = type(item_time) == "string" and item_time or ""
      if not oldest_id or item_time < oldest_time or (item_time == oldest_time and id < oldest_id) then
        oldest_id, oldest_time = id, item_time
      end
    end
    if not oldest_id then break end
    map[oldest_id] = nil
    count = count - 1
  end
end

local function empty_state()
  return { since = nil, messages_since = nil, processed = {}, processed_order = {},
    pending = json.object({}), quarantine = json.array({}), routes = json.object({}),
    direct_rooms = json.object({}),
    reply_outbox = json.object({}), reply_results = json.object({}) }
end

local function load_state(path)
  local file = io.open(path, "rb")
  if not file then return empty_state() end
  local text = file:read("*a")
  file:close()
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
  local quarantine = value.quarantine or json.array({})
  local routes = value.matrix_mail_routes or json.object({})
  local reply_outbox = value.matrix_reply_outbox or json.object({})
  local reply_results = value.matrix_reply_results or json.object({})
  local direct_rooms = value.matrix_direct_rooms or json.object({})
  if (since ~= nil and type(since) ~= "string")
    or (messages_since ~= nil and type(messages_since) ~= "string")
    or type(processed_ids) ~= "table" or processed_ids == json.null
    or getmetatable(processed_ids) ~= JSON_ARRAY_MT
    or type(pending) ~= "table" or pending == json.null
    or getmetatable(pending) == JSON_ARRAY_MT
    or type(quarantine) ~= "table" or quarantine == json.null
    or getmetatable(quarantine) ~= JSON_ARRAY_MT
    or type(routes) ~= "table" or routes == json.null or getmetatable(routes) == JSON_ARRAY_MT
    or type(reply_outbox) ~= "table" or reply_outbox == json.null or getmetatable(reply_outbox) == JSON_ARRAY_MT
    or type(reply_results) ~= "table" or reply_results == json.null or getmetatable(reply_results) == JSON_ARRAY_MT then
    return empty_state(), "invalid Matrix relay state fields"
  end
  local state = empty_state()
  local quarantine_pruned = false
  state.since, state.messages_since = since, messages_since
  state.quarantine, state.routes = json.array({}), json.object({})
  state.reply_outbox, state.reply_results = json.object({}), json.object({})
  if type(direct_rooms) == "table" and direct_rooms ~= json.null and getmetatable(direct_rooms) ~= JSON_ARRAY_MT then
    for room_id, senders in pairs(direct_rooms) do
      if type(room_id) == "string" and type(senders) == "table" then
        state.direct_rooms[room_id] = senders
      end
    end
  end
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
  for _, item in ipairs(quarantine) do
    if type(item) == "table" and type(item.id) == "string"
      and type(item.reason) == "string" and type(item.created_at) == "string"
      and (type(item.expires_at) ~= "string" or item.expires_at >= os.date("!%Y-%m-%dT%H:%M:%SZ")) then
      item.id, item.event_id = cap_field(item.id, 512), cap_field(item.event_id, 512)
      item.sender, item.reason = cap_field(item.sender, 256), cap_field(item.reason, 80)
      item.preview = quarantine_preview(item.preview)
      state.quarantine[#state.quarantine + 1] = item
      if #state.quarantine >= MAX_QUARANTINE_ITEMS then break end
    else
      quarantine_pruned = true
    end
  end
  for id, route in pairs(routes) do
    if type(id) == "string" and type(route) == "table"
      and type(route.room_id) == "string" and type(route.event_id) == "string" then
      state.routes[id] = route
    end
  end
  for id, item in pairs(reply_outbox) do
    if type(id) == "string" and type(item) == "table"
      and type(item.source_mail_id) == "string" and type(item.room_id) == "string"
      and type(item.event_id) == "string" and type(item.text) == "string"
      and type(item.txn_id) == "string" then state.reply_outbox[id] = item end
  end
  for id, item in pairs(reply_results) do
    if type(id) == "string" and type(item) == "table"
      and type(item.source_mail_id) == "string" and type(item.event_id) == "string"
      and type(item.completed_at) == "string" then
      state.reply_results[id] = item
    end
  end
  trim_map(state.routes, MAX_MAIL_ROUTES, "created_at")
  trim_map(state.reply_outbox, MAX_REPLY_OUTBOX, "created_at")
  trim_map(state.reply_results, MAX_REPLY_RESULTS, "completed_at")
  return state, nil, quarantine_pruned
end

local function save_state(path, state)
  local processed = json.array(state.processed_order)
  local json = encode({ since = state.since, processed_event_ids = processed,
    messages_since = state.messages_since, pending_events = state.pending,
    quarantine = state.quarantine, matrix_mail_routes = state.routes,
    matrix_reply_outbox = state.reply_outbox, matrix_reply_results = state.reply_results,
    matrix_direct_rooms = state.direct_rooms })
  return remuda.fs.write_atomic(path, json, { private = true })
end

function relay.new(options)
  options = options or {}
  local config_path = assert(options.config_path, "Matrix relay requires config_path")
  local api = assert(options.matrix or matrix, "Matrix relay requires the L1 matrix client")
  local deliver = assert(options.deliver, "Matrix relay requires a delivery function")
  local cfg, config_error = matrix.read_config(config_path)
  if not cfg then error(config_error, 0) end
  local state_path, ack_path = config_path .. ".since", config_path .. ".acks"
  local state, state_error, quarantine_pruned = load_state(state_path)
  if state_error then
    warn_once("state", state_path .. "\0" .. state_error,
      "butler invalid Matrix relay state; starting from a fresh baseline: " .. tostring(state_error))
  end
  if quarantine_pruned and not state_error then
    local saved, save_error = save_state(state_path, state)
    if not saved then warn_once("quarantine", state_path .. "\0expiry",
      "butler could not remove expired Matrix quarantine records: " .. tostring(save_error)) end
  end
  local active, request_handle, request_token, retry_timer, backfill_timer = false, nil, nil, nil, nil
  local delivery_retry_waiting, delivery_retry_timers = {}, {}
  local reply_retry_timers, reply_in_flight = {}, {}
  local generation = 0
  local failures = 0
  local instance = {}
  local function persist()
    local ok, err = save_state(state_path, state)
    if not ok then error("cannot save Matrix relay state: " .. tostring(err), 0) end
  end

  local function quarantine_event(ev, reason)
    local event_id = type(ev.event_id) == "string" and ev.event_id or ""
    local valid_id = event_id ~= "" and #event_id <= 512
    local id = valid_id and event_id or ("quarantine-" .. tostring(remuda._butler_new_ulid()))
    for _, item in ipairs(state.quarantine) do
      if item.id == id then return false end
    end
    local content = type(ev.content) == "table" and ev.content or {}
    state.quarantine[#state.quarantine + 1] = {
      id = id, event_id = cap_field(event_id, 512), sender = cap_field(ev.sender, 256),
      room_id = cap_field(cfg.room, 512), created_at = timestamp(ev), reason = reason,
      event_type = type(ev.type) == "string" and ev.type:sub(1, 80) or "",
      msgtype = type(content.msgtype) == "string" and content.msgtype:sub(1, 80) or "",
      preview = quarantine_preview(content.body),
      expires_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + QUARANTINE_TTL_SECONDS),
    }
    while #state.quarantine > MAX_QUARANTINE_ITEMS do table.remove(state.quarantine, 1) end
    if valid_id then add_processed(state, event_id) end
    persist()
    return true
  end

  function instance:quarantine_list()
    local result = {}
    local now, changed = os.date("!%Y-%m-%dT%H:%M:%SZ"), false
    for index = #state.quarantine, 1, -1 do
      local expires = state.quarantine[index].expires_at
      if type(expires) == "string" and expires < now then
        table.remove(state.quarantine, index)
        changed = true
      end
    end
    if changed then persist() end
    for _, item in ipairs(state.quarantine) do
      local copy = {}
      for key, value in pairs(item) do copy[key] = value end
      result[#result + 1] = copy
    end
    return result
  end

  function instance:quarantine_get(id)
    for _, item in ipairs(self:quarantine_list()) do
      if item.id == id or item.event_id == id then
        local copy = {}
        for key, value in pairs(item) do copy[key] = value end
        return copy
      end
    end
  end

  function instance:mail_reply_status(mail_id)
    local route = state.routes[mail_id]
    if not route or not route.last_reply_event_id then return nil end
    return { source_mail_id = mail_id, reply_mail_id = route.last_reply_mail_id,
      room_id = route.room_id, thread_root = route.thread_root,
      event_id = route.last_reply_event_id }
  end

  function instance:mail_route_for_event(room_id, thread_root, in_reply_to)
    local fallback
    for mail_id, route in pairs(state.routes) do
      if route.room_id == room_id then
        if in_reply_to and (route.last_reply_event_id == in_reply_to or route.event_id == in_reply_to) then
          return mail_id
        end
        if thread_root and (route.last_reply_event_id == thread_root
          or route.thread_root == thread_root or route.event_id == thread_root) then
          fallback = fallback or mail_id
        end
      end
    end
    return fallback
  end

  function instance:record_outgoing_reply(event_id, sent_id)
    if type(event_id) ~= "string" or type(sent_id) ~= "string" or sent_id == "" then return false end
    for _, route in pairs(state.routes) do
      if route.event_id == event_id or route.last_reply_event_id == event_id then
        if route.from_butler then return false end
        route.last_reply_event_id = sent_id
        persist()
        return true
      end
    end
    return false
  end

  function instance:can_reply_to(event_id)
    for _, route in pairs(state.routes) do
      if route.event_id == event_id or route.last_reply_event_id == event_id then
        return not route.from_butler
      end
    end
    return true
  end

  function instance:thread_root_for_event(event_id)
    for _, route in pairs(state.routes) do
      if route.event_id == event_id or route.last_reply_event_id == event_id then
        return route.thread_root or route.event_id
      end
    end
    return event_id
  end

  local function schedule_reply_retry(reply_id, delay)
    local retry_generation = generation
    local timer
    timer = remuda.schedule({ every = 1, run = function()
      if not active or generation ~= retry_generation or reply_retry_timers[reply_id] ~= timer then return end
      delay = delay - 1
      if delay > 0 then return end
      remuda.cancel(timer)
      reply_retry_timers[reply_id] = nil
      instance._send_reply(reply_id)
    end })
    reply_retry_timers[reply_id] = timer
  end

  function instance._send_reply(reply_id, callback)
    local item = state.reply_outbox[reply_id]
    if not item or reply_in_flight[reply_id] then return end
    item.attempts = (tonumber(item.attempts) or 0) + 1
    persist()
    local send_generation = generation
    local token = { generation = send_generation }
    reply_in_flight[reply_id] = token
    token.handle = api.reply({ room = item.room_id, event_id = item.event_id, text = item.text,
      thread_root = item.thread_root, txn_id = item.txn_id }, function(result)
      if reply_in_flight[reply_id] ~= token or generation ~= send_generation then return end
      reply_in_flight[reply_id] = nil
      if type(result) == "table" and not result.error then
        local ids = result.event_ids or {}
        local sent_id = result.event_id or ids[#ids]
        if type(sent_id) ~= "string" or sent_id == "" then
          result = { error = "Matrix reply omitted the sent event ID" }
        else
          local route = state.routes[item.source_mail_id] or {}
          route.room_id, route.event_id, route.thread_root = item.room_id, item.event_id, item.thread_root
          route.last_reply_mail_id, route.last_reply_event_id = reply_id, sent_id
          state.routes[item.source_mail_id] = route
          state.reply_results[reply_id] = { source_mail_id = item.source_mail_id,
            reply_mail_id = reply_id, room_id = item.room_id, thread_root = item.thread_root,
            event_id = sent_id, event_ids = ids, completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
          trim_map(state.reply_results, MAX_REPLY_RESULTS, "completed_at")
          state.reply_outbox[reply_id] = nil
          persist()
          if callback then callback(state.reply_results[reply_id]) end
          return
        end
      end
      item.last_error = tostring(result and result.error or "Matrix reply failed")
      if item.attempts >= 8 then
        state.reply_results[reply_id] = { source_mail_id = item.source_mail_id,
          reply_mail_id = reply_id, room_id = item.room_id, thread_root = item.thread_root,
          event_id = "", error = item.last_error, completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
        state.reply_outbox[reply_id] = nil
        trim_map(state.reply_results, MAX_REPLY_RESULTS, "completed_at")
      else
        item.status = "pending"
        schedule_reply_retry(reply_id, math.min(60, 2 ^ math.min(6, item.attempts - 1)))
      end
      persist()
      if callback then callback({ error = item.last_error, attempts = item.attempts }) end
    end)
  end

  function instance:queue_mail_reply(opts, callback)
    opts = opts or {}
    local source_id = opts.mail_id or opts.source_mail_id
    local reply_id = opts.reply_mail_id or opts.txn_id or source_id
    if type(source_id) ~= "string" or source_id == "" or type(reply_id) ~= "string" or reply_id == "" then
      return nil, "mail_id and reply_mail_id are required"
    end
    if state.reply_results[reply_id] then
      if callback then callback(state.reply_results[reply_id]) end
      return { cancel = function() end }
    end
    local route = state.routes[source_id] or opts.route
    if not route then return nil, "Matrix route for Butler mail " .. source_id .. " was not found" end
    if route.from_butler then return nil, "Butler-to-Butler replies are disabled" end
    if not state.routes[source_id] then
      if type(route.room_id) ~= "string" or type(route.event_id) ~= "string" then
        return nil, "Matrix reply route is incomplete"
      end
      state.routes[source_id] = { room_id = route.room_id, event_id = route.event_id,
        thread_root = route.thread_root, in_reply_to = route.in_reply_to,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
      route = state.routes[source_id]
      trim_map(state.routes, MAX_MAIL_ROUTES, "created_at")
      persist()
    end
    local existing = state.reply_outbox[reply_id]
    if not existing then
      if type(opts.text) ~= "string" or opts.text == "" then return nil, "reply text must not be empty" end
      if #opts.text > MAX_MAIL_REPLY_BYTES then return nil, "Matrix mail reply exceeds 64 KiB" end
      local pending = 0
      for _ in pairs(state.reply_outbox) do pending = pending + 1 end
      if pending >= MAX_REPLY_OUTBOX then return nil, "Matrix mail reply outbox is full" end
      local root = route.thread_root
      state.reply_outbox[reply_id] = { source_mail_id = source_id, room_id = route.room_id,
        event_id = route.event_id, thread_root = root, text = opts.text,
        txn_id = opts.txn_id or ("butler_" .. reply_id), attempts = 0, status = "pending",
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
      persist()
    end
    instance._send_reply(reply_id, callback)
    return { cancel = function() end }
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
            if type(result) == "table" and type(result.id) == "string" and result.id ~= "" then
              state.routes[result.id] = { room_id = event.room_id, event_id = event.event_id,
                thread_root = event.thread_root, in_reply_to = event.in_reply_to,
                context_mail_id = event.context_mail_id, from_butler = event.from_butler,
                created_at = event.created_at }
              trim_map(state.routes, MAX_MAIL_ROUTES, "created_at")
              persist()
            end
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

  local function accept_events(events, cursor, room_id)
    local added = {}
    for _, ev in ipairs(type(events) == "table" and events or {}) do
      if type(ev) == "table" then
        local event_id = type(ev.event_id) == "string" and ev.event_id or ""
        if (event_id == "" or (not state.processed[event_id] and not state.pending[event_id]))
          and ev.sender ~= cfg.self_mxid then
          local content = type(ev.content) == "table" and ev.content or {}
          local reason
          if event_id == "" then reason = "missing_event_id"
          elseif ev.type ~= "m.room.message" then reason = "unsupported_event_type"
          elseif type(ev.sender) ~= "string" or ev.sender == "" then reason = "missing_sender"
          elseif not cfg.allowed_senders[ev.sender] then reason = "sender_not_allowlisted"
          elseif content.msgtype ~= "m.text" and content.msgtype ~= "m.notice" and content.msgtype ~= "m.emote" then
            reason = "unsupported_message_type"
          elseif type(content.body) ~= "string" then reason = "missing_text_body" end
          if reason then
            quarantine_event(ev, reason)
          else
          local thread_root, in_reply_to = relation_fields(content)
          local actual_room = room_id or cfg.room
          local direct_senders = state.direct_rooms[actual_room]
          local is_direct = type(direct_senders) == "table" and direct_senders[ev.sender] == true
          local route_mail_id = instance:mail_route_for_event(actual_room, thread_root, in_reply_to)
          local addressed = is_direct or mentions(content, content.body, cfg.self_mxid) or route_mail_id ~= nil
          local is_other_butler = cfg.butler_senders[ev.sender] == true
          if not addressed or (is_other_butler and not mentions(content, content.body, cfg.self_mxid)) then
            add_processed(state, ev.event_id)
            if cursor then state.since = cursor end
          else
          state.pending[ev.event_id] = {
            sender = ev.sender, room_id = actual_room, event_id = ev.event_id,
            created_at = timestamp(ev), body = cap_body(content.body),
            thread_root = thread_root, in_reply_to = in_reply_to, mxc = media_uri(content),
            context_mail_id = route_mail_id, from_butler = is_other_butler,
          }
          added[#added + 1] = ev.event_id
          if cursor then state.since = cursor end
          persist()
          end
        end
      end
    end
    end
    return added
  end

  local function begin_request(path, params, timeout)
    if not active then return end
    local request_generation = generation
    local token = {}
    request_token = token
    local args = { method = "GET", path = query(path, params), room = cfg.room,
      timeout = timeout, max_bytes = 1024 * 1024 }
    local callback_seen = false
    local handle = api.request_json(args, function(result)
      callback_seen = true
      if request_token ~= token or generation ~= request_generation or not active then return end
      request_token = nil
      request_handle = nil
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
    if not callback_seen and request_token == token and generation == request_generation then
      request_handle = handle
    end
  end

  local function update_direct_rooms(response)
    local account_events = response.account_data and response.account_data.events or {}
    local changed = false
    for _, account_event in ipairs(account_events) do
      if account_event.type == "m.direct" and type(account_event.content) == "table" then
        state.direct_rooms = json.object({})
        changed = true
        for sender, rooms in pairs(account_event.content) do
          if type(rooms) == "table" then
            for _, room_id in ipairs(rooms) do
              if type(room_id) == "string" then
                state.direct_rooms[room_id] = state.direct_rooms[room_id] or json.object({})
                if state.direct_rooms[room_id][sender] ~= true then
                  state.direct_rooms[room_id][sender] = true
                  changed = true
                end
              end
            end
          end
        end
      end
    end
    if changed then persist() end
  end

  function instance._response(response, path)
    if path == SYNC_PATH then update_direct_rooms(response) end
    if path == SYNC_PATH and state.since == nil then
      if type(response.next_batch) ~= "string" then failed(); return end
      state.since = response.next_batch
      persist()
      deliver_pending()
      poll()
      return
    end
    if path == SYNC_PATH then
      local added = {}
      local joined = response.rooms and response.rooms.join or {}
      for room_id, room in pairs(joined) do
        if room_id == cfg.room or state.direct_rooms[room_id] then
          local room_added = accept_events(room and room.timeline and room.timeline.events, nil, room_id)
          for _, id in ipairs(room_added) do added[#added + 1] = id end
        end
      end
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
    generation = generation + 1
    active = true
    for id, item in pairs(state.reply_outbox) do
      if item.status ~= "failed" then instance._send_reply(id) end
    end
    poll()
    return true
  end

  function instance:stop()
    generation = generation + 1
    active = false
    if request_handle and request_handle.cancel then pcall(function() request_handle:cancel() end) end
    request_handle = nil
    request_token = nil
    for _, token in pairs(reply_in_flight) do
      if token.handle and token.handle.cancel then pcall(function() token.handle:cancel() end) end
    end
    reply_in_flight = {}
    if retry_timer then pcall(remuda.cancel, retry_timer) end
    if backfill_timer then pcall(remuda.cancel, backfill_timer) end
    for _, timer in pairs(delivery_retry_timers) do pcall(remuda.cancel, timer) end
    for _, timer in pairs(reply_retry_timers) do pcall(remuda.cancel, timer) end
    delivery_retry_timers, delivery_retry_waiting, reply_retry_timers = {}, {}, {}
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
          kind = event.from_butler and "matrix-butler" or "matrix", leader = "" },
        to = "butler", text = event.body, in_reply_to = event.context_mail_id,
        subject = event.context_mail_id and ("Matrix thread reply from " .. event.sender)
          or ("Matrix message from " .. event.sender),
      matrix = { sender = event.sender, room_id = event.room_id, event_id = event.event_id,
          created_at = event.created_at, thread_root = event.thread_root,
          in_reply_to = event.in_reply_to, context_mail_id = event.context_mail_id,
          from_butler = event.from_butler, mxc = event.mxc },
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

function matrix.quarantine_list()
  if relay.instance then return relay.instance:quarantine_list() end
  local paths = remuda._butler_matrix_config
  if not paths or not paths.config_path then return nil, "Matrix is not configured" end
  local state_path = paths.config_path .. ".since"
  local state, err, quarantine_pruned = load_state(state_path)
  if err then return nil, "cannot inspect Matrix quarantine: " .. tostring(err) end
  if quarantine_pruned then
    local saved, save_error = save_state(state_path, state)
    if not saved then return nil, "cannot remove expired Matrix quarantine records: " .. tostring(save_error) end
  end
  return state.quarantine
end

function matrix.quarantine_get(id)
  if type(id) ~= "string" or id == "" then return nil, "quarantine id is required" end
  if relay.instance then
    local result = relay.instance:quarantine_get(id)
    if result then return result end
    return nil, "no quarantined Matrix event " .. id
  end
  local rows, err = matrix.quarantine_list()
  if not rows then return nil, err end
  for _, item in ipairs(rows) do
    if item.id == id or item.event_id == id then return item end
  end
  return nil, "no quarantined Matrix event " .. id
end

function matrix.mail_reply(opts, callback)
  if not relay.instance then return nil, "Matrix relay is not running" end
  return relay.instance:queue_mail_reply(opts, callback)
end

function matrix.mail_reply_status(mail_id)
  if type(mail_id) ~= "string" or mail_id == "" then return nil, "mail_id is required" end
  if relay.instance then return relay.instance:mail_reply_status(mail_id) end
  local paths = remuda._butler_matrix_config
  if not paths or not paths.config_path then return nil, "Matrix is not configured" end
  local state = load_state(paths.config_path .. ".since")
  local route = state.routes[mail_id]
  if not route or not route.last_reply_event_id then return nil end
  return { source_mail_id = mail_id, reply_mail_id = route.last_reply_mail_id,
    room_id = route.room_id, thread_root = route.thread_root,
    event_id = route.last_reply_event_id }
end

function matrix.quarantine(opts, callback, agent)
  if agent then return callback({ error = "matrix quarantine is operator-only" }) end
  opts = opts or {}
  local result, err
  if opts.id then result, err = matrix.quarantine_get(opts.id)
  else result, err = matrix.quarantine_list() end
  if not result then return callback({ error = err }) end
  return callback({ json = type(result) == "table" and result or { item = result } })
end

return relay
