local config = assert(remuda._butler_mail_config)
local bus = assert(config.bus)
-- Trust words are bound at load (main.lua execs matrix_request before
-- this file), so a later redefinition of the public entry cannot change them.
local is_agent_mxid = remuda.butler and remuda.butler.matrix and remuda.butler.matrix.is_agent_mxid
bus.mail_loaded = bus.mail_loaded or {}
bus.mail_read = bus.mail_read or {}
bus.mail_unreadable = bus.mail_unreadable or {}
bus.mail_delivered = bus.mail_delivered or {}
bus.mail_resent = bus.mail_resent or {}

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
  return remuda._butler_new_ulid()
end

-- FRESH refuses an existing target: rename() replaces silently, and a new
-- message or object must never clobber an earlier one (single writer, so
-- check-then-rename cannot race).
local function write_atomic(path, content, fresh)
  if fresh then
    local existing = io.open(path, "r")
    if existing then
      existing:close()
      return nil, path:match("([^/]+)$") .. " already exists; refusing to overwrite it"
    end
  end
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

-- Optional RFC 5322 §3.6.4 / §3.6.2 fields; an envelope without them is a root.
local function thread_json(message, address_json)
  local out = ""
  if message.in_reply_to then out = out .. ',"in_reply_to":' .. config.json_quote(message.in_reply_to) end
  if message.references and #message.references > 0 then
    local quoted = {}
    for i, id in ipairs(message.references) do quoted[i] = config.json_quote(id) end
    out = out .. ',"references":[' .. table.concat(quoted, ",") .. "]"
  end
  if message.reply_to then out = out .. ',"reply_to":' .. address_json(message.reply_to) end
  return out
end

local function address_json(item)
  return '{"host":' .. config.json_quote(item.host) .. ',"id":' .. config.json_quote(item.id)
    .. ',"alias":' .. config.json_quote(item.alias) .. ',"kind":' .. config.json_quote(item.kind)
    .. ',"leader":' .. config.json_quote(item.leader) .. ',"session":' .. config.json_quote(item.session) .. '}'
end

