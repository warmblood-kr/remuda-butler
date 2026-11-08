-- Pure source adapter v1: exact immutable-file snapshot for one recipient.
--
-- This module performs migration-time verification only. It opens no SQLite,
-- performs no delivery or read receipt, and never mutates the mail source.
-- Every filesystem, JSON and hash capability is injected; absent capabilities
-- fail closed instead of guessing.
local M = { contract_version = 1 }

local function fail(code, field, path, line)
  return nil, { code = code, field = field, path = path, line = line }
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

-- Mailbox names are lowercase, even-length hex file components, never names.
local function is_hex(value)
  return type(value) == "string" and #value > 0 and #value % 2 == 0
    and value:match("^[0-9a-f]+$") ~= nil
end

-- An id becomes a path component; never one that leaves its directory.
local function safe_component(value)
  return nonempty(value) and not value:find("[/\\]") and not value:find("..", 1, true)
end

-- Bound root is an absolute canonical path, never a relative name.
local function is_canonical_root(value)
  if type(value) ~= "string" or value == "" or value:sub(1, 1) ~= "/" then return false end
  if value == "/" or value:sub(-1) == "/" then return false end
  if value:find("//", 1, true) then return false end
  if value:find("/./", 1, true) or value:sub(-2) == "/." then return false end
  if value:find("/../", 1, true) or value:sub(-3) == "/.." then return false end
  return true
end

-- fs.list is a dense array of basenames; extra or hole keys are not ignored.
local function dense_length(values)
  local count, maximum = 0, 0
  for key in pairs(values) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return nil end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if count ~= maximum then return nil end
  return count
end

local function error_code(err)
  if type(err) == "table" and nonempty(err.code) then return err.code end
  if type(err) == "string" and err:find("No such file", 1, true) then return "not_found" end
  return "io"
end

local Source = {}
Source.__index = Source

local function read(self, path)
  local ok, text, err = pcall(self.fs.read, path)
  if not ok or type(text) ~= "string" then
    local code = (not ok) and "io" or error_code(err)
    return nil, { code = (code == "not_found") and "not_found" or "source_unreadable", path = path }
  end
  return text
end

local function list(self, path)
  local ok, names, err = pcall(self.fs.list, path)
  if not ok then return nil, { code = "source_unreadable", path = path } end
  if names == nil then
    local code = error_code(err)
    if code == "not_found" then return {}, nil end
    return nil, { code = "source_unreadable", path = path }
  end
  if type(names) ~= "table" then return nil, { code = "source_unreadable", path = path } end
  local length = dense_length(names)
  if not length then return nil, { code = "source_unreadable", path = path } end
  for index = 1, length do
    if type(names[index]) ~= "string" then
      return nil, { code = "source_unreadable", path = path }
    end
  end
  return names, nil
end

local function decode(self, text, path)
  local ok, value = pcall(self.json.decode, text)
  if not ok or value == nil then return nil, { code = "source_unreadable", path = path } end
  return value
end

local function canonical(self, value, path)
  local ok, text = pcall(self.json.canonical, value)
  if not ok or type(text) ~= "string" then return nil, { code = "source_unreadable", path = path } end
  return text
end

local function check_root(self, root)
  if root ~= self.root then return fail("invalid_snapshot", "root") end
  return true
end

local function check_recipient(hex)
  if not is_hex(hex) then return fail("invalid_snapshot", "recipient") end
  return true
end

-- A missing content file is unreadable source, never an empty mailbox.
local function content_error(why, path, field)
  return fail("source_unreadable", field or "missing", path)
end

local function torn(text, path)
  return text ~= "" and text:sub(-1) ~= "\n" and { code = "partial", path = path } or nil
end

