local config = assert(remuda._butler_mail_config)
local bus = assert(config.bus)
bus.mail_loaded = bus.mail_loaded or {}
bus.mail_read = bus.mail_read or {}
bus.mail_unreadable = bus.mail_unreadable or {}

local function mailbox(name)
  bus.inboxes[name] = bus.inboxes[name] or {}
  return bus.inboxes[name]
end

local function address(value)
  if type(value) == "table" then
    local copy = {}
    for key, field in pairs(value) do copy[key] = field end
    copy.host = copy.host or "local"
    copy.alias = copy.alias or copy.session or "unknown"
    copy.session = copy.session or copy.alias
    copy.id, copy.kind, copy.leader = copy.id or "", copy.kind or "", copy.leader or ""
    return copy
  end
  local agent = bus.agents[value]
  if agent then
    local parent = agent.parent and bus.agents[agent.parent]
    return { host = "local", id = agent.id or "", alias = agent.alias or value,
      session = agent.alias or value, kind = agent.kind or "", leader = parent and parent.id or "" }
  end
  return { host = "local", id = "", alias = tostring(value or "outside"),
    session = tostring(value or "outside"), kind = "", leader = "" }
end

local function file_component(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

local function message_id()
  bus.next = bus.next + 1
  local seed = os.tmpname()
  os.remove(seed)
  local suffix = (seed:match("([^/]+)$") or seed):gsub("[^%w_-]", "-")
  return "message-" .. string.format("%x", os.time()) .. "-" .. string.format("%x", bus.next) .. "-" .. suffix
end

local function write_atomic(path, content)
  local temporary = path .. ".tmp-" .. message_id()
  local file, err = io.open(temporary, "w")
  if not file then return nil, err end
  local ok, write_err = file:write(content)
  local close_ok, close_err = file:close()
  if not ok or not close_ok then
    os.remove(temporary)
    return nil, write_err or close_err
  end
  local renamed, rename_err = os.rename(temporary, path)
  if not renamed then
    os.remove(temporary)
    return nil, rename_err
  end
  return true
end

-- Shared by every JSONL log (inboxes, read, agents). A crash can leave a last
-- row with no newline; end it first, or the next row is glued on and lost.
local function append(path, content)
  local tail = io.open(path, "rb")
  if tail then
    local size = tail:seek("end")
    if size and size > 0 and tail:seek("set", size - 1) and tail:read(1) ~= "\n" then
      content = "\n" .. content
    end
    tail:close()
  end
  local file, err = io.open(path, "a")
  if not file then return nil, err end
  local ok, write_err = file:write(content)
  local close_ok, close_err = file:close()
  if not ok or not close_ok then return nil, write_err or close_err end
  return true
end

local function paths(name)
  local root = config.root
  if not root then return nil end
  return {
    objects = root .. "/objects/", messages = root .. "/messages/",
    inbox = root .. "/inboxes/" .. file_component(name) .. ".jsonl",
    read = root .. "/read/" .. file_component(name) .. ".jsonl",
  }
end

local function prepare_storage()
  if not config.root then return true end
  local ok, err = pcall(function()
    remuda.mkdir(config.root .. "/objects")
    remuda.mkdir(config.root .. "/messages")
    remuda.mkdir(config.root .. "/inboxes")
    remuda.mkdir(config.root .. "/read")
  end)
  return ok, err
end

local function envelope_json(message, object)
  local function address_json(item)
    return '{"host":' .. config.json_quote(item.host) .. ',"id":' .. config.json_quote(item.id)
      .. ',"alias":' .. config.json_quote(item.alias) .. ',"kind":' .. config.json_quote(item.kind)
      .. ',"leader":' .. config.json_quote(item.leader) .. ',"session":' .. config.json_quote(item.session) .. '}'
  end
  return '{"id":' .. config.json_quote(message.id) .. ',"from":' .. address_json(message.from)
    .. ',"to":[' .. address_json(message.to[1]) .. '],"subject":' .. config.json_quote(message.subject)
    .. ',"created_at":' .. config.json_quote(message.created_at) .. ',"content_type":'
    .. config.json_quote(message.content_type) .. ',"body":{"object_id":'
    .. config.json_quote(object.id) .. ',"bytes":' .. tostring(object.bytes) .. ',"content_type":'
    .. config.json_quote(object.content_type) .. ',"content_hash":null}}\n'
end

local function load_read(name)
  if bus.mail_read[name] then return bus.mail_read[name] end
  local read = {}
  local disk = paths(name)
  local file = disk and io.open(disk.read, "r")
  if file then
    for id in file:lines() do read[id] = true end
    file:close()
  end
  bus.mail_read[name] = read
  return read
end

local function load_message(disk, id)
  if bus.messages[id] then return bus.messages[id] end
  local envelope_file = io.open(disk.messages .. id .. ".json", "r")
  if not envelope_file then return nil end
  local envelope = envelope_file:read("*a")
  envelope_file:close()
  local object_id = envelope:match('"object_id":"([^"]+)"')
  if not object_id then return nil end
  local object_file = io.open(disk.objects .. object_id, "r")
  if not object_file then return nil end
  local content = object_file:read("*a")
  object_file:close()
  local from = envelope:match('"from":(%b{})') or "{}"
  local sender = from:match('"session":"([^"]+)"') or "unknown"
  local sender_alias = from:match('"alias":"([^"]+)"') or sender
  local sender_id = from:match('"id":"([^"]*)"') or ""
  local sender_kind = from:match('"kind":"([^"]*)"') or ""
  local sender_leader = from:match('"leader":"([^"]*)"') or ""
  local sender_host = from:match('"host":"([^"]+)"') or "local"
  local subject = envelope:match('"subject":"([^"]*)"') or "Message"
  local created_at = envelope:match('"created_at":"([^"]+)"') or "unknown"
  local message = { id = id, from = { host = sender_host, id = sender_id, alias = sender_alias,
      session = sender, kind = sender_kind, leader = sender_leader }, subject = subject, created_at = created_at,
    body = { object_id = object_id }, content_type = "text/plain; charset=utf-8" }
  bus.messages[id] = message
  bus.objects[object_id] = { id = object_id, content = content, bytes = #content,
    content_type = "text/plain; charset=utf-8" }
  return message
end

local function load_inbox(name)
  if bus.mail_loaded[name] then return end
  bus.mail_loaded[name] = true
  local disk = paths(name)
  if not disk then return end
  local read = load_read(name)
  local present = {}
  for _, id in ipairs(mailbox(name)) do present[id] = true end
  local file = io.open(disk.inbox, "r")
  if not file then return end
  for line in file:lines() do
    local id = line:match('"message_id":"([^"]+)"')
    if id and not read[id] and not present[id] then
      present[id] = true
      if load_message(disk, id) then
        mailbox(name)[#mailbox(name) + 1] = id
      else
        -- Never delivered, so never marked read: it is reported, not lost.
        io.stderr:write("butler mail: message " .. id .. " in " .. name .. ": envelope unreadable, left unread\n")
        local unreadable = bus.mail_unreadable[name] or {}
        bus.mail_unreadable[name] = unreadable
        local known = false
        for _, seen in ipairs(unreadable) do known = known or seen == id end
        if not known then unreadable[#unreadable + 1] = id end
      end
    end
  end
  file:close()
end

-- Copy unread legacy alias-addressed messages into the new identity inbox.
-- The target's on-disk message-id set is the idempotency boundary: a crash
-- after copying but before acknowledging the old log is safe to retry.
local function migrate_legacy(alias, id)
  if not config.root or not alias or not id or alias == id then return true end
  local source, target = paths(alias), paths(id)
  local legacy = io.open(source.inbox, "r")
  if not legacy then return true end
  local ready, ready_err = prepare_storage()
  if not ready then legacy:close(); return nil, ready_err end
  local old_read = load_read(alias)
  local seen, unread, copy_ids = {}, {}, {}
  local current = io.open(target.inbox, "r")
  if current then
    for line in current:lines() do
      local message_id = line:match('"message_id":"([^"]+)"')
      if message_id then seen[message_id] = true end
    end
    current:close()
  end
  for line in legacy:lines() do
    local message_id = line:match('"message_id":"([^"]+)"')
    if message_id and not old_read[message_id] then
      unread[#unread + 1] = message_id
      if not seen[message_id] then
        copy_ids[#copy_ids + 1] = message_id
        seen[message_id] = true
      end
    end
  end
  legacy:close()
  if #copy_ids > 0 then
    local rows = {}
    for _, message_id in ipairs(copy_ids) do
      rows[#rows + 1] = '{"message_id":' .. config.json_quote(message_id) .. '}\n'
    end
    local copied, copy_err = append(target.inbox, table.concat(rows))
    if not copied then return nil, copy_err end
  end
  local ack = {}
  for _, message_id in ipairs(unread) do
    if not old_read[message_id] then ack[#ack + 1] = message_id; old_read[message_id] = true end
  end
  if #ack > 0 then
    local marked, mark_err = append(source.read, table.concat(ack, "\n") .. "\n")
    if not marked then return nil, mark_err end
  end
  if bus.mail_loaded[id] then
    bus.mail_loaded[id] = nil
    load_inbox(id)
  end
  return true
end

local function queue(from, to, text, subject, in_reply_to)
  from, to = address(from), address(to)
  if to.id == "" then return nil, "recipient has no Butler ULID" end
  if from.alias == "" then from.alias, from.session = from.session, from.session end
  local recipient_id = to.id
  load_inbox(recipient_id)
  local id = message_id()
  local object_id = id:gsub("^message%-", "object-")
  local sender, body = from.alias or "outside", tostring(text)
  local object = { id = object_id, content = body, bytes = #body,
    content_type = "text/plain; charset=utf-8", content_hash = nil }
  local message = { id = id, from = from, to = { to },
    subject = subject or ("Message from " .. sender), created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    in_reply_to = in_reply_to, content_type = "text/plain; charset=utf-8", body = { object_id = object_id } }
  local disk = paths(recipient_id)
  if disk then
    local ready, ready_err = prepare_storage()
    if not ready then return nil, "cannot prepare Butler mail storage: " .. tostring(ready_err) end
    local wrote, err = write_atomic(disk.objects .. object_id, body)
    if not wrote then return nil, "cannot write Butler mail body: " .. tostring(err) end
    wrote, err = write_atomic(disk.messages .. id .. ".json", envelope_json(message, object))
    if not wrote then return nil, "cannot write Butler mail envelope: " .. tostring(err) end
    wrote, err = append(disk.inbox, '{"message_id":' .. config.json_quote(id) .. '}\n')
    if not wrote then return nil, "cannot deliver Butler mail: " .. tostring(err) end
  end
  bus.objects[object_id], bus.messages[id] = object, message
  mailbox(recipient_id)[#mailbox(recipient_id) + 1] = id
  return message
end

local function inbox(name)
  load_inbox(name)
  local messages, unreadable = mailbox(name), bus.mail_unreadable[name] or {}
  if #messages == 0 and #unreadable == 0 then return "inbox empty" end
  local out, read, shown = {}, load_read(name), {}
  for _, id in ipairs(messages) do
    local message = bus.messages[id]
    local object = message and bus.objects[message.body.object_id]
    if message and object then
      out[#out + 1] = "[" .. message.id .. " from " .. message.from.host .. "/"
        .. message.from.session .. " · " .. message.created_at .. "] " .. message.subject .. "\n" .. object.content
      read[id], shown[#shown + 1] = true, id
    end
  end
  for _, id in ipairs(unreadable) do
    out[#out + 1] = "message " .. id .. ": envelope unreadable, left unread"
  end
  local disk = paths(name)
  if disk and #shown > 0 then
    local wrote, err = append(disk.read, table.concat(shown, "\n") .. "\n")
    if not wrote then return "mail read-state was not saved: " .. tostring(err) end
  end
  bus.inboxes[name] = {}
  return table.concat(out, "\n")
end

-- Unread count for the session list, rendered often: the file is read once
-- (load_inbox is memoized); queue and inbox keep the in-memory list current.
local function unread(name)
  load_inbox(name)
  return #mailbox(name)
end

remuda._butler_mail = { mailbox = mailbox, queue = queue, inbox = inbox, unread = unread, append = append,
  migrate_legacy = migrate_legacy }