local function envelope_json(message, object)
  local matrix = ""
  if message.matrix then
    local media = {}
    for i, url in ipairs(message.matrix.media or {}) do media[i] = config.json_quote(url) end
    matrix = ',"matrix":{"sender":' .. config.json_quote(message.matrix.sender)
      .. ',"room_id":' .. config.json_quote(message.matrix.room_id)
      .. (message.matrix.room and ',"room":' .. config.json_quote(message.matrix.room) or "")
      .. ',"event_id":' .. config.json_quote(message.matrix.event_id)
      .. (message.matrix.thread_root and ',"thread_root":' .. config.json_quote(message.matrix.thread_root) or "")
      .. (message.matrix.thread_id and ',"thread_id":' .. config.json_quote(message.matrix.thread_id) or "")
      .. (message.matrix.in_reply_to and ',"in_reply_to":' .. config.json_quote(message.matrix.in_reply_to) or "")
      .. (message.matrix.room_kind and ',"room_kind":' .. config.json_quote(message.matrix.room_kind) or "")
      .. (message.matrix.mxc and ',"mxc":' .. config.json_quote(message.matrix.mxc) or "")
      .. ',"media":[' .. table.concat(media, ",") .. ']}'
  end
  return '{"id":' .. config.json_quote(message.id) .. ',"from":' .. address_json(message.from)
    .. ',"to":[' .. address_json(message.to[1]) .. '],"subject":' .. config.json_quote(message.subject)
    .. ',"created_at":' .. config.json_quote(message.created_at) .. ',"content_type":'
    .. config.json_quote(message.content_type) .. thread_json(message, address_json) .. ',"body":{"object_id":'
    .. config.json_quote(object.id) .. ',"bytes":' .. tostring(object.bytes) .. ',"content_type":'
    .. config.json_quote(object.content_type) .. ',"content_hash":null}' .. matrix .. '}\n'
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
  message.in_reply_to = envelope:match('"in_reply_to":"([^"]+)"')
  local references = envelope:match('"references":(%b[])')
  if references then
    message.references = {}
    for ref in references:gmatch('"([^"]+)"') do message.references[#message.references + 1] = ref end
  end
  local reply_to = envelope:match('"reply_to":(%b{})')
  if reply_to then
    message.reply_to = { host = reply_to:match('"host":"([^"]+)"') or "local", id = reply_to:match('"id":"([^"]*)"') or "",
      alias = reply_to:match('"alias":"([^"]+)"'), session = reply_to:match('"session":"([^"]+)"') }
  end
  local matrix = envelope:match('"matrix":(%b{})')
  if matrix then
    message.matrix = {
      sender = matrix:match('"sender":"(.-)"'),
      room_id = matrix:match('"room_id":"(.-)"'),
      event_id = matrix:match('"event_id":"(.-)"'),
      room = matrix:match('"room":"(.-)"'),
      thread_root = matrix:match('"thread_root":"(.-)"'),
      thread_id = matrix:match('"thread_id":"(.-)"'),
      in_reply_to = matrix:match('"in_reply_to":"(.-)"'),
      room_kind = matrix:match('"room_kind":"(.-)"'),
      mxc = matrix:match('"mxc":"(.-)"'),
      media = {},
    }
    local media = matrix:match('"media":(%b[])')
    if media then
      for url in media:gmatch('"(.-)"') do message.matrix.media[#message.matrix.media + 1] = url end
    end
  end
  bus.messages[id] = message
  bus.objects[object_id] = { id = object_id, content = content, bytes = #content,
    content_type = "text/plain; charset=utf-8" }
  return message
end

local function mark_delivered(name, id)
  bus.mail_delivered[name] = bus.mail_delivered[name] or {}
  bus.mail_delivered[name][id] = true
end

-- The inbox log is the delivered set: every row ever, read or not. Reply and
-- forward rely on it, so no compaction may drop ids from it.
local function delivered(name, id)
  local known = bus.mail_delivered[name]
  if known and known[id] then return true end
  local disk = paths(name)
  local file = disk and io.open(disk.inbox, "r")
  if not file then return false end
  local found = false
  for line in file:lines() do
    if line:match('"message_id":"([^"]+)"') == id then found = true end
  end
  file:close()
  if found then mark_delivered(name, id) end
  return found
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
    if id then mark_delivered(name, id) end
    local resent = id and line:match('"resent":(%b{})')
    if resent then
      local note_id = resent:match('"note_object_id":"([^"]+)"')
      local note_file = note_id and io.open(disk.objects .. note_id, "r")
      local note = note_file and note_file:read("*a")
      if note_file then note_file:close() end
      bus.mail_resent[name] = bus.mail_resent[name] or {}
      bus.mail_resent[name][id] = { date = resent:match('"date":"([^"]+)"'), note = note,
        from = { alias = (resent:match('"from":(%b{})') or ""):match('"alias":"([^"]+)"') },
        to = { alias = (resent:match('"to":(%b{})') or ""):match('"alias":"([^"]+)"') } }
    end
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

-- The inbox row is the commit point: files written before it may be orphaned
-- by a crash, never left dangling.
local MATRIX_BODY_MAX_BYTES = 64 * 1024
local function cap_matrix_body(text)
  if #text <= MATRIX_BODY_MAX_BYTES then return text end
  local keep = MATRIX_BODY_MAX_BYTES
  while true do
    while keep > 0 do
      local next_byte = text:byte(keep + 1)
      if not next_byte or next_byte < 0x80 or next_byte >= 0xc0 then break end
      keep = keep - 1
    end
    local prefix = text:sub(1, keep)
    local suffix = "[truncated " .. tostring(#text - #prefix) .. " bytes]"
    local next_keep = MATRIX_BODY_MAX_BYTES - #suffix
    if next_keep == keep then return prefix .. suffix end
    keep = next_keep
  end
end

local function queue(from, to, text, subject, in_reply_to, references, matrix)
  from, to = address(from), address(to)
  if to.id == "" then return nil, "recipient has no Butler ULID" end
  if from.alias == "" then from.alias, from.session = from.session, from.session end
  local recipient_id = to.id
  load_inbox(recipient_id)
  if matrix and matrix.event_id then
    for existing_id in pairs(bus.mail_delivered[recipient_id] or {}) do
      local existing = bus.messages[existing_id]
        or (config.root and load_message(paths(recipient_id), existing_id))
      if existing and existing.matrix and existing.matrix.event_id == matrix.event_id
        and existing.matrix.room_id == matrix.room_id then
        return existing
      end
    end
  end
  local id = message_id()
  local object_id = "object-" .. id
  local sender, body = from.alias or "outside", tostring(text)
  if matrix then body = cap_matrix_body(body) end
  local object = { id = object_id, content = body, bytes = #body,
    content_type = "text/plain; charset=utf-8", content_hash = nil }
  local message = { id = id, from = from, to = { to },
    subject = subject or ("Message from " .. sender), created_at = matrix and matrix.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    in_reply_to = in_reply_to, references = references, content_type = "text/plain; charset=utf-8",
    body = { object_id = object_id }, matrix = matrix and {
      sender = matrix.sender, room_id = matrix.room_id, event_id = matrix.event_id,
      room = matrix.room or matrix.room_kind, thread_id = matrix.thread_id,
      thread_root = matrix.thread_root, in_reply_to = matrix.in_reply_to,
      room_kind = matrix.room_kind,
      mxc = matrix.mxc, media = matrix.media or {},
    } or nil }
  local disk = paths(recipient_id)
  if disk then
    local ready, ready_err = prepare_storage()
    if not ready then return nil, "cannot prepare Butler mail storage: " .. tostring(ready_err) end
    local wrote, err = write_atomic(disk.objects .. object_id, body, true)
    if not wrote then return nil, "cannot write Butler mail body: " .. tostring(err) end
    wrote, err = write_atomic(disk.messages .. id .. ".json", envelope_json(message, object), true)
    if not wrote then return nil, "cannot write Butler mail envelope: " .. tostring(err) end
    wrote, err = append(disk.inbox, '{"message_id":' .. config.json_quote(id) .. '}\n')
    if not wrote then return nil, "cannot deliver Butler mail: " .. tostring(err) end
  end
  bus.objects[object_id], bus.messages[id] = object, message
  mailbox(recipient_id)[#mailbox(recipient_id) + 1] = id
  mark_delivered(recipient_id, id)
  return message
end

-- Only the explicit operator (the CLI with no Butler identity) skips the
-- delivered check; any other caller must be a known agent holding the message.
local function may_resend(caller, id, as_operator)
  if as_operator then return true end
  if caller.id == "" then return nil, "unknown caller: run from a Butler session" end
  if not delivered(caller.id, id) then return nil, "message " .. id .. " was not delivered to you" end
  return true
end

local function find_message(id)
  return bus.messages[id] or (config.root and load_message(paths(""), id)) or nil
end

-- RFC 5322 §3.6.4: in_reply_to is the parent; references are the parent's (or
-- its in_reply_to), then the parent. JWZ: repeats and self-references drop.
local function reply(caller, parent_id, text, as_operator, deliver)
  caller = address(caller)
  local allowed, why = may_resend(caller, parent_id, as_operator)
  if not allowed then return nil, why end
  local parent = find_message(parent_id)
  if not parent then return nil, "message " .. parent_id .. " cannot be read" end
  local matrix_parent = parent.matrix and parent.matrix.event_id and parent.matrix.room_id
  local to = matrix_parent and { host = "matrix", id = parent_id,
    alias = parent.matrix.sender or "Matrix", session = parent.matrix.sender or "Matrix" }
    or parent.reply_to or parent.from
  if not matrix_parent and (not to.id or to.id == "") then
    return nil, "cannot reply: message " .. parent_id .. " is from " .. tostring(to.alias or to.session)
      .. ", which has no Butler inbox"
  end
  local chain = parent.references or {}
  if #chain == 0 and parent.in_reply_to then chain = { parent.in_reply_to } end
  local references, seen = {}, {}
  for _, id in ipairs(chain) do
    if id ~= parent_id and not seen[id] then references[#references + 1], seen[id] = id, true end
  end
  references[#references + 1] = parent_id
  local subject = parent.subject or "Message"
  if not subject:match("^Re: ") then subject = "Re: " .. subject end
  local message = {
    kind = matrix_parent and "matrix_reply" or "mail", from = caller, to = to, text = text, subject = subject,
    in_reply_to = parent_id, references = references,
  }
  if matrix_parent then
    message.reply_id = message_id()
    message.matrix_route = { room_id = parent.matrix.room_id, event_id = parent.matrix.event_id,
      thread_root = parent.matrix.thread_root, in_reply_to = parent.matrix.in_reply_to,
      room_kind = parent.matrix.room or parent.matrix.room_kind,
      from_agent = parent.matrix.sender == nil or is_agent_mxid(parent.matrix.sender) }
  end
  if matrix_parent and not deliver then return nil, "Matrix replies require durable relay delivery" end
  if deliver then return deliver(message), nil, to end
  return queue(caller, to, text, subject, parent_id, references)
end

-- RFC 5322 §3.6.6 and postfix redirection: the original envelope is never
-- rewritten; the target gets a row for the same id plus who resent it.
local function deliver_forward(message)
  local caller, id, target, note = message.from, message.id, message.to, message.note
  if delivered(target.id, id) then return nil, "message " .. id .. " was already delivered to " .. target.alias end
  load_inbox(target.id)
  local resent = { from = caller, to = target, date = message.date, note = note }
  local disk = paths(target.id)
  if disk then
    local ready, ready_err = prepare_storage()
    if not ready then return nil, "cannot prepare Butler mail storage: " .. tostring(ready_err) end
    local note_json = ""
    if note and note ~= "" then
      local note_id = "object-" .. message_id()
      local wrote, err = write_atomic(disk.objects .. note_id, note, true)
      if not wrote then return nil, "cannot write the forward note: " .. tostring(err) end
      note_json = ',"note_object_id":' .. config.json_quote(note_id)
    end
    -- The row is the commit point, written after the note object.
    local wrote, err = append(disk.inbox, '{"message_id":' .. config.json_quote(id) .. ',"resent":{"from":'
      .. address_json(caller) .. ',"to":' .. address_json(target) .. ',"date":'
      .. config.json_quote(resent.date) .. note_json .. '}}\n')
    if not wrote then return nil, "cannot deliver the forward: " .. tostring(err) end
  end
  bus.mail_resent[target.id] = bus.mail_resent[target.id] or {}
  bus.mail_resent[target.id][id] = resent
  mailbox(target.id)[#mailbox(target.id) + 1] = id
  mark_delivered(target.id, id)
  return find_message(id)
end

local function forward(caller, id, target, note, as_operator, deliver)
  caller, target = address(caller), address(target)
  if target.id == "" then return nil, "recipient has no Butler ULID" end
  local allowed, why = may_resend(caller, id, as_operator)
  if not allowed then return nil, why end
  if not find_message(id) then return nil, "message " .. id .. " cannot be read" end
  local message = {
    kind = "forward", id = id, from = caller, to = target,
    date = os.date("!%Y-%m-%dT%H:%M:%SZ"), note = note,
  }
  if deliver then return deliver(message) end
  return deliver_forward(message)
end

-- load_inbox runs once per daemon, so ids left unread for a bad envelope are
-- retried here; one that now loads is delivered like any other.
local function retry_unreadable(name)
  local unreadable, disk = bus.mail_unreadable[name], paths(name)
  if not unreadable or not disk then return end
  local still = {}
  for _, id in ipairs(unreadable) do
    if load_message(disk, id) then
      mailbox(name)[#mailbox(name) + 1] = id
    else
      still[#still + 1] = id
    end
  end
  bus.mail_unreadable[name] = still
end

local function utf8_prefix(value, limit)
  if #value <= limit then return value end
  local cut = limit
  local byte = value:byte(cut)
  if byte >= 0x80 and byte <= 0xbf then
    local lead = cut
    while lead > 1 do
      local current = value:byte(lead)
      if current < 0x80 or current > 0xbf then break end
      lead = lead - 1
    end
    local first = value:byte(lead)
    local width = first >= 0xf0 and first <= 0xf4 and 4
      or first >= 0xe0 and first <= 0xef and 3
      or first >= 0xc2 and first <= 0xdf and 2 or 1
    if width > cut - lead + 1 then cut = lead - 1 end
  elseif byte >= 0xc0 then
    cut = cut - 1
  end
  return value:sub(1, cut)
end

local function inbox(name)
  load_inbox(name)
  retry_unreadable(name)
  local messages, unreadable = mailbox(name), bus.mail_unreadable[name] or {}
  if #messages == 0 and #unreadable == 0 then return "inbox empty" end
  local out, read, shown = {}, load_read(name), {}
  for _, id in ipairs(messages) do
    local message = bus.messages[id]
    local object = message and bus.objects[message.body.object_id]
    if message and object then
      local lines = { "[" .. message.id .. " from " .. message.from.host .. "/"
        .. message.from.session .. " · " .. message.created_at .. "] " .. message.subject }
      if message.matrix and message.matrix.event_id then
        local event_id = message.matrix.event_id:gsub("[%z\1-\31\127]", "")
          :gsub("\194[\128-\159]", "")
        event_id = utf8_prefix(event_id, 256)
        lines[#lines + 1] = "  Matrix event " .. event_id
      end
      if message.in_reply_to then
        local root = message.references and message.references[1]
        if root then
          lines[#lines + 1] = "  in reply to " .. message.in_reply_to .. " (thread " .. root .. ")"
        else
          lines[#lines + 1] = "  in reply to " .. message.in_reply_to
        end
      elseif message.references and message.references[1] then
        lines[#lines + 1] = "  thread " .. message.references[1]
      end
      local resent = bus.mail_resent[name] and bus.mail_resent[name][id]
      if resent then
        lines[#lines + 1] = "  forwarded by " .. tostring(resent.from.alias) .. " to " .. tostring(resent.to.alias)
          .. " at " .. tostring(resent.date) .. ((resent.note and resent.note ~= "") and (": " .. resent.note) or "")
      end
      lines[#lines + 1] = object.content
      out[#out + 1] = table.concat(lines, "\n")
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
  retry_unreadable(name)
  return #mailbox(name)
end

local function is_unread(name, id)
  load_inbox(name)
  retry_unreadable(name)
  for _, message_id in ipairs(mailbox(name)) do
    if message_id == id then return true end
  end
  for _, message_id in ipairs(bus.mail_unreadable[name] or {}) do
    if message_id == id then return true end
  end
  return false
end

remuda._butler_mail = { mailbox = mailbox, queue = queue, reply = reply, forward = forward, forward_delivery = deliver_forward, inbox = inbox, unread = unread, append = append,
  find_message = find_message, is_unread = is_unread, migrate_legacy = migrate_legacy }