-- Strict newline-terminated JSONL of objects with a nonempty safe message_id.
-- Duplicates collapse at first distinct appearance; only a PRESENT resent
-- object replaces the retained annotation.
local function parse_inbox(self, hex, text)
  local path = "inboxes/" .. hex .. ".jsonl"
  local partial = torn(text, path)
  if partial then return nil, partial end
  local rows, index = {}, {}
  for line in text:gmatch("([^\n]*)\n") do
    local value, decode_err = decode(self, line, path)
    if decode_err or type(value) ~= "table" then
      return fail("source_unreadable", nil, path)
    end
    local id = value.message_id
    if not safe_component(id) then return fail("source_unreadable", "message_id", path) end
    local resent = value.resent
    if resent ~= nil and type(resent) ~= "table" then
      return fail("source_unreadable", "resent", path)
    end
    local row = index[id]
    if not row then
      row = { id = id, seq = #rows + 1 }
      rows[#rows + 1] = row
      index[id] = row
    end
    if resent ~= nil then
      local encoded, encode_err = canonical(self, resent, path)
      -- `resent` must be a JSON object. An empty Lua table cannot tell [] from
      -- {} by #, so the canonical encoding decides the wire shape.
      if not encoded or encoded:sub(1, 1) ~= "{" then
        return fail("source_unreadable", "resent", path)
      end
      row.resent = encoded
      row.resent_value = resent
    end
  end
  return rows, nil
end

-- Raw read ids: exact legacy line values (CR is data), duplicates collapse.
local function parse_reads(self, hex, text)
  local path = "read/" .. hex .. ".jsonl"
  local partial = torn(text, path)
  if partial then return nil, partial end
  local reads = {}
  for line in text:gmatch("([^\n]*)\n") do
    if not safe_component(line) then return fail("source_unreadable", nil, path) end
    reads[line] = true
  end
  return reads, nil
end

local function log_text(self, path)
  local text, why = read(self, self.root .. "/" .. path)
  if not text then
    if why.code == "not_found" then return false, nil end
    return nil, why
  end
  return text, nil
end

-- Every path the witness covers: both logs, each delivered envelope, its body
-- object, and any retained resent note object. Each file is read exactly once.
local function dependency_files(self, hex)
  local files = {}
  local inbox_text, inbox_err = log_text(self, "inboxes/" .. hex .. ".jsonl")
  if inbox_text == nil then return nil, inbox_err end
  files["inboxes/" .. hex .. ".jsonl"] = inbox_text
  local rows, rows_err = parse_inbox(self, hex, inbox_text or "")
  if not rows then return nil, rows_err end
  local read_text, read_err = log_text(self, "read/" .. hex .. ".jsonl")
  if read_text == nil then return nil, read_err end
  files["read/" .. hex .. ".jsonl"] = read_text
  local reads, reads_err = parse_reads(self, hex, read_text or "")
  if not reads then return nil, reads_err end
  for _, row in ipairs(rows) do
    local envelope_path = "messages/" .. row.id .. ".json"
    local text, why = read(self, self.root .. "/" .. envelope_path)
    if not text then return content_error(why, envelope_path) end
    files[envelope_path] = text
    local envelope, decode_err = decode(self, text, envelope_path)
    if decode_err or type(envelope) ~= "table" then
      return fail("source_unreadable", nil, envelope_path)
    end
    if envelope.id ~= row.id then return fail("source_unreadable", "id", envelope_path) end
    local body = envelope.body
    if type(body) ~= "table" or not safe_component(body.object_id) then
      return fail("source_unreadable", "object_id", envelope_path)
    end
    local object_path = "objects/" .. body.object_id
    local content, content_err = read(self, self.root .. "/" .. object_path)
    if not content then return content_error(content_err, object_path) end
    files[object_path] = content
    if body.bytes ~= nil and (type(body.bytes) ~= "number" or body.bytes % 1 ~= 0
      or body.bytes ~= #content) then
      return fail("source_unreadable", "bytes", envelope_path)
    end
    local note = row.resent_value and row.resent_value.note_object_id or nil
    if note ~= nil then
      if not safe_component(note) then
        return fail("source_unreadable", "note_object_id", "inboxes/" .. hex .. ".jsonl")
      end
      local note_path = "objects/" .. note
      local note_text, note_err = read(self, self.root .. "/" .. note_path)
      if not note_text then return content_error(note_err, note_path) end
      files[note_path] = note_text
    end
  end
  return files, nil
end

local function witness(self, root, hex)
  local ok, root_err = check_root(self, root)
  if not ok then return nil, root_err end
  ok, root_err = check_recipient(hex)
  if not ok then return nil, root_err end
  local files, dep_err = dependency_files(self, hex)
  if not files then return nil, dep_err end
  local ordered = {}
  for path in pairs(files) do ordered[#ordered + 1] = path end
  table.sort(ordered)
  local framed = {}
  local function frame(value) framed[#framed + 1] = #value .. ":" .. value end
  frame("source-v1")
  frame(self.root)
  frame(hex)
  for _, path in ipairs(ordered) do
    frame(path)
    local text = files[path]
    if text == false then
      frame("absent")
    else
      frame("present")
      frame(tostring(#text))
      frame(text)
    end
  end
  local digest = self.sha256(table.concat(framed))
  if not is_hex(digest) or #digest ~= 64 then return fail("unavailable", "sha256") end
  return "source-v1:sha256:" .. digest
end

function Source:recipients(root)
  local ok, root_err = check_root(self, root)
  if not ok then return nil, root_err end
  local names, names_err = list(self, self.root .. "/inboxes")
  if not names then return nil, names_err end
  local read_names, read_err = list(self, self.root .. "/read")
  if not read_names then return nil, read_err end
  local seen = {}
  for _, group in ipairs({ names, read_names }) do
    for _, name in ipairs(group) do
      local hex = type(name) == "string" and name:match("^([0-9a-f]+)%.jsonl$") or nil
      if not is_hex(hex) then return fail("source_unreadable", "filename") end
      seen[hex] = true
    end
  end
  local recipients = {}
  for hex in pairs(seen) do recipients[#recipients + 1] = hex end
  table.sort(recipients)
  return { recipients = recipients, complete = true }
end

function Source:snapshot(root, hex)
  local ok, root_err = check_root(self, root)
  if not ok then return nil, root_err end
  ok, root_err = check_recipient(hex)
  if not ok then return nil, root_err end
  local before, before_err = witness(self, root, hex)
  if not before then return nil, before_err end
  local inbox_text, inbox_why = log_text(self, "inboxes/" .. hex .. ".jsonl")
  if inbox_text == nil then return nil, inbox_why end
  local rows, rows_err = parse_inbox(self, hex, inbox_text or "")
  if not rows then return nil, rows_err end
  local read_text, read_why = log_text(self, "read/" .. hex .. ".jsonl")
  if read_text == nil then return nil, read_why end
  local reads, reads_err = parse_reads(self, hex, read_text or "")
  if not reads then return nil, reads_err end
  local deliveries = {}
  for index, row in ipairs(rows) do
    local envelope_path = "messages/" .. row.id .. ".json"
    local text, why = read(self, self.root .. "/" .. envelope_path)
    if not text then return content_error(why, envelope_path) end
    local envelope, decode_err = decode(self, text, envelope_path)
    if decode_err or type(envelope) ~= "table" then
      return fail("source_unreadable", nil, envelope_path)
    end
    if envelope.id ~= row.id then return fail("source_unreadable", "id", envelope_path) end
    local body = envelope.body
    if type(body) ~= "table" or not safe_component(body.object_id) then
      return fail("source_unreadable", "object_id", envelope_path)
    end
    local object_path = "objects/" .. body.object_id
    local content, content_err = read(self, self.root .. "/" .. object_path)
    if not content then return content_error(content_err, object_path) end
    if body.bytes ~= nil and (type(body.bytes) ~= "number" or body.bytes % 1 ~= 0
      or body.bytes ~= #content) then
      return fail("source_unreadable", "bytes", envelope_path)
    end
    local digest = self.sha256(content)
    if not is_hex(digest) or #digest ~= 64 then return fail("unavailable", "sha256") end
    local metadata, metadata_err = canonical(self, {
      envelope = envelope,
      object = { id = body.object_id, bytes = #content, sha256 = digest },
    }, envelope_path)
    if not metadata then return nil, metadata_err end
    deliveries[index] = { message_id = row.id, seq = index, resent = row.resent,
      envelope_ref = envelope_path, object_ref = object_path, metadata = metadata }
  end
  local after, after_err = witness(self, root, hex)
  if not after then return nil, after_err end
  if before ~= after then return fail("stale_generation") end
  return { deliveries = deliveries, reads = reads, recipient = hex, complete = true,
    witness = after, source_before = before, source_after = after }
end

function Source:witness(root, hex)
  return witness(self, root, hex)
end

-- ---------------------------------------------------------------------------
-- Sealed prefix capture. A sealed end is the byte just after the last complete
-- newline: appends after it never invalidate the prefix, and a non-newline tail
-- is recorded as torn rather than skipped or included as a complete line.
local SEAL_WINDOW = 64 * 1024

-- Plain find, not the backtracking `.*()\n` pattern: a 64 KiB no-newline tail
-- must stay linear in the C matcher.
local function last_newline(text)
  local at, last = 0, nil
  while true do
    local found = text:find("\n", at + 1, true)
    if not found then return last end
    last = found
    at = found
  end
end

local function sealed_log_end(self, path, allowance, resume)
  local ok, size, why = pcall(self.fs.size, path)
  if not ok then return nil, fail("source_unreadable", "log", path) end
  if size == nil then
    if error_code(why) == "not_found" then
      return { complete = true, end_offset = 0, torn = 0, used = 0 }
    end
    return nil, fail("source_unreadable", "log", path)
  end
  if type(size) ~= "number" or size % 1 ~= 0 or size < 0 then
    return nil, fail("source_unreadable", "log", path)
  end
  if size == 0 then
    return { complete = true, end_offset = 0, torn = 0, used = 0 }
  end
  local offset
  if resume == nil or resume == -1 then
    offset = size
  elseif type(resume) ~= "number" or resume % 1 ~= 0 or resume < 0 or resume > size then
    return nil, fail("stale_generation", "seal_resume", path)
  else
    offset = resume
  end
  if offset == 0 then
    -- A resumed scan that already reached the file start found no newline.
    return { complete = true, end_offset = 0, torn = 1, used = 0 }
  end
  local used = 0
  while offset > 0 do
    local remaining = allowance ~= nil and (allowance - used) or SEAL_WINDOW
    if remaining < 1 then
      return { complete = false, offset = offset, used = used }
    end
    local window = math.min(SEAL_WINDOW, offset, remaining)
    local window_start = offset - window
    local read_ok, chunk = pcall(self.fs.read_range, path, window_start, window)
    if not read_ok or type(chunk) ~= "table" or type(chunk.bytes) ~= "string" then
      return nil, fail("source_unreadable", "log", path)
    end
    used = used + #chunk.bytes
    local last = last_newline(chunk.bytes)
    if last then
      local finish = window_start + last
      return { complete = true, end_offset = finish,
        torn = finish < size and 1 or 0, used = used }
    end
    offset = window_start
  end
  return { complete = true, end_offset = 0, torn = 1, used = used }
end

function Source:seal(root, hex, budget)
  local ok, root_err = check_root(self, root)
  if not ok then return nil, root_err end
  ok, root_err = check_recipient(hex)
  if not ok then return nil, root_err end
  if type(self.fs.size) ~= "function" or type(self.fs.read_range) ~= "function" then
    return fail("unavailable", "fs")
  end
  local allowance, resume
  if budget ~= nil then
    if type(budget) ~= "table" or type(budget.max_bytes) ~= "number"
      or budget.max_bytes % 1 ~= 0 or budget.max_bytes < 1 then
      return fail("invalid_snapshot", "budget")
    end
    allowance = budget.max_bytes
    if budget.resume ~= nil then
      if type(budget.resume) ~= "table" then return fail("invalid_snapshot", "resume") end
      resume = budget.resume
    end
  end
  local inbox_done = resume and resume.inbox_done == 1 or false
  local read_done = resume and resume.read_done == 1 or false
  local inbox_end = resume and resume.inbox_end or nil
  local inbox_torn = resume and resume.inbox_torn or nil
  local read_end = resume and resume.read_end or nil
  local read_torn = resume and resume.read_torn or nil
  local inbox_offset = resume and resume.inbox_offset or -1
  local read_offset = resume and resume.read_offset or -1
  local used = 0
  if not inbox_done then
    local inbox, inbox_err = sealed_log_end(self,
      self.root .. "/inboxes/" .. hex .. ".jsonl", allowance,
      tonumber(inbox_offset))
    if not inbox then return nil, inbox_err end
    used = used + (inbox.used or 0)
    if not inbox.complete then
      return { partial = true, recipient = hex, bytes_read = used,
        inbox_offset = inbox.offset, read_offset = -1,
        inbox_done = 0, read_done = 0 }
    end
    inbox_done, inbox_end, inbox_torn = true, inbox.end_offset, inbox.torn
  end
  if not read_done then
    -- One total allowance per recipient: the inbox scan must not let the read
    -- scan exceed the caller's byte budget. A starved read scan resumes from
    -- its persisted offset on the next call.
    local remaining
    if allowance ~= nil then remaining = math.max(allowance - used, 0) end
    local reads, read_err = sealed_log_end(self,
      self.root .. "/read/" .. hex .. ".jsonl", remaining, tonumber(read_offset))
    if not reads then
      return nil, read_err
    end
    used = used + (reads.used or 0)
    if not reads.complete then
      return { partial = true, recipient = hex, bytes_read = used,
        inbox_offset = 0, read_offset = reads.offset,
        inbox_done = 1, inbox_end = inbox_end, inbox_torn = inbox_torn,
        read_done = 0 }
    end
    read_done, read_end, read_torn = true, reads.end_offset, reads.torn
  end
  return { recipient = hex, inbox_end = inbox_end, read_end = read_end,
    inbox_torn = inbox_torn, read_torn = read_torn, bytes_read = used }
end

-- ---------------------------------------------------------------------------
-- Resumable advance v1 (inbox-source-progress.md). The staged generation lives
-- in the injected progress backend; the cursor is bounded and diagnostic.
local LOG_CHUNK = 64 * 1024
local MAX_STAGE_ROWS = 256
-- v2 freezes the current bounded record order; v1/version-less cursors are not
-- resumed or promoted under this protocol.
local PROTOCOL = "source-progress-v2"
local generation_serial = 0

local function frame(parts)
  local out = {}
  for index = 1, #parts do out[index] = #parts[index] .. ":" .. parts[index] end
  return table.concat(out)
end

-- The sealed domain has its own seed over the immutable generation and ends;
-- v2 framing continues after that seed so appends beyond the seal cannot move
-- a completed prefix.
local SEALED_PROTOCOL = "migration-sealed-v1"
local function chain_start(self, root, hex, cursor)
  if cursor and cursor.protocol == SEALED_PROTOCOL then
    return self.sha256(frame({ SEALED_PROTOCOL, root, hex, cursor.generation,
      tostring(cursor.inbox_end), tostring(cursor.read_end) }))
  end
  return self.sha256(frame({ PROTOCOL, root, hex }))
end

local function chain_add(self, chain, path, presence, offset, length, digest)
  return self.sha256(frame({ chain, path, presence, tostring(offset),
    tostring(length), digest }))
end

local function new_generation(self, root, hex)
  generation_serial = generation_serial + 1
  local clock = (os and os.time and os.time()) or 0
  return "progress-v1:" .. self.sha256(table.concat({ root, hex, tostring(clock),
    tostring(os.clock and os.clock() or 0), tostring(generation_serial) }, "\0"))
end

-- Row helpers: false means a proven absence, nil means the query failed.
local function progress_get(self, root, hex, generation, kind, key)
  local row, err = self.progress.get(root, hex, generation, kind, key)
  if row == nil then return nil, err end
  if row.state == "absent" then return false end
  return row
end

local function scan_pages(self, root, hex, generation, kind)
  local out, after = {}, nil
  repeat
    local page, err = self.progress.scan(root, hex, generation, kind, after,
      MAX_STAGE_ROWS)
    if not page then return nil, err end
    for _, row in ipairs(page.rows) do out[#out + 1] = row end
    after = page.next_key
  until page.complete
  return out
end

local function read_dependency(self, path)
  local size, size_err = self.fs.size(self.root .. "/" .. path)
  if type(size) ~= "number" or size < 0 or size % 1 ~= 0 then
    return fail("source_unreadable", "missing", path)
  end
  if self.max_single_file_bytes and size > self.max_single_file_bytes then
    return fail("source_oversize", "file", path)
  end
  local text, why = read(self, self.root .. "/" .. path)
  if not text then return content_error(why, path) end
  return text
end

local function envelope_of(self, delivery)
  local path = "messages/" .. delivery.message_id .. ".json"
  local text, err = read_dependency(self, path)
  if not text then return nil, err end
  local envelope, decode_err = decode(self, text, path)
  if decode_err or type(envelope) ~= "table" then
    return fail("source_unreadable", nil, path)
  end
  if envelope.id ~= delivery.message_id then
    return fail("source_unreadable", "id", path)
  end
  local body = envelope.body
  if type(body) ~= "table" or not safe_component(body.object_id) then
    return fail("source_unreadable", "object_id", path)
  end
  return { path = path, text = text, envelope = envelope, body = body,
    object_path = "objects/" .. body.object_id }
end

local function note_object_path(self, delivery)
  if delivery.resent == nil then return nil end
  local resent, err = decode(self, delivery.resent,
    "inboxes/" .. delivery.message_id .. ".jsonl")
  if err or type(resent) ~= "table" then
    return fail("source_unreadable", "resent",
      "inboxes/" .. delivery.message_id .. ".jsonl")
  end
  local note = resent.note_object_id
  if note == nil then return nil end
  if not safe_component(note) then
    return fail("source_unreadable", "note_object_id",
      "inboxes/" .. delivery.message_id .. ".jsonl")
  end
  return "objects/" .. note
end

local function sha_of(self, text, path)
  local digest = self.sha256(text)
  if not is_hex(digest) or #digest ~= 64 then
    return fail("unavailable", "sha256", path)
  end
  return digest
end

local function delivery_task(self, root, hex, state, delivery, pass)
  local id = delivery.message_id
  local env_path = "messages/" .. id .. ".json"
  local env_proof, proof_err = progress_get(self, root, hex, state.generation,
    "fileproof", { pass = pass, path = env_path })
  if env_proof == nil then return nil, proof_err end
  if env_proof == false then
    return { kind = "envelope", delivery = delivery, path = env_path }
  end
  local body_dep, dep_err = progress_get(self, root, hex, state.generation,
    "dependency", { owner = id, role = "body" })
  if body_dep == nil then return nil, dep_err end
  if body_dep == false then
    if pass == 1 then return { kind = "envelope", delivery = delivery, path = env_path } end
    return fail("source_unreadable", "dependency", env_path)
  end
  local body_proof, body_err = progress_get(self, root, hex, state.generation,
    "fileproof", { pass = pass, path = body_dep.path })
  if body_proof == nil then return nil, body_err end
  if body_proof == false then
    return { kind = "body", delivery = delivery, path = body_dep.path }
  end
  local note_path, note_err = note_object_path(self, delivery)
  if not note_path and note_err then return nil, note_err end
  local note_dep, note_dep_err = progress_get(self, root, hex, state.generation,
    "dependency", { owner = id, role = "note" })
  if note_dep == nil then return nil, note_dep_err end
  if note_path and note_dep == false then
    if pass == 1 then
      return { kind = "note", delivery = delivery, path = note_path }
    end
    return fail("source_unreadable", "dependency", note_path)
  end
  if note_dep and note_dep ~= false then
    local note_proof, note_proof_err = progress_get(self, root, hex, state.generation,
      "fileproof", { pass = pass, path = note_dep.path })
    if note_proof == nil then return nil, note_proof_err end
    if note_proof == false then
      return { kind = "note", delivery = delivery, path = note_dep.path }
    end
  end
  if pass == 1 and delivery.metadata == nil then
    return { kind = "metadata", delivery = delivery }
  end
  return nil
end

-- One bounded delivery page per call. `after_key` is the last seq fully
-- checked; a delivery with unfinished work keeps the key at seq-1 so the next
-- unit rechecks it. This never scans the whole mailbox to find one task.
local function find_file_task(self, root, hex, state, pass)
  local cursor = state.cursor
  local after = tonumber(cursor.after_key) or 0
  local page, page_err = self.progress.scan(root, hex, state.generation,
    "deliveries", tostring(after), MAX_STAGE_ROWS)
  if not page then return nil, page_err end
  for _, delivery in ipairs(page.rows) do
    local task, task_err = delivery_task(self, root, hex, state, delivery, pass)
    if task_err then return nil, task_err end
    if task then
      cursor.after_key = tostring((tonumber(delivery.seq) or 1) - 1)
      return task
    end
    after = tonumber(delivery.seq) or after
    cursor.after_key = tostring(after)
  end
  if page.complete then
    cursor.after_key = nil
    return nil
  end
  cursor.after_key = tostring(after)
  return "more"
end

local function first_proof(self, root, hex, generation, path)
  local proof, err = progress_get(self, root, hex, generation, "fileproof",
    { pass = 1, path = path })
  if proof == nil then return nil, err end
  if proof == false then return fail("stale_generation", "proof", path) end
  return proof
end

local function pass2_proof(self, root, hex, state, path, text)
  local first, err = first_proof(self, root, hex, state.generation, path)
  if not first then return nil, err end
  local digest, sha_err = sha_of(self, text, path)
  if not digest then return nil, sha_err end
  if first.bytes ~= #text or first.sha256 ~= digest or first.present ~= true then
    return fail("stale_generation", "proof", path)
  end
  return { { op = "fileproof", pass = 2, path = path, present = true,
    bytes = #text, sha256 = digest } }, digest
end

local function execute_file_task(self, root, hex, state, pass, task)
  local delivery = task.delivery
  local id = delivery.message_id
  if task.kind == "envelope" then
    local env, err = envelope_of(self, delivery)
    if not env then return nil, err, 0 end
    if pass == 2 then
      local delta, digest = pass2_proof(self, root, hex, state, env.path, env.text)
      if not delta then return nil, digest, 0 end
      local chain = chain_add(self, state.cursor.chain, env.path, "present", 0,
        #env.text, digest)
      return delta, nil, #env.text, chain
    end
    local digest, sha_err = sha_of(self, env.text, env.path)
    if not digest then return nil, sha_err, 0 end
    local delta = {
      { op = "dependency", owner = id, role = "envelope", path = env.path },
      { op = "dependency", owner = id, role = "body", path = env.object_path },
      { op = "fileproof", pass = 1, path = env.path, present = true,
        bytes = #env.text, sha256 = digest },
    }
    local chain = chain_add(self, state.cursor.chain, env.path, "present", 0,
      #env.text, digest)
    return delta, nil, #env.text, chain
  end
  if task.kind == "body" then
    local env, env_err = envelope_of(self, delivery)
    if not env then return nil, env_err, 0 end
    if task.path ~= env.object_path then
      return fail("source_unreadable", "object_id", env.path), 0
    end
    local text, read_err = read_dependency(self, task.path)
    if not text then return nil, read_err, 0 end
    if env.body.bytes ~= nil and (type(env.body.bytes) ~= "number"
      or env.body.bytes % 1 ~= 0 or env.body.bytes ~= #text) then
      return fail("source_unreadable", "bytes", env.path), 0
    end
    local digest, sha_err = sha_of(self, text, task.path)
    if not digest then return nil, sha_err, 0 end
    if pass == 2 then
      local delta, why = pass2_proof(self, root, hex, state, task.path, text)
      if not delta then return nil, why, 0 end
      local chain = chain_add(self, state.cursor.chain, task.path, "present", 0,
        #text, digest)
      return delta, nil, #text, chain
    end
    local metadata, metadata_err = canonical(self, {
      envelope = env.envelope,
      object = { id = env.body.object_id, bytes = #text, sha256 = digest },
    }, env.path)
    if not metadata then return nil, metadata_err, 0 end
    local delta = {
      { op = "fileproof", pass = 1, path = task.path, present = true,
        bytes = #text, sha256 = digest },
      { op = "metadata", message_id = id, envelope_ref = env.path,
        object_ref = task.path, metadata = metadata },
    }
    local chain = chain_add(self, state.cursor.chain, task.path, "present", 0,
      #text, digest)
    return delta, nil, #text, chain
  end
  if task.kind == "note" then
    if pass == 1 then
      local already, proof_err = progress_get(self, root, hex, state.generation,
        "fileproof", { pass = 1, path = task.path })
      if already == nil then return nil, proof_err, 0 end
      if already ~= false then
        -- The note object is already proven by another delivery's first
        -- encounter; link this owner without rehashing or folding the path.
        return { { op = "dependency", owner = id, role = "note",
          path = task.path } }, nil, 0, state.cursor.chain
      end
    end
    local text, read_err = read_dependency(self, task.path)
    if not text then return nil, read_err, 0 end
    local digest, sha_err = sha_of(self, text, task.path)
    if not digest then return nil, sha_err, 0 end
    if pass == 2 then
      local delta, why = pass2_proof(self, root, hex, state, task.path, text)
      if not delta then return nil, why, 0 end
      local chain = chain_add(self, state.cursor.chain, task.path, "present", 0,
        #text, digest)
      return delta, nil, #text, chain
    end
    local delta = {
      { op = "dependency", owner = id, role = "note", path = task.path },
      { op = "fileproof", pass = 1, path = task.path, present = true,
        bytes = #text, sha256 = digest },
    }
    local chain = chain_add(self, state.cursor.chain, task.path, "present", 0,
      #text, digest)
    return delta, nil, #text, chain
  end
  if task.kind == "metadata" then
    local env, env_err = envelope_of(self, delivery)
    if not env then return nil, env_err, 0 end
    local text, read_err = read_dependency(self, env.object_path)
    if not text then return nil, read_err, 0 end
    if env.body.bytes ~= nil and (type(env.body.bytes) ~= "number"
      or env.body.bytes % 1 ~= 0 or env.body.bytes ~= #text) then
      return fail("source_unreadable", "bytes", env.path), 0
    end
    local digest, sha_err = sha_of(self, text, env.object_path)
    if not digest then return nil, sha_err, 0 end
    local metadata, metadata_err = canonical(self, {
      envelope = env.envelope,
      object = { id = env.body.object_id, bytes = #text, sha256 = digest },
    }, env.path)
    if not metadata then return nil, metadata_err, 0 end
    local delta = {
      { op = "dependency", owner = id, role = "envelope", path = env.path },
      { op = "dependency", owner = id, role = "body", path = env.object_path },
      { op = "metadata", message_id = id, envelope_ref = env.path,
        object_ref = env.object_path, metadata = metadata },
    }
    return delta, nil, #env.text + #text, state.cursor.chain
  end
  return fail("invalid_snapshot", "task"), 0
end

local function assemble_snapshot(self, root, hex, state, witness)
  local deliveries, err = scan_pages(self, root, hex, state.generation, "deliveries")
  if not deliveries then return nil, err end
  local read_rows, read_err = scan_pages(self, root, hex, state.generation, "reads")
  if not read_rows then return nil, read_err end
  local reads = {}
  for _, row in ipairs(read_rows) do reads[row.message_id] = true end
  local out = {}
  for index, row in ipairs(deliveries) do
    out[index] = { message_id = row.message_id, seq = tonumber(row.seq),
      resent = row.resent, envelope_ref = row.envelope_ref,
      object_ref = row.object_ref, metadata = row.metadata }
  end
  return { deliveries = out, reads = reads, recipient = hex, complete = true,
    witness = witness, source_before = witness, source_after = witness }
end

local function invalidate(self, root, hex, state, reason)
  local cursor = state.cursor
  local next_cursor = { generation = cursor.generation, protocol_version = 2,
    phase = "invalid", offset = 0, parse_offset = 0, line_tail = "",
    chain = cursor.chain, first_chain = cursor.first_chain,
    next_seq = cursor.next_seq or 1, complete = false }
  local value, err = self.progress.commit(root, hex, state.revision, next_cursor,
    { { op = "invalid", reason = reason } })
  if not value and err and err.code == "unknown_commit" then return nil, err end
  return fail(reason)
end

local function commit_log(self, root, hex, state, cursor, delta, bytes)
  local value, err = self.progress.commit(root, hex, state.revision, cursor, delta)
  if not value then return nil, err end
  return { revision = value.revision, cursor = cursor, bytes = bytes }
end

local function finish_log(self, root, hex, state, cursor, delta, bytes)
  if (cursor.log or "inbox") == "inbox" then
    cursor.log = "read"
    cursor.offset = 0
    cursor.parse_offset = 0
    cursor.line_tail = ""
  else
    cursor.log = nil
    if cursor.phase == "logs1" then cursor.phase = "files1" else cursor.phase = "files2" end
  end
  return commit_log(self, root, hex, state, cursor, delta, bytes)
end

local function stage_line(self, root, hex, state, cursor, log, line, seen)
  if log == "read" then
    if not safe_component(line) then return fail("source_unreadable", nil,
      "read/" .. hex .. ".jsonl") end
    return { op = "read", message_id = line }
  end
  local path = "inboxes/" .. hex .. ".jsonl"
  local value, decode_err = decode(self, line, path)
  if decode_err or type(value) ~= "table" then
    return fail("source_unreadable", nil, path)
  end
  local id = value.message_id
  if not safe_component(id) then return fail("source_unreadable", "message_id", path) end
  local resent
  if value.resent ~= nil then
    if type(value.resent) ~= "table" then return fail("source_unreadable", "resent", path) end
    local encoded, encode_err = canonical(self, value.resent, path)
    if not encoded or encoded:sub(1, 1) ~= "{" then
      return fail("source_unreadable", "resent", path)
    end
    resent = encoded
  end
  local existing, get_err = progress_get(self, root, hex, state.generation,
    "delivery", id)
  if existing == nil then return nil, get_err end
  local seq
  if seen[id] then
    seq = seen[id]
  elseif existing == false then
    seq = cursor.next_seq or 1
    cursor.next_seq = seq + 1
    seen[id] = seq
  else
    seq = tonumber(existing.seq)
    seen[id] = seq
  end
  return { op = "delivery", message_id = id, seq = seq, resent = resent }
end

local function log_unit(self, root, hex, state)
  local cursor = state.cursor
  local log = cursor.log or "inbox"
  local path = (log == "inbox" and "inboxes" or "read") .. "/" .. hex .. ".jsonl"
  local offset = cursor.offset or 0
  local parse_offset = cursor.parse_offset or 0
  local line_tail = cursor.line_tail or ""
  local limit
  if cursor.protocol == SEALED_PROTOCOL then
    limit = (log == "read") and cursor.read_end or cursor.inbox_end
    if type(limit) ~= "number" or limit % 1 ~= 0 or limit < 0 then
      return fail("invalid_snapshot", "sealed_end", path)
    end
    if offset >= limit then
      cursor.chain = chain_add(self, cursor.chain, path, "eof", limit, 0,
        assert(self.sha256("")))
      return finish_log(self, root, hex, state, cursor, {}, 0)
    end
  end
  local want = limit and math.min(LOG_CHUNK, limit - offset) or LOG_CHUNK
  local ok, chunk, range_err = pcall(self.fs.read_range,
    self.root .. "/" .. path, offset, want)
  if not ok then return fail("source_unreadable", "log", path) end
  if chunk == nil then
    if error_code(range_err) ~= "not_found" then
      return fail("source_unreadable", "log", path)
    end
    local digest = assert(self.sha256(""))
    cursor.chain = chain_add(self, cursor.chain, path, "absent", 0, 0, digest)
    return finish_log(self, root, hex, state, cursor, {}, 0)
  end
  if type(chunk) ~= "table" or type(chunk.bytes) ~= "string" then
    return fail("source_unreadable", "log", path)
  end
  local bytes = chunk.bytes
  local at_limit = limit ~= nil and (offset + #bytes >= limit)
  if limit and chunk.eof == true and not at_limit then
    -- The durable seal points past the live file: the sealed prefix was
    -- truncated or rewritten. Never stage a shorter prefix as if it were the
    -- sealed one.
    return fail("stale_generation", "log", path)
  end
  local eof = at_limit or chunk.eof == true
  if eof and #bytes == 0 and parse_offset == 0 and line_tail ~= "" then
    -- The tail was already persisted by the previous unit.
    return fail("partial")
  end
  local buffer = line_tail .. bytes
  local position = parse_offset
  local delta = {}
  local staged = 0
  local seen = {}
  while staged < MAX_STAGE_ROWS do
    local newline = buffer:find("\n", position + 1, true)
    if not newline then break end
    local op, op_err = stage_line(self, root, hex, state, cursor, log,
      buffer:sub(position + 1, newline - 1), seen)
    if not op then return nil, op_err end
    delta[#delta + 1] = op
    position = newline
    staged = staged + 1
  end
  if position < #buffer and buffer:find("\n", position + 1, true) then
    cursor.parse_offset = position
    cursor.line_tail = line_tail
    return commit_log(self, root, hex, state, cursor, delta, #bytes)
  end
  local remainder = buffer:sub(position + 1)
  if eof and limit and remainder ~= "" then
    -- A sealed end is always after a complete newline. A nonempty remainder at
    -- that end means the live bytes no longer match the seal.
    return fail("stale_generation", "log", path)
  end
  if eof and remainder ~= "" then
    -- Torn tail: rewind to this chunk's fixed boundary. Only the prefix that
    -- came from earlier folded chunks is carried; this chunk is re-read after
    -- the append, so its bytes are not duplicated and pass2 sees the same
    -- chunk boundaries.
    cursor.parse_offset = 0
    cursor.line_tail = line_tail
    if #line_tail > self.max_line_bytes then
      return fail("source_oversize", "line", path)
    end
    local committed, commit_err = commit_log(self, root, hex, state, cursor,
      delta, #bytes)
    if not committed then return nil, commit_err end
    return fail("partial")
  end
  -- The whole fixed chunk is consumed: fold its record exactly once.
  cursor.chain = chain_add(self, cursor.chain, path, "present", offset, #bytes,
    assert(self.sha256(bytes)))
  cursor.parse_offset = 0
  cursor.offset = offset + #bytes
  cursor.line_tail = remainder
  if #remainder > self.max_line_bytes then
    return fail("source_oversize", "line", path)
  end
  if eof then
    cursor.chain = chain_add(self, cursor.chain, path, "eof", offset + #bytes, 0,
      assert(self.sha256("")))
    return finish_log(self, root, hex, state, cursor, delta, #bytes)
  end
  return commit_log(self, root, hex, state, cursor, delta, #bytes)
end

local function file_unit(self, root, hex, state, pass)
  local task, task_err = find_file_task(self, root, hex, state, pass)
  if task_err then return nil, task_err end
  if task == "more" then
    return commit_log(self, root, hex, state, state.cursor, {}, 0)
  end
  if not task then
    local cursor = state.cursor
    if pass == 1 then
      cursor.first_chain = cursor.chain
      cursor.phase = "logs2"
      cursor.log = "inbox"
      cursor.offset = 0
      cursor.parse_offset = 0
      cursor.line_tail = ""
      cursor.after_key = nil
      cursor.chain = chain_start(self, root, hex, cursor)
      return commit_log(self, root, hex, state, cursor, {}, 0)
    end
    local first = cursor.first_chain
    local second = cursor.chain
    if type(first) ~= "string" or first ~= second then
      return invalidate(self, root, hex, state, "stale_generation")
    end
    local sealed = cursor.protocol == SEALED_PROTOCOL
    local witness_protocol = sealed and SEALED_PROTOCOL or PROTOCOL
    local witness = witness_protocol .. ":sha256:" .. second
    local ready_cursor = { generation = cursor.generation,
      protocol_version = sealed and 3 or 2,
      phase = "ready", offset = 0, parse_offset = 0, line_tail = "",
      chain = second, first_chain = first, next_seq = cursor.next_seq or 1,
      complete = true, witness = witness }
    if sealed then
      ready_cursor.protocol = SEALED_PROTOCOL
      ready_cursor.inbox_end = cursor.inbox_end
      ready_cursor.read_end = cursor.read_end
    end
    local value, ready_err = self.progress.commit(root, hex, state.revision,
      ready_cursor, { { op = "ready", witness = witness, first_chain = first,
        second_chain = second } })
    if not value then return nil, ready_err end
    local snapshot, snapshot_err = assemble_snapshot(self, root, hex, state, witness)
    if not snapshot then return nil, snapshot_err end
    return { revision = value.revision, cursor = ready_cursor, bytes = 0,
      snapshot = snapshot }
  end
  local delta, exec_err, bytes, chain = execute_file_task(self, root, hex, state,
    pass, task)
  if not delta then return nil, exec_err end
  state.cursor.chain = chain
  local value, commit_err = self.progress.commit(root, hex, state.revision,
    state.cursor, delta)
  if not value then return nil, commit_err end
  return { revision = value.revision, cursor = state.cursor, bytes = bytes }
end

local function advance_result(unit, state, ready)
  local cursor = unit.cursor
  local revision = unit.revision
  if ready then
    return { state = "ready", complete = true,
      cursor = { generation = cursor.generation, revision = revision,
        pass = "ready", task = "ready", offset = 0 },
      processed_bytes = 0, processed_tasks = 1, snapshot = unit.snapshot }
  end
  return { state = "backlog", complete = false,
    cursor = { generation = (cursor and cursor.generation) or state.cursor.generation,
      revision = revision, pass = (cursor and cursor.phase) or state.cursor.phase,
      task = (cursor and (cursor.log or "files")) or "files",
      offset = (cursor and cursor.offset) or 0 },
    processed_bytes = unit.bytes or 0, processed_tasks = 1, snapshot = nil }
end

local function advance_impl(self, root, hex, budget, sealed)
  local ok, root_err = check_root(self, root)
  if not ok then return nil, root_err end
  ok, root_err = check_recipient(hex)
  if not ok then return nil, root_err end
  if sealed ~= nil then
    if type(sealed) ~= "table" or not nonempty(sealed.generation)
      or type(sealed.inbox_end) ~= "number" or sealed.inbox_end % 1 ~= 0
      or sealed.inbox_end < 0 or type(sealed.read_end) ~= "number"
      or sealed.read_end % 1 ~= 0 or sealed.read_end < 0 then
      return fail("invalid_snapshot", "sealed")
    end
  end
  if type(self.progress) ~= "table" or type(self.progress.load) ~= "function"
    or type(self.progress.commit) ~= "function"
    or type(self.progress.scan) ~= "function"
    or type(self.progress.get) ~= "function" then
    return fail("unavailable", "progress")
  end
  if type(self.fs.read_range) ~= "function" or type(self.fs.size) ~= "function" then
    return fail("unavailable", "fs")
  end
  if type(budget) ~= "table" then return fail("invalid_snapshot", "budget") end
  for _, key in ipairs({ "max_bytes", "max_tasks", "max_ms" }) do
    local value = budget[key]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
      return fail("invalid_snapshot", "budget")
    end
  end
  local function new_cursor()
    local cursor = { phase = "logs1", log = "inbox", offset = 0,
      parse_offset = 0, line_tail = "", next_seq = 1, complete = false }
    if sealed then
      cursor.generation = sealed.generation
      cursor.protocol_version = 3
      cursor.protocol = SEALED_PROTOCOL
      cursor.inbox_end = sealed.inbox_end
      cursor.read_end = sealed.read_end
    else
      cursor.generation = new_generation(self, root, hex)
      cursor.protocol_version = 2
    end
    cursor.chain = chain_start(self, root, hex, cursor)
    return cursor
  end
  local state, load_err = self.progress.load(root, hex)
  if state == nil then
    if load_err and load_err.code ~= "not_found" then return nil, load_err end
    local cursor = new_cursor()
    local value, commit_err = self.progress.commit(root, hex, 0, cursor, {})
    if not value then return nil, commit_err end
    return { state = "backlog", complete = false,
      cursor = { generation = cursor.generation, revision = value.revision,
        pass = "logs1", task = "inbox", offset = 0 },
      processed_bytes = 0, processed_tasks = 0, snapshot = nil }
  end
  if sealed then
    if state.cursor.protocol == SEALED_PROTOCOL then
      if state.cursor.generation ~= sealed.generation
        or tonumber(state.cursor.inbox_end) ~= sealed.inbox_end
        or tonumber(state.cursor.read_end) ~= sealed.read_end then
        return nil, { code = "stale_generation", field = "sealed_end",
          restart_required = true }
      end
    elseif state.cursor.protocol_version == 3 then
      return nil, { code = "unsupported_protocol", required = SEALED_PROTOCOL,
        found = state.cursor.protocol, restart_required = true }
    else
      -- Explicit sealed upgrade of an older v1/v2 cursor. Old staged rows stay
      -- in place; this cursor is never resumed as if it were sealed.
      local cursor = new_cursor()
      local value, commit_err = self.progress.commit(root, hex, state.revision,
        cursor, {})
      if not value then return nil, commit_err end
      return { state = "backlog", complete = false,
        cursor = { generation = cursor.generation, revision = value.revision,
          pass = "logs1", task = "inbox", offset = 0 },
        processed_bytes = 0, processed_tasks = 0, snapshot = nil }
    end
  elseif state.cursor.protocol_version ~= 2 then
    return nil, { code = "unsupported_protocol", required = 2,
      found = state.cursor.protocol_version, restart_required = true }
  end
  if state.cursor.phase == "invalid" then return fail("stale_generation") end
  if state.cursor.phase == "ready" or state.cursor.complete == true then
    local witness = state.cursor.witness
    if type(witness) ~= "string" then
      local snapshot, snapshot_err = assemble_snapshot(self, root, hex, state, witness)
      if not snapshot then return nil, snapshot_err end
      witness = snapshot.witness
    end
    local snapshot, snapshot_err = assemble_snapshot(self, root, hex, state, witness)
    if not snapshot then return nil, snapshot_err end
    return { state = "ready", complete = true,
      cursor = { generation = state.cursor.generation, revision = state.revision,
        pass = "ready", task = "ready", offset = 0 },
      processed_bytes = 0, processed_tasks = 0, snapshot = snapshot }
  end
  local unit, unit_err
  if state.cursor.phase == "logs1" or state.cursor.phase == "logs2" then
    unit, unit_err = log_unit(self, root, hex, state)
  elseif state.cursor.phase == "files1" then
    unit, unit_err = file_unit(self, root, hex, state, 1)
  elseif state.cursor.phase == "files2" then
    unit, unit_err = file_unit(self, root, hex, state, 2)
  else
    return fail("invalid_snapshot", "phase")
  end
  if not unit then return nil, unit_err end
  return advance_result(unit, state, unit.snapshot ~= nil)
end

function Source:advance(root, hex, budget)
  return advance_impl(self, root, hex, budget, nil)
end

function Source:sealed_advance(root, hex, ends, budget)
  return advance_impl(self, root, hex, budget, ends)
end

function M.open(config)
  if type(config) ~= "table" then return fail("invalid_snapshot", "config") end
  if not is_canonical_root(config.root) then return fail("invalid_snapshot", "root") end
  local fs = config.fs
  if type(fs) ~= "table" or type(fs.list) ~= "function" or type(fs.read) ~= "function" then
    return fail("unavailable", "fs")
  end
  local json = config.json
  if type(json) ~= "table" or type(json.decode) ~= "function"
    or type(json.canonical) ~= "function" then
    return fail("unavailable", "json")
  end
  if type(config.sha256) ~= "function" then return fail("unavailable", "sha256") end
  if config.max_single_file_bytes ~= nil then
    if type(config.max_single_file_bytes) ~= "number"
      or config.max_single_file_bytes % 1 ~= 0 or config.max_single_file_bytes < 1 then
      return fail("invalid_snapshot", "max_single_file_bytes")
    end
  end
  if config.max_line_bytes ~= nil then
    if type(config.max_line_bytes) ~= "number"
      or config.max_line_bytes % 1 ~= 0 or config.max_line_bytes < 1 then
      return fail("invalid_snapshot", "max_line_bytes")
    end
  end
  if config.progress ~= nil and type(config.progress) ~= "table" then
    return fail("invalid_snapshot", "progress")
  end
  return setmetatable({ root = config.root, fs = fs, json = json,
    sha256 = config.sha256, progress = config.progress,
    max_single_file_bytes = config.max_single_file_bytes,
    max_line_bytes = config.max_line_bytes or (1024 * 1024) }, Source)
end

if type(remuda) == "table" then remuda._butler_inbox_source = M end
return M
